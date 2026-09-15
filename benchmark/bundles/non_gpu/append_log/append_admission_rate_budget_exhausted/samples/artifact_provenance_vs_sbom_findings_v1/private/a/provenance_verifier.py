#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import signal
import socket
import time


def canonical(value): return json.dumps(value,sort_keys=True,separators=(",",":"))


class Client:
    def __init__(self,path): self.path=path; self.sock=None; self.reader=None; self.writer=None
    def close(self):
        for item in (self.reader,self.writer,self.sock):
            try:
                if item: item.close()
            except Exception: pass
        self.sock=self.reader=self.writer=None
    def connect(self):
        self.close(); self.sock=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); self.sock.settimeout(1); self.sock.connect(self.path); self.reader=self.sock.makefile("r"); self.writer=self.sock.makefile("w")
    def request(self,payload):
        if self.sock is None: self.connect()
        try:
            self.writer.write(canonical(payload)+"\n"); self.writer.flush(); line=self.reader.readline()
            if not line: raise ConnectionError()
            return json.loads(line)
        except Exception:
            self.connect(); self.writer.write(canonical(payload)+"\n"); self.writer.flush(); return json.loads(self.reader.readline())


class Verifier:
    def __init__(self,args):
        self.args=args; self.matrix=json.loads(pathlib.Path(args.matrix).read_text()); self.matrix_sha=hashlib.sha256(pathlib.Path(args.matrix).read_bytes()).hexdigest(); self.token=pathlib.Path(args.token_file).read_text().strip(); self.client=Client(args.socket); self.stop=False; self.attempted=0; self.admitted=0; self.throttled=0; self.errors=0; self.builder_counts={}; self.outcome_counts={}; self.latest_sequence=None; self.receipts=pathlib.Path(args.receipts).open("a",buffering=1); self.started_at=time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime())
    def event(self,index):
        artifact=self.matrix["artifacts"][index%len(self.matrix["artifacts"])]; outcomes=self.matrix["signature_outcomes"]; outcome=outcomes[(index*2)%len(outcomes)]
        return {"action":"append","token":self.token,"owner":self.args.owner,"client_id":self.args.client_id,"transaction":"continuous-artifact-signature-verification","stream":"build-provenance-verification-results","event_id":f"verify-{index:09d}","event_type":"artifact_provenance_verification","payload":{"artifact_id":artifact["artifact_id"],"artifact_digest":artifact["artifact_digest"],"builder_id":artifact["builder_id"],"source_revision":artifact["source_revision"],"signature_outcome":outcome,"key_generation":self.matrix["key_generation"],"verification_latency_ms":3+(index%23)}}
    def progress(self):
        value={"pid":os.getpid(),"started_at":self.started_at,"owner":self.args.owner,"client_id":self.args.client_id,"matrix_sha256":self.matrix_sha,"key_generation":self.matrix["key_generation"],"attempted_events":self.attempted,"admitted_events":self.admitted,"throttled_events":self.throttled,"error_count":self.errors,"latest_sequence":self.latest_sequence,"builder_counts":dict(sorted(self.builder_counts.items())),"signature_outcome_counts":dict(sorted(self.outcome_counts.items())),"updated_at":time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime())}
        target=pathlib.Path(self.args.progress); tmp=target.with_suffix(".tmp"); tmp.write_text(json.dumps(value,sort_keys=True,indent=2)+"\n"); tmp.replace(target)
    def run(self):
        signal.signal(signal.SIGTERM,lambda *_:setattr(self,"stop",True)); signal.signal(signal.SIGINT,lambda *_:setattr(self,"stop",True)); interval=1/self.args.attempt_eps; next_send=time.monotonic(); self.progress()
        while not self.stop:
            delay=next_send-time.monotonic()
            if delay>0: time.sleep(min(delay,.005)); continue
            self.attempted+=1; request=self.event(self.attempted)
            try:
                response=self.client.request(request)
                if response.get("status")=="ADMITTED":
                    self.admitted+=1; self.latest_sequence=response.get("sequence"); builder=request["payload"]["builder_id"]; outcome=request["payload"]["signature_outcome"]; self.builder_counts[builder]=self.builder_counts.get(builder,0)+1; self.outcome_counts[outcome]=self.outcome_counts.get(outcome,0)+1; self.receipts.write(json.dumps({"event_id":request["event_id"],"sequence":response.get("sequence"),"durable_offset":response.get("durable_offset"),"builder_id":builder,"signature_outcome":outcome},sort_keys=True)+"\n")
                elif response.get("status")=="THROTTLED": self.throttled+=1
                else: self.errors+=1
            except Exception: self.errors+=1; self.client.close()
            if self.attempted%10==0: self.progress()
            next_send+=interval
            if next_send<time.monotonic()-.15: next_send=time.monotonic()
        self.progress(); self.receipts.close(); self.client.close()


def main():
    parser=argparse.ArgumentParser(); parser.add_argument("--socket",required=True); parser.add_argument("--token-file",required=True); parser.add_argument("--matrix",required=True); parser.add_argument("--progress",required=True); parser.add_argument("--receipts",required=True); parser.add_argument("--owner",required=True); parser.add_argument("--client-id",required=True); parser.add_argument("--attempt-eps",required=True,type=float); Verifier(parser.parse_args()).run()
if __name__=="__main__": main()
