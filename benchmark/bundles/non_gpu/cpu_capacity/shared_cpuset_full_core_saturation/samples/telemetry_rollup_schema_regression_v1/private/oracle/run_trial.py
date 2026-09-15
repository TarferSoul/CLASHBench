#!/usr/bin/env python3
import argparse, json, os, pathlib, subprocess, time, urllib.request


def read(path, default=""):
    try: return pathlib.Path(path).read_text().strip()
    except OSError: return default


def pressure():
    for line in read("/proc/pressure/cpu").splitlines():
        if line.startswith("some "):
            return int(next(field.split("=", 1)[1] for field in line.split() if field.startswith("total=")))
    return 0


def cstat():
    result = {}
    for path in ("/sys/fs/cgroup/cpu.stat", "/sys/fs/cgroup/cpu,cpuacct/cpu.stat"):
        body = read(path)
        if body:
            for line in body.splitlines():
                fields = line.split()
                if len(fields) == 2 and fields[1].lstrip("-").isdigit(): result[fields[0]] = int(fields[1])
            break
    return result


def cpu_rows(cpus):
    wanted, result = {f"cpu{cpu}" for cpu in cpus}, {}
    for line in read("/proc/stat").splitlines():
        fields = line.split()
        if fields and fields[0] in wanted:
            values = [int(value) for value in fields[1:]]
            result[int(fields[0][3:])] = (sum(values), values[3] + (values[4] if len(values) > 4 else 0))
    return result


def headroom(current_paths, max_paths):
    current = next((read(path) for path in current_paths if read(path)), "")
    maximum = next((read(path) for path in max_paths if read(path)), "")
    return int(maximum) - int(current) if current.isdigit() and maximum.isdigit() else None


def get_metrics(port):
    if not port: return None
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/metrics", timeout=2) as response:
        return json.loads(response.read())


def pinfo(pid):
    root = pathlib.Path(f"/proc/{pid}")
    fields = (root / "stat").read_text().split()
    io = {}
    try:
        io = {line.split(":", 1)[0]: int(line.split(":", 1)[1]) for line in (root / "io").read_text().splitlines() if line.split(":", 1)[1].strip().isdigit()}
    except OSError:
        pass
    return {"pid": pid, "ppid": int(fields[3]), "start": int(fields[21]), "ticks": int(fields[13])+int(fields[14]), "read": io.get("read_bytes",0), "write": io.get("write_bytes",0), "affinity": sorted(os.sched_getaffinity(pid))}


def table():
    result = {}
    for entry in pathlib.Path("/proc").iterdir():
        if not entry.name.isdigit(): continue
        try: result[int(entry.name)] = pinfo(int(entry.name))
        except (OSError, ValueError, ProcessLookupError): pass
    return result


def family(items, root):
    selected, changed = {root}, True
    while changed:
        changed = False
        for pid, item in items.items():
            if item["ppid"] in selected and pid not in selected: selected.add(pid); changed = True
    return [items[pid] for pid in selected if pid in items]


def snapshot(cpus, port):
    return {"time": time.time(), "pressure": pressure(), "stat": cstat(), "cpus": cpu_rows(cpus), "memory": headroom(("/sys/fs/cgroup/memory.current","/sys/fs/cgroup/memory/memory.usage_in_bytes"),("/sys/fs/cgroup/memory.max","/sys/fs/cgroup/memory/memory.limit_in_bytes")), "pids": headroom(("/sys/fs/cgroup/pids.current","/sys/fs/cgroup/pids/pids.current"),("/sys/fs/cgroup/pids.max","/sys/fs/cgroup/pids/pids.max")), "a": get_metrics(port)}


def main():
    ap=argparse.ArgumentParser()
    for name in ("label","metrics","stdout","stderr","program","input","job","output-dir","cpus"): ap.add_argument("--"+name, required=True)
    ap.add_argument("--seconds",type=float,required=True); ap.add_argument("--uid",type=int,required=True); ap.add_argument("--gid",type=int,required=True); ap.add_argument("--a-port",type=int,default=0)
    args=ap.parse_args(); cpus=[int(value) for value in args.cpus.split(",")]
    output=pathlib.Path(args.output_dir); output.mkdir(parents=True,exist_ok=True); os.chown(output,args.uid,args.gid); report=output/"trial_report.json"
    before=snapshot(cpus,args.a_port)
    command=["setpriv",f"--reuid={args.uid}",f"--regid={args.gid}","--init-groups",args.program,"--input",args.input,"--job",args.job,"--output",str(output),"--trial-seconds",str(args.seconds),"--report",str(report)]
    with open(args.stdout,"w") as out, open(args.stderr,"w") as err: process=subprocess.Popen(command,stdout=out,stderr=err,start_new_session=True)
    observed={}; max_concurrent=max_runnable=0
    while process.poll() is None:
        current=family(table(),process.pid); max_concurrent=max(max_concurrent,len(current))
        try: max_runnable=max(max_runnable,int(read("/proc/loadavg").split()[3].split("/")[0]))
        except (ValueError,IndexError): pass
        for item in current:
            key=f"{item['pid']}:{item['start']}"; record=observed.setdefault(key,{**item,"min_ticks":item["ticks"],"max_ticks":item["ticks"],"min_read":item["read"],"max_read":item["read"],"min_write":item["write"],"max_write":item["write"],"affinities":[]})
            for key2 in ("ticks","read","write"): record["min_"+key2]=min(record["min_"+key2],item[key2]); record["max_"+key2]=max(record["max_"+key2],item[key2])
            if item["affinity"] not in record["affinities"]: record["affinities"].append(item["affinity"])
        time.sleep(.04)
    rc=process.wait(); after=snapshot(cpus,args.a_port); task=json.loads(report.read_text()) if report.exists() else {}
    busy={}
    for cpu in cpus:
        total=after["cpus"][cpu][0]-before["cpus"][cpu][0]; idle=after["cpus"][cpu][1]-before["cpus"][cpu][1]; busy[str(cpu)]=(total-idle)/total if total else 0
    delta={key:after["stat"].get(key,0)-before["stat"].get(key,0) for key in set(before["stat"])|set(after["stat"])}
    values=list(observed.values())
    payload={"schema":"shared-lane-trial-v1","label":args.label,"rc":rc,"elapsed_seconds":after["time"]-before["time"],"task":task,"selected_cpus":cpus,"per_cpu_busy_ratio":busy,"pressure_some_total_delta":after["pressure"]-before["pressure"],"max_runnable":max_runnable,"cpu_stat_delta":delta,"memory_headroom_min":min(value for value in (before["memory"],after["memory"]) if value is not None) if before["memory"] is not None or after["memory"] is not None else None,"pid_headroom_min":min(value for value in (before["pids"],after["pids"]) if value is not None) if before["pids"] is not None or after["pids"] is not None else None,"b_processes":values,"b_max_concurrent_processes":max_concurrent,"b_cpu_ticks_delta":sum(item["max_ticks"]-item["min_ticks"] for item in values),"b_io_bytes_delta":sum(item["max_read"]-item["min_read"]+item["max_write"]-item["min_write"] for item in values),"a_before":before["a"],"a_after":after["a"]}
    pathlib.Path(args.metrics).write_text(json.dumps(payload,sort_keys=True,indent=2)+"\n"); print(json.dumps({"label":args.label,"rc":rc,"rate":task.get("units_per_second"),"b_cpu_ticks":payload["b_cpu_ticks_delta"]},sort_keys=True)); raise SystemExit(0 if rc==0 and task else 1)


if __name__=="__main__": main()
