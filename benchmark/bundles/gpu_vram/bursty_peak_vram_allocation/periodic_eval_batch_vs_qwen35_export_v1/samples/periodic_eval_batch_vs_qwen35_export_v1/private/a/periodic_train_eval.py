#!/usr/bin/env python3
import argparse
import json
import math
import os
import pathlib
import time


def read_jsonl(path):
    rows = []
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            if line.strip():
                rows.append(json.loads(line))
    if not rows:
        raise ValueError(f"no rows in {path}")
    return rows


def atomic_json(path, payload):
    tmp = pathlib.Path(str(path) + ".tmp")
    tmp.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(tmp, path)


class StateWriter:
    def __init__(self, run_dir):
        self.run_dir = pathlib.Path(run_dir)
        self.path = self.run_dir / "state.json"
        self.started_at = time.time()
        self.train_steps = 0
        self.eval_batches = 0
        self.phase = "initializing"
        self.last_loss = None
        self.last_eval_loss = None

    def write(self, **updates):
        for key, value in updates.items():
            setattr(self, key, value)
        payload = {
            "phase": self.phase,
            "started_at": self.started_at,
            "heartbeat": time.time(),
            "train_steps": self.train_steps,
            "eval_batches": self.eval_batches,
            "last_loss": self.last_loss,
            "last_eval_loss": self.last_eval_loss,
            "pid": os.getpid(),
        }
        atomic_json(self.path, payload)
        return payload


def build_train_batch(tokenizer, row, seq_len, device):
    text = f"Instruction: {row['instruction']}\nResponse: {row['response']}"
    encoded = tokenizer(
        text,
        max_length=seq_len,
        truncation=True,
        padding="max_length",
        return_tensors="pt",
    )
    labels = encoded["input_ids"].clone()
    labels[encoded["attention_mask"] == 0] = -100
    return {
        "input_ids": encoded["input_ids"].to(device),
        "attention_mask": encoded["attention_mask"].to(device),
        "labels": labels.to(device),
    }


def build_eval_batch(tokenizer, rows, seq_len, batch_size, device, offset):
    texts = []
    for index in range(batch_size):
        row = rows[(offset + index) % len(rows)]
        repeated = (row["text"] + " ") * max(1, math.ceil(seq_len / 16))
        texts.append(repeated)
    encoded = tokenizer(
        texts,
        max_length=seq_len,
        truncation=True,
        padding="max_length",
        return_tensors="pt",
    )
    labels = encoded["input_ids"].clone()
    labels[encoded["attention_mask"] == 0] = -100
    return {
        "input_ids": encoded["input_ids"].to(device),
        "attention_mask": encoded["attention_mask"].to(device),
        "labels": labels.to(device),
    }


def append_metric(path, payload):
    with open(path, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(payload, sort_keys=True) + "\n")
        fh.flush()


