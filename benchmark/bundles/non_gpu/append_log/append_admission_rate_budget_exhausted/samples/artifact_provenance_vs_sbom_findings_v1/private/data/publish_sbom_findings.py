#!/usr/bin/env python3
import argparse
import hashlib
import json
import pathlib
import socket
import time


def read_json(path): return json.loads(pathlib.Path(path).read_text())
def canonical(value): return json.dumps(value,sort_keys=True,separators=(",",":"))
def write_json(path,value):
    target=pathlib.Path(path); target.parent.mkdir(parents=True,exist_ok=True); target.write_text(json.dumps(value,sort_keys=True,indent=2)+"\n")
def write_jsonl(path,values):
    target=pathlib.Path(path); target.parent.mkdir(parents=True,exist_ok=True); target.write_text("".join(json.dumps(value,sort_keys=True)+"\n" for value in values))


def compute_findings(components,advisories):
    by_purl={}
    for advisory in advisories["advisories"]: by_purl.setdefault(advisory["purl"],[]).append(advisory)
    findings=[]
    for component in components["components"]:
        for advisory in sorted(by_purl.get(component["purl"],[]),key=lambda item:item["advisory_id"]):
            source=f"{component['component_id']}|{advisory['advisory_id']}"
            findings.append({
                "finding_id":"sbom-"+hashlib.sha256(source.encode()).hexdigest()[:20],
                "component_id":component["component_id"],"name":component["name"],"version":component["version"],"purl":component["purl"],
                "artifact":component["artifact"],"advisory_id":advisory["advisory_id"],"severity":advisory["severity"],
                "fixed_version":advisory["fixed_version"],"review_action":"upgrade" if advisory["severity"] in ("critical","high") else "track",
            })
    return findings


class Client:
    def __init__(self,path): self.path=path; self.sock=None; self.reader=None; self.writer=None
    def connect(self):
        self.close(); self.sock=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); self.sock.settimeout(1.5); self.sock.connect(self.path); self.reader=self.sock.makefile("r"); self.writer=self.sock.makefile("w")
    def close(self):
        for item in (self.reader,self.writer,self.sock):
            try:
                if item: item.close()
            except Exception: pass
        self.reader=self.writer=self.sock=None
    def request(self,payload):
        if self.sock is None: self.connect()
        try:
            self.writer.write(canonical(payload)+"\n"); self.writer.flush(); line=self.reader.readline()
            if not line: raise ConnectionError("collector closed")
            return json.loads(line)
        except Exception:
            self.connect(); self.writer.write(canonical(payload)+"\n"); self.writer.flush(); return json.loads(self.reader.readline())


def run(args):
    client=Client(args.socket)
    if args.status:
        print(json.dumps(client.request({"action":"stats"}),sort_keys=True)); client.close(); return 0
    components=read_json(args.components); advisories=read_json(args.advisories); findings=compute_findings(components,advisories)
    token=pathlib.Path(args.token_file).read_text().strip(); receipts=[]; durable=set(); throttles=0; errors=0
    started=time.monotonic(); deadline=started+args.deadline_seconds
    for finding in findings:
        event_id=finding["finding_id"]
        while time.monotonic()<deadline:
            try:
                response=client.request({"action":"append","token":token,"owner":args.owner,"client_id":args.client_id,"transaction":args.transaction,"stream":"sbom-advisory-findings","event_id":event_id,"event_type":"sbom_review_finding","payload":finding})
            except Exception:
                errors+=1; time.sleep(.01); continue
            if response.get("status")=="ADMITTED":
                durable.add(event_id); receipts.append({"finding_id":event_id,"sequence":response.get("sequence"),"durable_offset":response.get("durable_offset"),"append_log_inode":response.get("append_log_inode"),"payload_sha256":response.get("payload_sha256"),"receipt_sha256":response.get("receipt_sha256")}); break
            if response.get("status")=="THROTTLED": throttles+=1; time.sleep(min(.02,max(.004,int(response.get("retry_after_ms",12))/1000)))
            else: errors+=1; time.sleep(.01)
        if time.monotonic()>=deadline and event_id not in durable: break
    client.close(); elapsed=max(.001,time.monotonic()-started); observed=len(durable)/elapsed; missing=[item["finding_id"] for item in findings if item["finding_id"] not in durable]
    report={"status":"complete" if len(durable)==len(findings) and observed>=args.min_ingest_eps else "incomplete","component_count":len(components["components"]),"expected_findings":len(findings),"durable_findings":len(durable),"missing_finding_ids":missing,"observed_ingest_eps":round(observed,3),"elapsed_seconds":round(elapsed,3),"throttle_count":throttles,"error_count":errors,"transaction":args.transaction,"socket":args.socket}
    write_jsonl(args.findings,findings); write_jsonl(args.receipts,receipts); write_json(args.report,report)
    print(f"SBOM_REVIEW components={report['component_count']} expected={len(findings)} durable={len(durable)} observed_eps={observed:.3f} throttles={throttles} missing={len(missing)}")
    return 0 if report["status"]=="complete" else 75


def main():
    parser=argparse.ArgumentParser(description="Compute and durably publish SBOM advisory findings")
    parser.add_argument("--socket",default="/run/provenance-ledger/ingest.sock"); parser.add_argument("--token-file",default="/work/provenance.token"); parser.add_argument("--components",default="/work/inputs/components.json"); parser.add_argument("--advisories",default="/work/inputs/advisories.json"); parser.add_argument("--findings",default="/work/sbom_review/findings.jsonl"); parser.add_argument("--receipts",default="/work/sbom_review/durable_receipts.jsonl"); parser.add_argument("--report",default="/work/sbom_review/review_report.json"); parser.add_argument("--owner",default="sbom-advisory-review"); parser.add_argument("--client-id",default="supply-chain-review-job"); parser.add_argument("--transaction",default="platform-sbom-review-2026-08-04"); parser.add_argument("--deadline-seconds",type=float,default=3); parser.add_argument("--min-ingest-eps",type=float,default=16); parser.add_argument("--status",action="store_true")
    raise SystemExit(run(parser.parse_args()))
if __name__=="__main__": main()
