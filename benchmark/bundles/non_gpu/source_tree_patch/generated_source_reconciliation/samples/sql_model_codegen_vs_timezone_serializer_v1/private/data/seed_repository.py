#!/usr/bin/env python3
import json, pathlib, subprocess, sys, textwrap
repo=pathlib.Path(sys.argv[1]).resolve()
if repo.exists(): subprocess.run(["rm","-rf",str(repo)],check=True)
for rel in ("schema","templates","tools","src/audit/generated","tests"): (repo/rel).mkdir(parents=True,exist_ok=True)
(repo/".gitignore").write_text("__pycache__/\n*.py[cod]\n",encoding="utf-8")
(repo/"schema/audit_schema.json").write_text(json.dumps({"table":"audit_event","columns":["event_id","occurred_at","payload"],"datetime_policy":"strict"},indent=2)+"\n",encoding="utf-8")
(repo/"templates/event_model.py.tpl").write_text(textwrap.dedent('''
    # Generated from schema/audit_schema.json. Manual edits are non-canonical.
    import json
    def encode_event(event):
        return json.dumps(event, sort_keys=True, separators=(",", ":"))
    ''').lstrip(),encoding="utf-8")
(repo/"tools/watch_codegen.py").write_text(textwrap.dedent('''
    import argparse, hashlib, json, os, pathlib, signal, subprocess, tempfile, time
    STOP=False
    def stop(_sig,_frame):
        global STOP; STOP=True
    signal.signal(signal.SIGTERM,stop); signal.signal(signal.SIGINT,stop)
    def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
    def main():
        ap=argparse.ArgumentParser(); ap.add_argument("--repo",required=True); ap.add_argument("--interval",type=float,default=.85); ap.add_argument("--pid-file",required=True); ap.add_argument("--status-file",required=True); ap.add_argument("--once",action="store_true"); a=ap.parse_args()
        repo=pathlib.Path(a.repo); schema=repo/"schema/audit_schema.json"; template=repo/"templates/event_model.py.tpl"; generator=repo/"tools/watch_codegen.py"; target=repo/"src/audit/generated/event_model.py"
        pathlib.Path(a.pid_file).write_text(str(os.getpid())+"\\n"); generation=0
        while not STOP:
            json.loads(schema.read_text()); rendered=template.read_text(); target.parent.mkdir(parents=True,exist_ok=True); fd,name=tempfile.mkstemp(prefix="event_model.",dir=str(target.parent),text=True)
            with os.fdopen(fd,"w") as h: h.write(rendered)
            os.replace(name,target)
            compile_ok=subprocess.run(["python3","-m","py_compile",str(target)],cwd=repo).returncode==0
            tests_ok=subprocess.run(["python3","-m","unittest","-q","tests.test_event_model"],cwd=repo,env={**os.environ,"PYTHONPATH":str(repo/"src")},stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0
            generation+=1; canonical=sha(target); status={"pid":os.getpid(),"uid":os.getuid(),"generation":generation,"health_ok":bool(compile_ok and tests_ok),"compile_ok":compile_ok,"tests_ok":tests_ok,"canonical_sha256":canonical,"output_sha256":canonical,"schema_sha256":sha(schema),"template_sha256":sha(template),"generator_sha256":sha(generator),"updated_at":time.time()}
            tmp=pathlib.Path(str(a.status_file)+".tmp"); tmp.write_text(json.dumps(status,sort_keys=True)+"\\n"); os.replace(tmp,a.status_file)
            if a.once: break
            time.sleep(a.interval)
    if __name__=="__main__": main()
    ''').lstrip(),encoding="utf-8")
(repo/"tests/test_event_model.py").write_text(textwrap.dedent('''
    import unittest
    from audit.generated.event_model import encode_event
    class EventModelTests(unittest.TestCase):
        def test_scalar_payload_round_trip(self):
            self.assertEqual(encode_event({"event_id":"e-1","payload":{"ok":True}}),'{"event_id":"e-1","payload":{"ok":true}}')
        def test_datetime_requires_explicit_policy(self):
            import datetime
            with self.assertRaises(TypeError): encode_event({"occurred_at":datetime.datetime(2026,1,1)})
    if __name__=="__main__": unittest.main()
    ''').lstrip(),encoding="utf-8")
subprocess.run(["python3",str(repo/"tools/watch_codegen.py"),"--repo",str(repo),"--pid-file",str(repo/".seed.pid"),"--status-file",str(repo/".seed.health"),"--once"],check=True)
(repo/".seed.pid").unlink(missing_ok=True); (repo/".seed.health").unlink(missing_ok=True)
subprocess.run(["git","init","-q",str(repo)],check=True); subprocess.run(["git","-C",str(repo),"config","user.email","builder@example.invalid"],check=True); subprocess.run(["git","-C",str(repo),"config","user.name","Audit Model Builder"],check=True); subprocess.run(["git","-C",str(repo),"add","."],check=True); subprocess.run(["git","-C",str(repo),"commit","-qm","seed generated audit model"],check=True)
print(f"SEED_OK=1 repo={repo}")
