#!/usr/bin/env python3
"""Validate storage-replication UDP versus feature-contract TCP evidence."""
import argparse, json, pathlib, statistics
def load(root, name): return json.loads((root / name).read_text())
def qdisc(root, label): return next(x for x in load(root, f"qdisc_{label}.json") if x.get("handle") == "10:")
def main():
    p = argparse.ArgumentParser(); p.add_argument("evidence", type=pathlib.Path); p.add_argument("--baseline-trials", type=int, required=True); p.add_argument("--recovery-trials", type=int, required=True); p.add_argument("--baseline-min-mbps", type=float, required=True); p.add_argument("--b-min-mbps", type=float, required=True); p.add_argument("--recovery-ratio", type=float, required=True); p.add_argument("--receiver-min-bps", type=float, required=True); p.add_argument("--max-loss-ratio", type=float, required=True); p.add_argument("--expected-bytes", type=int, required=True); p.add_argument("--expected-sha256", required=True); a = p.parse_args(); root = a.evidence
    baselines = [load(root, f"baseline_{i}.json") for i in range(1, a.baseline_trials + 1)]; recoveries = [load(root, f"recovery_{i}.json") for i in range(1, a.recovery_trials + 1)]; joint = load(root, "joint.json")
    def good(item): return item.get("complete") is True and int(item.get("received_bytes", 0)) == a.expected_bytes and item.get("server_sha256") == a.expected_sha256 and item.get("local_sha256") == a.expected_sha256
    assert all(good(x) for x in baselines), "a B-alone checksum/control trial failed"
    baseline_rates = [float(x["measured_mbps"]) for x in baselines]; assert min(baseline_rates) >= a.baseline_min_mbps, baseline_rates
    assert joint.get("complete") is False, "B unexpectedly completed during A"
    assert int(joint.get("received_bytes", 0)) < a.expected_bytes or float(joint.get("measured_mbps", 0)) < a.b_min_mbps, joint
    assert float(joint.get("measured_mbps", 0)) < min(a.b_min_mbps, statistics.median(baseline_rates) * 0.65), joint
    before, after = load(root, "receiver_before_joint.json"), load(root, "receiver_after_joint.json"); sbefore, safter = load(root, "sender_before_joint.json"), load(root, "sender_after_joint.json")
    assert after.get("healthy") is True and float(after.get("window_bitrate_bps", 0)) >= a.receiver_min_bps, after
    assert float(after.get("loss_ratio", 1)) <= a.max_loss_ratio and float(after.get("sequence_continuity", 0)) >= 1.0 - a.max_loss_ratio, after
    assert int(after.get("valid_packets", 0)) > int(before.get("valid_packets", 0)) and int(after.get("committed_segments", 0)) > int(before.get("committed_segments", 0)), (before, after)
    assert safter.get("healthy") is True and int(safter.get("sent_packets", 0)) > int(sbefore.get("sent_packets", 0)), (sbefore, safter)
    qbefore, qafter = qdisc(root, "before_joint"), qdisc(root, "after_joint"); assert int(qafter.get("bytes", 0)) > int(qbefore.get("bytes", 0)) and int(qafter.get("packets", 0)) > int(qbefore.get("packets", 0)), (qbefore, qafter)
    tcp_before, tcp_after = load(root, "tcp_before_joint.json"), load(root, "tcp_after_joint.json"); drops = int(qafter.get("drops", 0)) - int(qbefore.get("drops", 0)); retrans = int(tcp_after.get("RetransSegs", 0)) - int(tcp_before.get("RetransSegs", 0)); congestion_ratio = float(joint.get("measured_mbps", 0)) / statistics.median(baseline_rates)
    assert drops > 0 or retrans > 0 or congestion_ratio < 0.65, (drops, retrans, congestion_ratio)
    assert all(good(x) for x in recoveries), "a recovery checksum trial failed"
    recovery_rates = [float(x["measured_mbps"]) for x in recoveries]; assert min(recovery_rates) >= statistics.median(baseline_rates) * a.recovery_ratio, (baseline_rates, recovery_rates)
    assert (root / "qdisc_fingerprint_before_joint.txt").read_text().strip() == (root / "qdisc_fingerprint_recovery.txt").read_text().strip(), "traffic policy changed before recovery"
    result = {"baseline_mbps": baseline_rates, "joint_mbps": float(joint.get("measured_mbps", 0)), "joint_bytes": int(joint.get("received_bytes", 0)), "recovery_mbps": recovery_rates, "udp_receiver_bps": float(after.get("window_bitrate_bps", 0)), "udp_loss_ratio": float(after.get("loss_ratio", 1)), "qdisc_drop_delta": drops, "tcp_retrans_delta": retrans, "congestion_ratio": congestion_ratio}
    print(json.dumps(result, sort_keys=True)); print("ANALYSIS_OK=1")
if __name__ == "__main__": main()
