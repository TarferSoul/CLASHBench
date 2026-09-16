#!/usr/bin/env python3
"""Export deterministic top-logit summaries for a sharded prompt suite."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import time
from typing import Iterable


def read_jsonl(path: pathlib.Path) -> list[dict]:
    rows: list[dict] = []
    with path.open("r", encoding="utf-8") as handle:
        for line_no, line in enumerate(handle, 1):
            line = line.strip()
            if not line:
                continue
            item = json.loads(line)
            item["_source_line"] = line_no
            rows.append(item)
    return rows


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def iter_batches(rows: list[dict], batch_size: int) -> Iterable[list[dict]]:
    for start in range(0, len(rows), batch_size):
        yield rows[start : start + batch_size]


def normalize_prompt(row: dict) -> str:
    prompt = str(row.get("prompt", ""))
    target = str(row.get("target", ""))
    return (
        "You are evaluating a code-agent operations answer.\n\n"
        f"Prompt:\n{prompt}\n\n"
        "Return a concise answer that preserves the operational constraint."
        f"\nReference style hint:\n{target[:512]}"
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--suite", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--batch-size", type=int, default=2)
    parser.add_argument("--max-length", type=int, default=32768)
    parser.add_argument("--top-k", type=int, default=8)
    parser.add_argument("--dtype", choices=["auto", "bfloat16", "float16"], default="bfloat16")
    parser.add_argument("--device", default="cuda")
    args = parser.parse_args()

    suite = pathlib.Path(args.suite).resolve()
    output = pathlib.Path(args.output).resolve()
    shard_out = output / "shards"
    shard_out.mkdir(parents=True, exist_ok=True)

    import torch
    from transformers import AutoModelForCausalLM, AutoTokenizer

    dtype = {
        "auto": "auto",
        "bfloat16": torch.bfloat16,
        "float16": torch.float16,
    }[args.dtype]

    tokenizer = AutoTokenizer.from_pretrained(args.model, trust_remote_code=True)
    if tokenizer.pad_token_id is None:
        tokenizer.pad_token = tokenizer.eos_token
    model = AutoModelForCausalLM.from_pretrained(
        args.model,
        torch_dtype=dtype,
        trust_remote_code=True,
        low_cpu_mem_usage=True,
    )
    model.to(args.device)
    model.eval()

    manifest_rows = []
    total_rows = 0
    started = time.time()
    shard_paths = sorted(suite.glob("shard_*.jsonl"))
    if not shard_paths:
        raise SystemExit(f"no shard_*.jsonl files found under {suite}")

    for shard_path in shard_paths:
        rows = read_jsonl(shard_path)
        out_path = shard_out / f"{shard_path.stem}_logits.jsonl"
        tmp_path = out_path.with_suffix(out_path.suffix + ".tmp")
        shard_count = 0
        with tmp_path.open("w", encoding="utf-8") as handle:
            for batch in iter_batches(rows, args.batch_size):
                prompts = [normalize_prompt(row) for row in batch]
                encoded = tokenizer(
                    prompts,
                    return_tensors="pt",
                    padding=True,
                    truncation=True,
                    max_length=args.max_length,
                )
                encoded = {key: value.to(args.device) for key, value in encoded.items()}
                with torch.inference_mode():
                    result = model(**encoded)
                    last_positions = encoded["attention_mask"].sum(dim=1) - 1
                    logits = result.logits[torch.arange(len(batch), device=args.device), last_positions]
                    values, indices = torch.topk(logits.float(), k=args.top_k, dim=-1)
                for row, token_ids, token_logits in zip(batch, indices.cpu().tolist(), values.cpu().tolist()):
                    record = {
                        "id": row["id"],
                        "source_shard": shard_path.name,
                        "top_token_ids": token_ids,
                        "top_logits": [round(float(value), 6) for value in token_logits],
                    }
                    handle.write(json.dumps(record, sort_keys=True) + "\n")
                    shard_count += 1
        os.replace(tmp_path, out_path)
        digest = sha256_file(out_path)
        manifest_rows.append(
            {
                "shard": shard_path.name,
                "output": f"shards/{out_path.name}",
                "rows": shard_count,
                "sha256": digest,
            }
        )
        total_rows += shard_count

    manifest = {
        "model_path": str(pathlib.Path(args.model).resolve()),
        "suite_path": str(suite),
        "completed_shards": len(manifest_rows),
        "total_rows": total_rows,
        "batch_size": args.batch_size,
        "max_length": args.max_length,
        "top_k": args.top_k,
        "device": args.device,
        "shards": manifest_rows,
        "completed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    summary = {
        "status": "complete",
        "elapsed_seconds": round(time.time() - started, 3),
        "completed_shards": len(manifest_rows),
        "total_rows": total_rows,
        "suite_sha256": hashlib.sha256(
            "".join(sha256_file(path) for path in shard_paths).encode("utf-8")
        ).hexdigest(),
    }
    (output / "summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    with (output / "checksums.sha256").open("w", encoding="utf-8") as handle:
        for row in manifest_rows:
            handle.write(f"{row['sha256']}  {row['output']}\n")
    print(json.dumps(summary, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
