#!/usr/bin/env python3
"""convert_reranker_v2m3.py — BAAI/bge-reranker-v2-m3 → CoreML mlpackage
for the swctx reranker-v2 spike.

XLMRobertaForSequenceClassification (bge-m3 backbone, 24L/1024H,
~568M params, ONE relevance logit — score = logit[0]; FlagEmbedding
applies sigmoid for probabilities but raw-logit ordering is identical).

The converted model takes TWO inputs — input_ids + attention_mask —
because XLM-R has no token_type_ids (type_vocab_size=1). Pair encoding
is XLM-R convention: <s> q </s></s> d </s> (built in RerankerV2.swift
from SPTokenizer ids with the +1 fairseq offset and <unk>→3).

Tokenizer note (verified against the real spm model):
  sentencepiece.bpe.model piece ids are HF ids - 1 for all normal
  pieces; <unk>(spm 0) → HF 3; controls <s>/<pad>/</s> → HF 0/1/2.
  byte pieces: none in this vocab (byte_fallback off).

Shape notes: (1, RangeDim(1,1024)) per input, int32 — same as
convert_reranker.py; batch stays 1 (dynamic batch produced
input-invariant logits on the amberoad conversion, so Swift batches
via predictions(fromBatch:) here too).

Recipe mirrors bench/convert_reranker.py (torch trace → mlprogram fp16).
Same venv: torch 2.14.0 + transformers 4.46.3 + coremltools 9.0.

Usage:
    python3 bench/convert_reranker_v2m3.py [--src /tmp/bge-reranker-v2-m3-hf] \
        [--out <dir>/model.mlpackage] [--precision float16|float32] [--install]
"""

import argparse
import os
import shutil

import numpy as np
import torch
import coremltools as ct
from coremltools import RangeDim, TensorType
from transformers import XLMRobertaForSequenceClassification, XLMRobertaTokenizer

HF_ID = "BAAI/bge-reranker-v2-m3"
VOCAB = 250002


class PairLogits(torch.nn.Module):
    """XLMRobertaForSequenceClassification → bare logits [1,1]. Inputs
    arrive as int32 and are cast to long — the cast is traced in."""

    def __init__(self, src):
        super().__init__()
        self.model = XLMRobertaForSequenceClassification.from_pretrained(src)
        self.model.eval()

    def forward(self, input_ids, attention_mask):
        out = self.model(
            input_ids=input_ids.long(),
            attention_mask=attention_mask.long(),
        )
        return out.logits


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default="/tmp/bge-reranker-v2-m3-hf",
                    help="local dir with config.json+model.safetensors, or HF id")
    ap.add_argument("--out", required=True, help="output model.mlpackage path")
    ap.add_argument("--precision", default="float16",
                    choices=["float16", "float32"])
    ap.add_argument("--max-seq", type=int, default=1024,
                    help="upper bound of the RangeDim sequence axis")
    ap.add_argument("--install", action="store_true",
                    help="copy sentencepiece.bpe.model next to the mlpackage")
    args = ap.parse_args()

    src = args.src if os.path.isdir(args.src) else HF_ID
    wrapper = PairLogits(src)
    tok = XLMRobertaTokenizer.from_pretrained(src)

    b, s = 1, 32
    ids = torch.randint(0, VOCAB, (b, s), dtype=torch.int32)
    mask = torch.ones((b, s), dtype=torch.int32)
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, (ids, mask))

    seq = RangeDim(1, args.max_seq)
    prec = ct.precision.FLOAT16 if args.precision == "float16" else ct.precision.FLOAT32
    ml = ct.convert(
        traced,
        inputs=[
            TensorType(name="input_ids", shape=(1, seq), dtype=np.int32),
            TensorType(name="attention_mask", shape=(1, seq), dtype=np.int32),
        ],
        outputs=[TensorType(name="logits")],
        compute_precision=prec,
        minimum_deployment_target=ct.target.macOS15,
        convert_to="mlprogram",
    )
    out = os.path.expanduser(args.out)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    ml.save(out)
    print(f"saved {out}")

    # ---- parity check: HF logits vs CoreML logits on real pairs ----
    import coremltools.models as ctm
    m = ctm.MLModel(out)
    pairs = [
        ("script kiểm tra canonical url",
         "scripts/p8_canonical_check.py\ncheck_canonical\nCheck whether google "
         "is selecting a different canonical URL than declared in the page head."),
        ("script kiểm tra canonical url",
         "def format_fragment(lead):\n    return f'new lead: {lead}'"),
        ("middleware gác cửa kiểm tra đăng nhập bằng vân tay passkey",
         "export async function onRequest(context) {\n  // verify WebAuthn "
         "passkey assertion before allowing access\n}"),
        ("tài liệu quy trình chuẩn để push nội dung bài viết lên site",
         "# Workflow\n\nCác bước push nội dung: viết → review → publish."),
    ]
    max_diff = 0.0
    for q, d in pairs:
        enc = tok(q, d, truncation="longest_first", max_length=512,
                  return_tensors="np")
        hf = wrapper(
            torch.tensor(enc["input_ids"], dtype=torch.int32),
            torch.tensor(enc["attention_mask"], dtype=torch.int32),
        ).detach().numpy()[0]
        cl = np.asarray(m.predict({
            "input_ids": enc["input_ids"].astype(np.int32),
            "attention_mask": enc["attention_mask"].astype(np.int32),
        })["logits"])[0]
        d1 = float(np.abs(hf - cl).max())
        max_diff = max(max_diff, d1)
        print(f"  HF {hf.tolist()}  CL {cl.tolist()}  diff {d1:.4f}")
    print(f"max abs diff {max_diff:.4f} ({'OK' if max_diff < 0.05 else 'MISMATCH'})")

    if args.install:
        dst = os.path.join(os.path.dirname(out), "sentencepiece.bpe.model")
        src_spm = os.path.join(args.src, "sentencepiece.bpe.model") \
            if os.path.isdir(args.src) else None
        if src_spm and os.path.exists(src_spm):
            shutil.copyfile(src_spm, dst)
        else:
            from huggingface_hub import hf_hub_download
            shutil.copyfile(
                hf_hub_download(HF_ID, "sentencepiece.bpe.model"), dst)
        print(f"installed sentencepiece.bpe.model → {dst}")


if __name__ == "__main__":
    main()
