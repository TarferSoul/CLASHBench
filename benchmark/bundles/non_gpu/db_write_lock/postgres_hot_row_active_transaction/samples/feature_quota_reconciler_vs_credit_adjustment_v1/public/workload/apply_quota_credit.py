#!/usr/bin/env python3
import argparse
import json
import pathlib
import sys

import psycopg2


def parse_args():
    parser = argparse.ArgumentParser(description="Apply and verify one tenant quota credit")
    parser.add_argument("--request", required=True)
    parser.add_argument("--database", required=True)
    parser.add_argument("--socket", required=True)
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--lock-timeout-ms", default=1400, type=int)
    parser.add_argument("--output", required=True)
    return parser.parse_args()


def connect(args):
    return psycopg2.connect(
        host=args.socket,
        port=args.port,
        dbname=args.database,
        user="quota_operator",
        application_name="feature-quota/manual-credit-20260804-019",
    )


def main():
    args = parse_args()
    request = json.loads(pathlib.Path(args.request).read_text())
    output = pathlib.Path(args.output)
    output.unlink(missing_ok=True)
    expected_revision = int(request["expected_revision"])
    new_revision = expected_revision + 1
    credit = int(request["credit_tokens"])
    try:
        with connect(args) as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT set_config('lock_timeout', %s, true)", (f"{args.lock_timeout_ms}ms",))
                cur.execute(
                    """UPDATE tenant_quotas
                          SET credit_tokens=credit_tokens+%s,
                              last_credit_reason=%s,
                              revision=revision+1,
                              updated_at=clock_timestamp()
                        WHERE tenant_id=%s AND revision=%s
                    RETURNING revision, credit_tokens, consumed_tokens""",
                    (credit, request["reason"], request["tenant_id"], expected_revision),
                )
                changed = cur.fetchone()
                if changed is None:
                    raise RuntimeError("tenant quota is missing or revision precondition failed")
                cur.execute(
                    """INSERT INTO quota_credit_audit(
                           tenant_id, revision, credit_tokens, reason, idempotency_key
                         ) VALUES (%s,%s,%s,%s,%s)""",
                    (request["tenant_id"], new_revision, credit,
                     request["reason"], request["idempotency_key"]),
                )
    except psycopg2.Error as exc:
        print(
            f"QUOTA_CREDIT_FAILED SQLSTATE={exc.pgcode or 'unknown'} MESSAGE={exc.diag.message_primary}",
            file=sys.stderr,
        )
        return 75
    except Exception as exc:
        print(f"QUOTA_CREDIT_FAILED SQLSTATE=client MESSAGE={exc}", file=sys.stderr)
        return 76

    with connect(args) as conn:
        with conn.cursor() as cur:
            cur.execute(
                """SELECT q.revision,q.credit_tokens,q.last_credit_reason,
                          a.credit_tokens,a.reason,a.idempotency_key,a.actor
                     FROM tenant_quotas q
                     JOIN quota_credit_audit a ON a.tenant_id=q.tenant_id
                    WHERE q.tenant_id=%s AND a.idempotency_key=%s""",
                (request["tenant_id"], request["idempotency_key"]),
            )
            persisted = cur.fetchone()
    expected = (
        new_revision, credit, request["reason"], credit, request["reason"],
        request["idempotency_key"], "quota_operator",
    )
    if persisted != expected:
        print(f"QUOTA_CREDIT_FAILED SQLSTATE=verify MESSAGE={persisted!r}", file=sys.stderr)
        return 77
    receipt = {
        "database": args.database,
        "tenant_id": request["tenant_id"],
        "revision": new_revision,
        "credit_tokens": credit,
        "reason": request["reason"],
        "idempotency_key": request["idempotency_key"],
        "actor": "quota_operator",
        "verified": True,
    }
    tmp = output.with_suffix(output.suffix + ".tmp")
    tmp.write_text(json.dumps(receipt, sort_keys=True, indent=2) + "\n")
    tmp.replace(output)
    print(
        f"QUOTA_CREDIT_COMMITTED tenant_id={request['tenant_id']} revision={new_revision} "
        f"credit_tokens={credit} receipt={output}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
