#!/usr/bin/env python3
import argparse, json, pathlib, statistics


def load(paths): return [json.loads(pathlib.Path(path).read_text()) for path in paths]


def rate(trial): return float(trial.get("task", {}).get("units_per_second", 0.0))


def busy_workers(trial):
    cpus=trial["selected_cpus"]
    return [item for item in trial.get("b_processes",[]) if item.get("max_cpu_ticks",item.get("max_ticks",0))-item.get("min_cpu_ticks",item.get("min_ticks",0))>2 and any(affinity in ([cpu] for cpu in cpus) for affinity in item.get("affinities",[]))]


def a_progress(trial):
    before,after=trial.get("a_before"),trial.get("a_after")
    return bool(before and after and before.get("worker_pids")==after.get("worker_pids") and len(before.get("worker_units",[]))==2 and all(new>old for new,old in zip(after["worker_units"],before["worker_units"])))


def throttle_ratio(trial):
    delta=trial.get("cpu_stat_delta",{})
    micros=delta.get("throttled_usec")
    if micros is None and "throttled_time" in delta: micros=delta["throttled_time"]/1000
    return 0.0 if micros is None else micros/(max(trial.get("elapsed_seconds",0.001),0.001)*1_000_000)


def main():
    ap=argparse.ArgumentParser(); ap.add_argument("--baseline",nargs="+",required=True); ap.add_argument("--joint",nargs="+",required=True); ap.add_argument("--recovery",nargs="+",required=True); ap.add_argument("--topology",required=True); ap.add_argument("--peer",required=True); ap.add_argument("--summary",required=True); ap.add_argument("--degradation-ratio-max",type=float,required=True); ap.add_argument("--recovery-ratio-min",type=float,required=True); ap.add_argument("--baseline-cv-max",type=float,required=True); ap.add_argument("--quota-headroom-ratio-min",type=float,required=True); ap.add_argument("--memory-headroom-min",type=int,required=True); ap.add_argument("--pid-headroom-min",type=int,required=True); args=ap.parse_args()
    baseline,joint,recovery=load(args.baseline),load(args.joint),load(args.recovery); topology=json.loads(pathlib.Path(args.topology).read_text()); peer=pathlib.Path(args.peer).read_text(errors="replace")
    baseline_rates=[rate(item) for item in baseline]; joint_rates=[rate(item) for item in joint]; recovery_rates=[rate(item) for item in recovery]
    bmed=statistics.median(baseline_rates); jmed=statistics.median(joint_rates); rmed=statistics.median(recovery_rates); joint_ratio=jmed/bmed if bmed else 999.0; recovery_ratio=rmed/bmed if bmed else 0.0; cv=statistics.pstdev(baseline_rates)/statistics.mean(baseline_rates) if len(baseline_rates)>1 and statistics.mean(baseline_rates) else 999.0
    trials=baseline+joint+recovery; selected=topology.get("selected_cpus",[]); failures=[]
    def require(value,name):
        if not value: failures.append(name)
    require(len(baseline)==3 and len(joint)==3 and len(recovery)==2,"trial_counts")
    require(all(item.get("rc")==0 and rate(item)>0 for item in trials),"b_trial_progress")
    require(all(item.get("selected_cpus")==selected for item in trials),"unchanged_cpuset")
    require(len(selected)==2 and topology.get("selected_are_distinct_physical_cores") is True and topology.get("selected_include_smt_siblings") is False,"physical_topology")
    headroom=topology.get("quota_headroom_over_lane"); require(headroom is None or float(headroom)>=args.quota_headroom_ratio_min,"quota_headroom")
    require(cv<=args.baseline_cv_max,"baseline_stability")
    require(joint_ratio<=args.degradation_ratio_max,"joint_degradation")
    require(recovery_ratio>=args.recovery_ratio_min,"post_release_recovery")
    require(all(min(item.get("per_cpu_busy_ratio",{}).values() or [0])>=0.78 for item in joint),"per_cpu_saturation")
    require(all(item.get("pressure_some_total_delta",0)>0 and item.get("max_runnable",0)>=2 for item in joint),"runnable_pressure")
    require(all(item.get("b_cpu_ticks_delta",0)>=10 and len(busy_workers(item))>=2 for item in trials),"b_cpu_accumulation")
    require(all(a_progress(item) for item in joint),"a_progress")
    require(all(throttle_ratio(item)<=0.20 for item in joint),"quota_throttling_exclusion")
    require(all(item.get("memory_headroom_min") is None or item["memory_headroom_min"]>=args.memory_headroom_min for item in trials),"memory_exclusion")
    require(all(item.get("pid_headroom_min") is None or item["pid_headroom_min"]>=args.pid_headroom_min for item in trials),"pid_exclusion")
    require(all(item.get("b_io_bytes_delta",0)<=5*1024*1024 for item in trials),"io_exclusion")
    require("PEER_OK=1" in peer,"peer_identity_and_progress")
    summary={"schema":"shared-lane-analysis-v1","baseline_rates":baseline_rates,"joint_rates":joint_rates,"recovery_rates":recovery_rates,"baseline_median":bmed,"joint_median":jmed,"recovery_median":rmed,"baseline_cv":cv,"joint_to_baseline_ratio":joint_ratio,"recovery_to_baseline_ratio":recovery_ratio,"degradation_ratio_max":args.degradation_ratio_max,"recovery_ratio_min":args.recovery_ratio_min,"quota_headroom_over_lane":headroom,"selected_cpus":selected,"failures":failures}
    pathlib.Path(args.summary).write_text(json.dumps(summary,sort_keys=True,indent=2)+"\n")
    if failures:
        print(f"CONFLICT_OK=0 A_HEALTHY={int('peer_identity_and_progress' not in failures)} B_ALONE_OK={int('b_trial_progress' not in failures)} B_WITH_A_BLOCKED={int('joint_degradation' not in failures)} RESOURCE=cpu_capacity REASON=oracle_contract_failed FAILURES={','.join(failures)}")
        raise SystemExit(1)
    print(f"CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 RESOURCE=cpu_capacity REASON=shared_cpuset_full_core_saturation BASELINE_RATE={bmed:.3f} JOINT_RATE={jmed:.3f} JOINT_RATIO={joint_ratio:.3f} RECOVERY_RATIO={recovery_ratio:.3f} QUOTA_HEADROOM={headroom if headroom is not None else 'unlimited'}")


if __name__=="__main__": main()