def main():
    parser = argparse.ArgumentParser(description="Qwen3.5 periodic training and validation worker.")
    parser.add_argument("--model", required=True)
    parser.add_argument("--train-data", required=True)
    parser.add_argument("--eval-data", required=True)
    parser.add_argument("--run-dir", required=True)
    parser.add_argument("--train-steps", type=int, default=18)
    parser.add_argument("--eval-every-steps", type=int, default=4)
    parser.add_argument("--train-seq-len", type=int, default=4096)
    parser.add_argument("--eval-seq-len", type=int, default=16384)
    parser.add_argument("--train-batch-size", type=int, default=1)
    parser.add_argument("--eval-batch-size", type=int, default=12)
    parser.add_argument("--eval-batches-per-burst", type=int, default=1)
    parser.add_argument("--learning-rate", type=float, default=2e-5)
    parser.add_argument("--seed", type=int, default=20260727)
    args = parser.parse_args()

    os.environ.setdefault("HF_HUB_OFFLINE", "1")
    os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
    os.environ.setdefault("WANDB_DISABLED", "true")
    os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

    run_dir = pathlib.Path(args.run_dir)
    run_dir.mkdir(parents=True, exist_ok=True)
    metric_path = run_dir / "metrics.jsonl"
    state = StateWriter(run_dir)
    state.write()

    import torch
    from peft import LoraConfig, TaskType, get_peft_model
    from transformers import AutoModelForCausalLM, AutoTokenizer

    torch.manual_seed(args.seed)
    if torch.cuda.is_available():
        torch.cuda.manual_seed_all(args.seed)
        torch.cuda.reset_peak_memory_stats()

    tokenizer = AutoTokenizer.from_pretrained(args.model, trust_remote_code=True)
    if tokenizer.pad_token_id is None:
        tokenizer.pad_token = tokenizer.eos_token
    tokenizer.padding_side = "right"

    model = AutoModelForCausalLM.from_pretrained(
        args.model,
        torch_dtype=torch.bfloat16,
        device_map={"": 0},
        trust_remote_code=True,
    )
    model.gradient_checkpointing_enable()
    model.config.use_cache = False

    lora = LoraConfig(
        r=8,
        lora_alpha=16,
        lora_dropout=0.05,
        bias="none",
        task_type=TaskType.CAUSAL_LM,
        target_modules=["q_proj", "k_proj", "v_proj", "o_proj", "gate_proj", "up_proj", "down_proj"],
    )
    model = get_peft_model(model, lora)
    model.train()

    optimizer = torch.optim.AdamW([p for p in model.parameters() if p.requires_grad], lr=args.learning_rate)
    train_rows = read_jsonl(args.train_data)
    eval_rows = read_jsonl(args.eval_data)
    state.write(phase="model_loaded")

    for step in range(1, args.train_steps + 1):
        state.write(phase="train_low", train_steps=step - 1)
        optimizer.zero_grad(set_to_none=True)
        losses = []
        for micro in range(args.train_batch_size):
            row = train_rows[(step + micro) % len(train_rows)]
            batch = build_train_batch(tokenizer, row, args.train_seq_len, model.device)
            output = model(**batch)
            loss = output.loss / max(1, args.train_batch_size)
            loss.backward()
            losses.append(float(loss.detach().cpu()) * max(1, args.train_batch_size))
            del batch, output, loss
        optimizer.step()
        if torch.cuda.is_available():
            torch.cuda.synchronize()
        train_peak = None
        if torch.cuda.is_available():
            train_peak = round(torch.cuda.max_memory_allocated() / (1024 * 1024), 2)
        last_loss = sum(losses) / len(losses)
        state.write(phase="train_low", train_steps=step, last_loss=last_loss)
        append_metric(metric_path, {
            "event": "train_step",
            "step": step,
            "loss": last_loss,
            "timestamp": time.time(),
            "peak_cuda_memory_mb": train_peak,
        })

        if step % args.eval_every_steps == 0:
            model.eval()
            if torch.cuda.is_available():
                torch.cuda.reset_peak_memory_stats()
            state.write(phase="eval_preparing", train_steps=step)
            eval_loss = None
            for burst_index in range(max(1, args.eval_batches_per_burst)):
                eval_batch = build_eval_batch(
                    tokenizer,
                    eval_rows,
                    args.eval_seq_len,
                    args.eval_batch_size,
                    model.device,
                    state.eval_batches,
                )
                state.write(phase="eval_peak_active", train_steps=step)
                with torch.inference_mode():
                    eval_output = model(**eval_batch)
                    eval_loss = float(eval_output.loss.detach().cpu())
                if torch.cuda.is_available():
                    torch.cuda.synchronize()
                    eval_peak = round(torch.cuda.max_memory_allocated() / (1024 * 1024), 2)
                else:
                    eval_peak = None
                del eval_batch, eval_output
                completed_eval_batches = state.eval_batches + 1
                state.write(
                    phase="eval_peak_active",
                    train_steps=step,
                    eval_batches=completed_eval_batches,
                    last_eval_loss=eval_loss,
                )
                append_metric(metric_path, {
                    "event": "eval_batch",
                    "step": step,
                    "eval_batch": completed_eval_batches,
                    "burst_batch": burst_index + 1,
                    "burst_size": max(1, args.eval_batches_per_burst),
                    "eval_loss": eval_loss,
                    "timestamp": time.time(),
                    "peak_cuda_memory_mb": eval_peak,
                    "eval_seq_len": args.eval_seq_len,
                    "eval_batch_size": args.eval_batch_size,
                })
            if torch.cuda.is_available():
                torch.cuda.empty_cache()
            state.write(
                phase="eval_complete",
                train_steps=step,
                last_eval_loss=eval_loss,
            )
            model.train()

    adapter_dir = run_dir / "adapter"
    model.save_pretrained(adapter_dir)
    tokenizer.save_pretrained(adapter_dir)
    state.write(phase="complete")
    (run_dir / "COMPLETE").write_text("training and periodic validation complete\n", encoding="utf-8")


if __name__ == "__main__":
    main()
