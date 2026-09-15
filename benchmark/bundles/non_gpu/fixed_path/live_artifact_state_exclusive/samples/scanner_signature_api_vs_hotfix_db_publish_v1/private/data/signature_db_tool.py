#!/usr/bin/env python3
import argparse
import csv
import json
import os
import pathlib
import sqlite3
import stat
import sys
import tempfile
import time


REQUIRED_COLUMNS = ("rule_id", "severity", "action", "pattern", "description")


def write_json(path, payload):
    if not path:
        return
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n", encoding="utf-8")


def read_rules(path):
    with pathlib.Path(path).open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        missing = [column for column in REQUIRED_COLUMNS if column not in (reader.fieldnames or [])]
        if missing:
            raise ValueError(f"missing CSV columns: {','.join(missing)}")
        rows = []
        seen = set()
        for row in reader:
            cleaned = {column: (row.get(column) or "").strip() for column in REQUIRED_COLUMNS}
            if not cleaned["rule_id"]:
                raise ValueError("empty rule_id")
            if cleaned["rule_id"] in seen:
                raise ValueError(f"duplicate rule_id: {cleaned['rule_id']}")
            seen.add(cleaned["rule_id"])
            rows.append(cleaned)
    if not rows:
        raise ValueError("no signature rows")
    return rows


def create_db(path, dataset_id, rows):
    con = sqlite3.connect(path)
    try:
        con.execute("PRAGMA journal_mode=DELETE")
        con.execute("create table metadata (key text primary key, value text not null)")
        con.execute(
            "create table signatures ("
            "rule_id text primary key, severity text not null, action text not null, "
            "pattern text not null, description text not null)"
        )
        con.execute("insert into metadata(key, value) values ('dataset_id', ?)", (dataset_id,))
        con.execute(
            "insert into metadata(key, value) values ('created_at_epoch', ?)",
            (str(int(time.time())),),
        )
        con.executemany(
            "insert into signatures(rule_id, severity, action, pattern, description) "
            "values (:rule_id, :severity, :action, :pattern, :description)",
            rows,
        )
        con.commit()
        integrity = con.execute("PRAGMA integrity_check").fetchone()[0]
        if integrity != "ok":
            raise RuntimeError(f"sqlite integrity_check failed: {integrity}")
    finally:
        con.close()


def publish(tmp_path, output, mode):
    output = pathlib.Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    if mode == "replace":
        os.replace(tmp_path, output)
        return "replaced"
    try:
        os.link(tmp_path, output)
    except FileExistsError:
        raise
    finally:
        try:
            os.unlink(tmp_path)
        except FileNotFoundError:
            pass
    return "created"


def build(args):
    output = pathlib.Path(args.output)
    report = {
        "command": "build",
        "input": args.input,
        "output": str(output),
        "dataset_id": args.dataset_id,
        "mode": args.mode,
        "ok": False,
    }
    if args.mode == "no_clobber" and output.exists():
        report.update({"error": "destination_exists", "errno": 17})
        write_json(args.report, report)
        print(f"PUBLISH_ERROR errno=17 EEXIST destination_exists path={output}", file=sys.stderr)
        return 17
    try:
        rows = read_rules(args.input)
        fd, tmp_name = tempfile.mkstemp(prefix=".signature-build-", suffix=".sqlite", dir=str(output.parent))
        os.close(fd)
        try:
            create_db(tmp_name, args.dataset_id, rows)
            os.chmod(tmp_name, 0o644)
            action = publish(tmp_name, output, args.mode)
            report.update({"ok": True, "rows": len(rows), "publish_action": action})
            write_json(args.report, report)
            print(f"BUILD_OK=1 output={output} dataset={args.dataset_id} rows={len(rows)} mode={args.mode}")
            return 0
        finally:
            try:
                os.unlink(tmp_name)
            except FileNotFoundError:
                pass
    except FileExistsError:
        report.update({"error": "destination_exists", "errno": 17})
        write_json(args.report, report)
        print(f"PUBLISH_ERROR errno=17 EEXIST destination_exists path={output}", file=sys.stderr)
        return 17
    except Exception as exc:
        report.update({"error": f"{type(exc).__name__}:{exc}"})
        write_json(args.report, report)
        print(f"BUILD_OK=0 error={type(exc).__name__}:{exc}", file=sys.stderr)
        return 1


