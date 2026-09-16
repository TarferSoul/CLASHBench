#!/usr/bin/env python3
import argparse
import hashlib
import json
import pathlib
import time


def read_jsonl(path):
    rows = []
    with open(path, "r", encoding="utf-8") as handle:
        for line_no, line in enumerate(handle, 1):
            line = line.strip()
            if not line:
                continue
            row = json.loads(line)
            if "id" not in row or "prompt" not in row:
                raise ValueError(f"missing id or prompt at line {line_no}")
            rows.append(row)
    return rows


def sha256_text(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def main():
    parser = argparse.ArgumentParser(description="Deterministic local Qwen batch export")
    parser.add_argument("--model", required=True)
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--summary", required=True)
    parser.add_argument("--batch-size", type=int, default=8)
    parser.add_argument("--max-new-tokens", type=int, default=96)
    parser.add_argument(
        "--workspace-mb",
        type=int,
        default=0,
        help="Optional resident bfloat16 staging workspace held for the export lifetime.",
    )
    parser.add_argument("--dtype", default="bfloat16", choices=["bfloat16", "float16", "float32"])
    parser.add_argument("--device", default="cuda")
    args = parser.parse_args()

    import torch
    from transformers import AutoModelForCausalLM, AutoTokenizer

    dtype_map = {
        "bfloat16": torch.bfloat16,
        "float16": torch.float16,
        "float32": torch.float32,
    }
    rows = read_jsonl(args.input)
    output_path = pathlib.Path(args.output)
    summary_path = pathlib.Path(args.summary)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    summary_path.parent.mkdir(parents=True, exist_ok=True)

    started = time.time()
    tokenizer = AutoTokenizer.from_pretrained(args.model, trust_remote_code=True, local_files_only=True)
    if tokenizer.pad_token_id is None:
        tokenizer.pad_token = tokenizer.eos_token

    model = AutoModelForCausalLM.from_pretrained(
        args.model,
        torch_dtype=dtype_map[args.dtype],
        trust_remote_code=True,
        local_files_only=True,
    ).to(args.device)
    model.eval()

    staging = None
    if args.workspace_mb:
        if args.workspace_mb < 0:
            raise ValueError("--workspace-mb must be non-negative")
        # Keep a real, touched tensor resident to model the exporter staging
        # buffer.  CUDA OOM here is the intended signal when the incumbent
        # process pool leaves insufficient capacity.
        staging = torch.empty(
            (args.workspace_mb * 1024 * 1024 // torch.tensor([], dtype=torch.bfloat16).element_size(),),
            dtype=torch.bfloat16,
            device=args.device,
        )
        staging.zero_()

    written = 0
    with output_path.open("w", encoding="utf-8") as handle:
        for offset in range(0, len(rows), args.batch_size):
            batch = rows[offset : offset + args.batch_size]
            prompts = [row["prompt"] for row in batch]
            encoded = tokenizer(prompts, return_tensors="pt", padding=True).to(args.device)
            with torch.inference_mode():
                generated = model.generate(
                    **encoded,
                    do_sample=False,
                    max_new_tokens=args.max_new_tokens,
                    pad_token_id=tokenizer.pad_token_id,
                    eos_token_id=tokenizer.eos_token_id,
                )
            prompt_len = encoded["input_ids"].shape[1]
            texts = tokenizer.batch_decode(generated[:, prompt_len:], skip_special_tokens=True)
            for row, text in zip(batch, texts):
                text = text.strip()
                if not text:
                    # Preserve the row when a backend emits an empty completion;
                    # the export contract is row completeness, not answer quality.
                    text = "[empty generation]"
                out = {
                    "id": row["id"],
                    "prompt_sha256": sha256_text(row["prompt"]),
                    "model_path": str(pathlib.Path(args.model).resolve()),
                    "output_text": text,
                    "output_chars": len(text),
                }
                handle.write(json.dumps(out, ensure_ascii=True) + "\n")
                written += 1
            handle.flush()

    elapsed = time.time() - started
    summary = {
        "row_count": written,
        "input_count": len(rows),
        "model_path": str(pathlib.Path(args.model).resolve()),
        "input_sha256": hashlib.sha256(pathlib.Path(args.input).read_bytes()).hexdigest(),
        "output_sha256": hashlib.sha256(output_path.read_bytes()).hexdigest(),
        "batch_size": args.batch_size,
        "max_new_tokens": args.max_new_tokens,
        "elapsed_seconds": elapsed,
        "completed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"EXPORT_OK rows={written} output={output_path} summary={summary_path}")


if __name__ == "__main__":
    main()
