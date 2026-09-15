#!/usr/bin/env python3
import argparse, hashlib, json, os, signal, threading, time
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

class State:
    def __init__(self, pool):
        self.pool=pool; self.lock=threading.Lock(); self.active=0
        self.by_owner={"a":0,"b":0}; self.queued=0; self.accepted=0
        self.completed=0; self.errors=0; self.stop=False; self.log_lock=threading.Lock()
    def log(self, event):
        with self.log_lock: print(json.dumps(event, sort_keys=True), flush=True)

class Service(HTTPServer):
    allow_reuse_address=True
    def __init__(self, address, handler, state, path, service_id):
        super().__init__(address, handler); self.state=state; self.path=path
        self.service_id=service_id; self.executor=ThreadPoolExecutor(max_workers=state.pool); self.timeout=.2
    def process_request(self, request, client_address):
        accepted=time.time_ns()
        with self.state.lock: self.state.accepted+=1; self.state.queued+=1
        self.executor.submit(self._run, request, client_address, accepted)
    def finish_request(self, request, client_address, accepted):
        self.RequestHandlerClass(request, client_address, self, accepted)
    def _run(self, request, address, accepted):
        with self.state.lock: self.state.queued=max(0,self.state.queued-1)
        try:
            self.finish_request(request, address, accepted); self.shutdown_request(request)
        except Exception as exc:
            with self.state.lock: self.state.errors+=1
            self.state.log({"kind":"server_error","pid":os.getpid(),"error":repr(exc),"wall_ns":time.time_ns()})
            self.shutdown_request(request)

class Handler(BaseHTTPRequestHandler):
    protocol_version="HTTP/1.1"
    def __init__(self, request, address, server, accepted):
        self.accepted_ns=accepted; super().__init__(request,address,server)
    def log_message(self,*_args): return
    def reply(self, payload, status):
        body=(json.dumps(payload,sort_keys=True)+"\n").encode()
        self.send_response(status); self.send_header("Content-Type","application/json")
        self.send_header("Content-Length",str(len(body))); self.send_header("Connection","close")
        self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        srv=self.server; parsed=urlparse(self.path); q=parse_qs(parsed.query)
        if parsed.path=="/health": self.reply({"ok":True,"service_id":srv.service_id,"pid":os.getpid()},200); return
        if parsed.path!=srv.path: self.reply({"ok":False,"error":"not_found"},404); return
        owner=q.get("owner",[""])[0]; rid=q.get("request_id",[""])[0]; batch=q.get("batch_id",[""])[0]
        unit=q.get("unit",[""])[0]; revision=q.get("revision",[""])[0]
        try: duration=int(q.get("duration_ms",["0"])[0])
        except ValueError: duration=0
        if owner not in ("a","b") or not all((rid,batch,unit,revision)) or not 20<=duration<=2500:
            self.reply({"ok":False,"error":"invalid_request"},400); return
        with srv.state.lock:
            srv.state.active+=1; srv.state.by_owner[owner]+=1
            active=srv.state.active; queued=srv.state.queued
        dispatch=time.time_ns()
        srv.state.log({"kind":"dispatch","pid":os.getpid(),"service_id":srv.service_id,"owner":owner,
                       "request_id":rid,"batch_id":batch,"unit":unit,"revision":revision,
                       "active":active,"queued":queued,"queue_wait_ms":round((dispatch-self.accepted_ns)/1e6,3),
                       "wall_ns":dispatch})
        try:
            time.sleep(duration/1000)
            rh=hashlib.sha256(f"{srv.service_id}|{revision}|{unit}|{rid}|{duration}".encode()).hexdigest()
            self.reply({"ok":True,"service_id":srv.service_id,"pid":os.getpid(),"request_id":rid,
                        "batch_id":batch,"unit":unit,"revision":revision,"response_hash":rh,
                        "queue_wait_ms":round((dispatch-self.accepted_ns)/1e6,3),"processing_ms":duration},200)
            srv.state.log({"kind":"complete","pid":os.getpid(),"service_id":srv.service_id,"owner":owner,
                           "request_id":rid,"batch_id":batch,"unit":unit,"revision":revision,
                           "response_hash":rh,"status":200,"wall_ns":time.time_ns()})
        finally:
            with srv.state.lock:
                srv.state.active=max(0,srv.state.active-1); srv.state.by_owner[owner]=max(0,srv.state.by_owner[owner]-1); srv.state.completed+=1

def main():
    ap=argparse.ArgumentParser(); ap.add_argument("--port",type=int,required=True); ap.add_argument("--path",required=True)
    ap.add_argument("--pool",type=int,required=True); ap.add_argument("--service-id",required=True); ap.add_argument("--runtime",required=True)
    a=ap.parse_args(); os.makedirs(a.runtime,exist_ok=True); state=State(a.pool)
    server=Service(("127.0.0.1",a.port),Handler,state,a.path,a.service_id); pid=os.path.join(a.runtime,"service.pid")
    with open(pid,"w") as f: json.dump({"pid":os.getpid(),"start_ns":time.time_ns(),"service_id":a.service_id},f)
    state.log({"kind":"service_ready","pid":os.getpid(),"service_id":a.service_id,"port":a.port,"pool":a.pool,"wall_ns":time.time_ns()})
    def stop(_sig,_frame): state.stop=True
    signal.signal(signal.SIGTERM,stop); signal.signal(signal.SIGINT,stop)
    def metrics():
        while not state.stop:
            with state.lock: event={"kind":"metric","pid":os.getpid(),"service_id":a.service_id,"active":state.active,"active_by_owner":dict(state.by_owner),"queued":state.queued,"accepted":state.accepted,"completed":state.completed,"errors":state.errors,"wall_ns":time.time_ns()}
            state.log(event); time.sleep(.05)
    threading.Thread(target=metrics,daemon=True).start()
    while not state.stop: server.handle_request()
    server.server_close(); server.executor.shutdown(wait=True); state.log({"kind":"service_stopped","pid":os.getpid(),"wall_ns":time.time_ns()})

if __name__=="__main__": main()