def parse_expect_rule(value):
    parts = value.split(":")
    if len(parts) != 3 or not all(parts):
        raise argparse.ArgumentTypeError("expected RULE_ID:SEVERITY:ACTION")
    return tuple(parts)


def validate(args):
    db_path = pathlib.Path(args.db)
    errors = []
    payload = {
        "command": "validate",
        "db": str(db_path),
        "dataset_id": args.dataset_id,
        "ok": False,
    }
    try:
        st = os.lstat(db_path)
        if stat.S_ISLNK(st.st_mode):
            errors.append("db_is_symlink")
        if not stat.S_ISREG(st.st_mode):
            errors.append("db_not_regular")
    except FileNotFoundError:
        errors.append("db_missing")
        write_json(args.report, {**payload, "errors": errors})
        print("VALIDATION_OK=0 reason=db_missing")
        return 1
    try:
        con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
        integrity = con.execute("PRAGMA integrity_check").fetchone()[0]
        dataset_row = con.execute("select value from metadata where key='dataset_id'").fetchone()
        dataset = dataset_row[0] if dataset_row else None
        rule_count = con.execute("select count(*) from signatures").fetchone()[0]
        rules = {
            row[0]: {"severity": row[1], "action": row[2]}
            for row in con.execute("select rule_id, severity, action from signatures")
        }
        con.close()
    except Exception as exc:
        errors.append(f"sqlite_open_failed:{type(exc).__name__}:{exc}")
        integrity = None
        dataset = None
        rule_count = None
        rules = {}
    if integrity != "ok":
        errors.append("sqlite_integrity_failed")
    if dataset != args.dataset_id:
        errors.append("dataset_mismatch")
    if args.expect_rule_count is not None and rule_count != args.expect_rule_count:
        errors.append("rule_count_mismatch")
    for rule_id, severity, action in args.expect_rule:
        observed = rules.get(rule_id)
        if observed != {"severity": severity, "action": action}:
            errors.append(f"rule_mismatch:{rule_id}")
    payload.update(
        {
            "ok": not errors,
            "errors": errors,
            "sqlite_integrity": integrity,
            "observed_dataset_id": dataset,
            "rule_count": rule_count,
            "expected_rules": [
                {"rule_id": rule_id, "severity": severity, "action": action}
                for rule_id, severity, action in args.expect_rule
            ],
        }
    )
    write_json(args.report, payload)
    if errors:
        print(f"VALIDATION_OK=0 reason={','.join(errors)}")
        return 1
    print(f"VALIDATION_OK=1 db={db_path} dataset={dataset} rules={rule_count}")
    return 0


def main():
    parser = argparse.ArgumentParser(description="Build and validate EDR signature SQLite databases.")
    sub = parser.add_subparsers(dest="command", required=True)

    build_parser = sub.add_parser("build")
    build_parser.add_argument("--input", required=True)
    build_parser.add_argument("--output", required=True)
    build_parser.add_argument("--dataset-id", required=True)
    build_parser.add_argument("--report", required=True)
    mode = build_parser.add_mutually_exclusive_group()
    mode.add_argument("--no-clobber", dest="mode", action="store_const", const="no_clobber")
    mode.add_argument("--replace", dest="mode", action="store_const", const="replace")
    build_parser.set_defaults(mode="no_clobber", func=build)

    validate_parser = sub.add_parser("validate")
    validate_parser.add_argument("--db", required=True)
    validate_parser.add_argument("--dataset-id", required=True)
    validate_parser.add_argument("--expect-rule-count", type=int, default=None)
    validate_parser.add_argument("--expect-rule", type=parse_expect_rule, action="append", default=[])
    validate_parser.add_argument("--report", required=True)
    validate_parser.set_defaults(func=validate)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
