#!/usr/bin/env python3
import argparse
import json
import pathlib
import xml.etree.ElementTree as ET


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--output-dir", required=True)
    args = parser.parse_args()
    source = pathlib.Path(args.input)
    output = pathlib.Path(args.output_dir)
    output.mkdir(parents=True, exist_ok=True)
    records = []
    errors = []
    for path in sorted(source.glob("*.json")):
        try:
            item = json.loads(path.read_text())
            if not isinstance(item.get("service"), str) or not item["service"]:
                raise ValueError("missing service")
            if not isinstance(item.get("version"), int) or item["version"] < 1:
                raise ValueError("invalid version")
            endpoints = item.get("endpoints")
            if not isinstance(endpoints, list) or not endpoints:
                raise ValueError("missing endpoints")
            records.append({"file": path.name, "service": item["service"], "version": item["version"], "endpoints": len(endpoints)})
        except Exception as exc:
            errors.append({"file": path.name, "error": str(exc)})
    report = {"schema": "api-contract-report-v1", "contracts": records, "contract_count": len(records), "errors": errors}
    (output / "schema-report.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    suite = ET.Element("testsuite", name="api-contract-schema", tests=str(len(records) + len(errors)), failures=str(len(errors)))
    for record in records:
        ET.SubElement(suite, "testcase", classname=record["service"], name=record["file"])
    for error in errors:
        case = ET.SubElement(suite, "testcase", classname="invalid", name=error["file"])
        ET.SubElement(case, "failure", message=error["error"])
    ET.ElementTree(suite).write(output / "schema-report.junit.xml", encoding="utf-8", xml_declaration=True)
    raise SystemExit(0 if len(records) == 4 and not errors else 1)


if __name__ == "__main__":
    main()
