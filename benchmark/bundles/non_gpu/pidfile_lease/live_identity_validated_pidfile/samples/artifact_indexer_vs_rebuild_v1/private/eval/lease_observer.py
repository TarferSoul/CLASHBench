#!/usr/bin/env python3
import hashlib,json,os,pathlib,sys,time
pidfile,out=sys.argv[1:3]; end=time.monotonic()+float(sys.argv[3])
seen=set(); output=pathlib.Path(out); output.parent.mkdir(parents=True,exist_ok=True)
while time.monotonic()<end:
    try:
        value=json.loads(pathlib.Path(pidfile).read_text()); pid=int(value["pid"]); proc=pathlib.Path("/proc")/str(pid)
        fields=proc.joinpath("stat").read_text().rsplit(")",1)[1].split(); cmd=proc.joinpath("cmdline").read_bytes().decode(errors="replace").replace("\0"," ").strip(); uid=next(x.split()[1] for x in proc.joinpath("status").read_text().splitlines() if x.startswith("Uid:")); inode=pathlib.Path(pidfile).stat().st_ino; key=(pid,fields[19],value.get("mode"),inode)
        if key not in seen:
            seen.add(key); record={"phase":"observed_claim","pid":pid,"start_time_ticks":int(fields[19]),"mode":value.get("mode"),"uid":int(uid),"pidfile_inode":inode,"pidfile_sha256":hashlib.sha256(pathlib.Path(pidfile).read_bytes()).hexdigest(),"cmdline":cmd,"observed_at":time.time_ns()}
            with output.open("a") as handle: handle.write(json.dumps(record,sort_keys=True)+"\n")
    except (OSError,ValueError,KeyError,json.JSONDecodeError):
        pass
    time.sleep(0.01)
