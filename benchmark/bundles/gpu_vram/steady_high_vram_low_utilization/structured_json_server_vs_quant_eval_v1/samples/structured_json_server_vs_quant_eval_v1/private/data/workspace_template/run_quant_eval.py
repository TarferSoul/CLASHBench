#!/usr/bin/env python3
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import sys
import time


def read_jsonl(path):
    rows = []
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    tmp.replace(path)


def write_jsonl(path, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with open(tmp, "w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, sort_keys=True) + "\n")
    tmp.replace(path)


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def cuda_oom(exc):
    text = f"{type(exc).__name__}: {exc}".lower()
    return "cuda" in text and ("out of memory" in text or "oom" in text or "allocation" in text)


def load_model(model_path, device):
    import torch
    from transformers import AutoModelForCausalLM, AutoTokenizer

    tokenizer = AutoTokenizer.from_pretrained(model_path, trust_remote_code=True)
    if tokenizer.pad_token_id is None:
        tokenizer.pad_token = tokenizer.eos_token

    kwargs = {
        "torch_dtype": torch.bfloat16,
        "trust_remote_code": True,
        "low_cpu_mem_usage": True,
    }
    try:
        model = AutoModelForCausalLM.from_pretrained(
            model_path,
            device_map={"": device},
            **kwargs,
        )
    except Exception as exc:
        if cuda_oom(exc):
            raise
        print(f"device_map load failed, retrying with explicit .to({device}): {exc}", flush=True)
        kwargs.pop("low_cpu_mem_usage", None)
        model = AutoModelForCausalLM.from_pretrained(model_path, **kwargs)
        model.to(device)

    model.eval()
    return tokenizer, model


def collect_calibration(model, tokenizer, rows, args, device):
    import torch

    observed = {}
    handles = []

    def make_hook(name):
        def hook(_module, _inputs, output):
            tensor = output[0] if isinstance(output, tuple) else output
            if hasattr(tensor, "detach"):
                value = float(tensor.detach().abs().amax().float().cpu().item())
                observed[name] = max(value, observed.get(name, 0.0))
        return hook

    for name, module in model.named_modules():
        if module.__class__.__name__ == "Linear":
            handles.append(module.register_forward_hook(make_hook(name)))
            if len(handles) >= args.max_observer_layers:
                break

    started = time.time()
    sample_rows = rows[: args.calibration_samples]
    for offset in range(0, len(sample_rows), args.calibration_batch_size):
        batch = sample_rows[offset : offset + args.calibration_batch_size]
        texts = [row["text"] for row in batch]
        enc = tokenizer(
            texts,
            return_tensors="pt",
            padding="max_length",
            truncation=True,
            max_length=args.calibration_max_length,
        )
        enc = {key: value.to(device) for key, value in enc.items()}
        with torch.no_grad():
            model(**enc, use_cache=True)
        torch.cuda.synchronize()

    for handle in handles:
        handle.remove()

    scales = [
        {
            "name": name,
            "activation_absmax": round(value, 6),
            "symmetric_int8_scale": round(max(value / 127.0, 1e-8), 10),
        }
        for name, value in sorted(observed.items())
    ]
    return {
        "samples": len(sample_rows),
        "layers_observed": len(scales),
        "elapsed_seconds": round(time.time() - started, 3),
        "scales": scales,
    }


def choice_nll(model, tokenizer, prompt, choice, args, device, quantize_logits=False):
    import torch
    import torch.nn.functional as F

    prefix = f"{prompt}\nAnswer:"
    text = f"{prefix} {choice}"
    full = tokenizer(
        text,
        return_tensors="pt",
        truncation=True,
        max_length=args.eval_max_length,
    )
    prefix_ids = tokenizer(
        prefix,
        return_tensors="pt",
        truncation=True,
        max_length=args.eval_max_length,
    )["input_ids"]

    full = {key: value.to(device) for key, value in full.items()}
    with torch.no_grad():
        out = model(**full, use_cache=False)

    logits = out.logits[:, :-1, :]
    if quantize_logits:
        scale = logits.detach().abs().amax(dim=-1, keepdim=True).clamp(min=1e-6) / 127.0
        logits = (logits / scale).round().clamp(-127, 127) * scale
    labels = full["input_ids"][:, 1:]
    losses = F.cross_entropy(
        logits.reshape(-1, logits.shape[-1]).float(),
        labels.reshape(-1),
        reduction="none",
    ).reshape(labels.shape)

    start = max(int(prefix_ids.shape[1]) - 1, 0)
    mask = torch.arange(labels.shape[1], device=device) >= start
    if not bool(mask.any()):
        mask[-1] = True
    return float(losses[:, mask].mean().detach().cpu().item())


def evaluate(model, tokenizer, rows, args, device, quantize_logits):
    predictions = []
    correct = 0
    for row in rows[: args.eval_samples]:
        scores = []
        for choice in row["choices"]:
            scores.append(choice_nll(model, tokenizer, row["prompt"], choice, args, device, quantize_logits))
        pred = min(range(len(scores)), key=lambda idx: scores[idx])
        ok = int(pred == int(row["answer"]))
        correct += ok
        predictions.append({
            "id": row["id"],
            "prediction": pred,
            "answer": int(row["answer"]),
            "correct": ok,
            "scores": [round(score, 6) for score in scores],
            "mode": "int8_logit" if quantize_logits else "bf16",
        })
    accuracy = correct / max(len(predictions), 1)
    return predictions, accuracy


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", default="/models/Qwen3.5-4B")
    parser.add_argument("--input-dir", default="/work/qwen35_quant_eval/inputs")
    parser.add_argument("--output-dir", default="/work/qwen35_quant_eval/results")
    parser.add_argument("--calibration-samples", type=int, default=8)
    parser.add_argument("--eval-samples", type=int, default=6)
    parser.add_argument("--calibration-max-length", type=int, default=8192)
    parser.add_argument("--eval-max-length", type=int, default=2048)
    parser.add_argument("--calibration-batch-size", type=int, default=4)
    parser.add_argument("--max-observer-layers", type=int, default=24)
    args = parser.parse_args()

    out = Path(args.output_dir)
    out.mkdir(parents=True, exist_ok=True)
    failure_path = out / "run_failure.json"
    start = time.time()

    try:
        import torch

        if not torch.cuda.is_available():
            raise RuntimeError("CUDA is required for this calibration run")
        device = "cuda:0"
        torch.cuda.reset_peak_memory_stats()

        calibration_path = Path(args.input_dir) / "calibration_prompts.jsonl"
        eval_path = Path(args.input_dir) / "eval_prompts.jsonl"
        calibration_rows = read_jsonl(calibration_path)
        eval_rows = read_jsonl(eval_path)

        tokenizer, model = load_model(args.model, device)
        calibration = collect_calibration(model, tokenizer, calibration_rows, args, device)

        scale_path = out / "activation_scales.json"
        write_json(scale_path, {
            "model": os.path.realpath(args.model),
            "method": "activation_observer_symmetric_int8",
            "calibration": calibration,
        })

        baseline_rows, baseline_accuracy = evaluate(model, tokenizer, eval_rows, args, device, quantize_logits=False)
        quant_rows, quant_accuracy = evaluate(model, tokenizer, eval_rows, args, device, quantize_logits=True)
        torch.cuda.synchronize()
        peak_mb = int(torch.cuda.max_memory_allocated() // (1024 * 1024))

        baseline_path = out / "baseline_predictions.jsonl"
        quantized_path = out / "quantized_predictions.jsonl"
        write_jsonl(baseline_path, baseline_rows)
        write_jsonl(quantized_path, quant_rows)

        calibration_report = {
            "status": "completed",
            "model_path": os.path.realpath(args.model),
            "device": device,
            "torch_dtype": "bfloat16",
            "calibration_samples": calibration["samples"],
            "observer_layers": calibration["layers_observed"],
            "calibration_max_length": args.calibration_max_length,
            "calibration_batch_size": args.calibration_batch_size,
            "activation_scales_file": str(scale_path),
            "activation_scales_sha256": sha256_file(scale_path),
            "peak_cuda_vram_mb": peak_mb,
            "elapsed_seconds": round(time.time() - start, 3),
        }
        comparison_report = {
            "status": "completed",
            "model_path": os.path.realpath(args.model),
            "device": device,
            "eval_examples": len(baseline_rows),
            "baseline_accuracy": round(baseline_accuracy, 6),
            "quantized_accuracy": round(quant_accuracy, 6),
            "accuracy_delta": round(abs(baseline_accuracy - quant_accuracy), 6),
            "baseline_predictions": str(baseline_path),
            "quantized_predictions": str(quantized_path),
            "method": "bf16_vs_calibrated_int8_logit_comparison",
            "peak_cuda_vram_mb": peak_mb,
            "completed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }
        write_json(out / "calibration_report.json", calibration_report)
        write_json(out / "comparison_report.json", comparison_report)
        write_json(out / "run_manifest.json", {
            "status": "completed",
            "inputs": {
                "calibration_prompts": str(calibration_path),
                "eval_prompts": str(eval_path),
            },
            "outputs": {
                "calibration_report": str(out / "calibration_report.json"),
                "comparison_report": str(out / "comparison_report.json"),
            },
        })
        print(json.dumps({"status": "completed", "peak_cuda_vram_mb": peak_mb, "eval_examples": len(baseline_rows)}, sort_keys=True))
        return 0
    except Exception as exc:
        failure = {
            "status": "failed",
            "error_type": type(exc).__name__,
            "error": str(exc),
            "cuda_oom": cuda_oom(exc),
            "elapsed_seconds": round(time.time() - start, 3),
        }
        write_json(failure_path, failure)
        print(json.dumps(failure, sort_keys=True), file=sys.stderr)
        return 42 if failure["cuda_oom"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
