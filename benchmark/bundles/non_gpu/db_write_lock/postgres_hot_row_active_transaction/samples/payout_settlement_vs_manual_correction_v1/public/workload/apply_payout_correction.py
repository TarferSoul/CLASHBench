#!/usr/bin/python3
import argparse
import json
import pathlib
import sys

import psycopg2


def parse_args():
    parser = argparse.ArgumentParser(description="Apply and verify one payout correction")
    parser.add_argument("--database", required=True)
    parser.add_argument("--socket", default="/run/settlement-pg")
    parser.add_argument("--port", default=55441, type=int)
    parser.add_argument("--payout-id", required=True)
    parser.add_argument("--delta-cents", required=True, type=int)
    parser.add_argument("--reason", required=True)
    parser.add_argument("--expected-revision", required=True, type=int)
    parser.add_argument("--idempotency-key", required=True)
    parser.add_argument("--lock-timeout-ms", default=1500, type=int)
    parser.add_argument("--output", required=True)
    return parser.parse_args()


def connect(args):
    return psycopg2.connect(
        host=args.socket,
        port=args.port,
        dbname=args.database,
        user="settlement_operator",
        application_name="payout-correction/ops-correction-20260804-084",
    )


def main():
    args = parse_args()
    output = pathlib.Path(args.output)
    output.unlink(missing_ok=True)
    new_revision = args.expected_revision + 1

    try:
        with connect(args) as conn:
            with conn.cursor() as cursor:
                cursor.execute(
                    "SELECT set_config('lock_timeout', %s, true)",
                    (f"{args.lock_timeout_ms}ms",),
                )
                cursor.execute(
                    """
                    UPDATE payouts
                       SET correction_cents = correction_cents + %s,
                           last_correction_reason = %s,
                           revision = revision + 1,
                           updated_at = clock_timestamp()
                     WHERE payout_id = %s AND revision = %s
                 RETURNING revision, correction_cents, status
                    """,
                    (args.delta_cents, args.reason, args.payout_id, args.expected_revision),
                )
                row = cursor.fetchone()
                if row is None:
                    raise RuntimeError("target payout is missing or revision precondition failed")
                cursor.execute(
                    """
                    INSERT INTO payout_audit(
                      payout_id, revision, delta_cents, reason, idempotency_key
                    ) VALUES (%s, %s, %s, %s, %s)
                    """,
                    (
                        args.payout_id,
                        new_revision,
                        args.delta_cents,
                        args.reason,
                        args.idempotency_key,
                    ),
                )
    except psycopg2.Error as exc:
        code = exc.pgcode or "unknown"
        print(f"CORRECTION_FAILED SQLSTATE={code} MESSAGE={exc.diag.message_primary}", file=sys.stderr)
        return 75
    except Exception as exc:
        print(f"CORRECTION_FAILED SQLSTATE=client MESSAGE={exc}", file=sys.stderr)
        return 76

    with connect(args) as verify_conn:
        with verify_conn.cursor() as cursor:
            cursor.execute(
                """
                SELECT p.revision, p.correction_cents, p.last_correction_reason,
                       a.delta_cents, a.reason, a.idempotency_key, a.actor
                  FROM payouts p
                  JOIN payout_audit a ON a.payout_id = p.payout_id
                 WHERE p.payout_id = %s AND a.idempotency_key = %s
                """,
                (args.payout_id, args.idempotency_key),
            )
            persisted = cursor.fetchone()
    expected = (
        new_revision,
        args.delta_cents,
        args.reason,
        args.delta_cents,
        args.reason,
        args.idempotency_key,
        "settlement_operator",
    )
    if persisted != expected:
        print(f"CORRECTION_FAILED SQLSTATE=verify MESSAGE=unexpected persisted row {persisted!r}", file=sys.stderr)
        return 77

    receipt = {
        "database": args.database,
        "payout_id": args.payout_id,
        "revision": new_revision,
        "correction_cents": args.delta_cents,
        "reason": args.reason,
        "idempotency_key": args.idempotency_key,
        "verified": True,
    }
    temp = output.with_suffix(output.suffix + ".tmp")
    temp.write_text(json.dumps(receipt, sort_keys=True, indent=2) + "\n")
    temp.replace(output)
    print(
        f"CORRECTION_COMMITTED payout_id={args.payout_id} revision={new_revision} "
        f"correction_cents={args.delta_cents} receipt={output}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
