#!/usr/bin/env python3
"""convert_bgem3.py — BAAI/bge-m3 → CoreML mlpackage for the swctx embedder.

XLMRobertaModel (24L/1024H, ~568M params). Dense convention per
FlagEmbedding/model card: CLS token of last_hidden_state → L2 normalize.
The norm is traced into the graph so the CoreML output is already
unit-length — dot product of two outputs equals cosine.

Same tokenizer family as bge-reranker-v2-m3 (sentencepiece.bpe.model,
fairseq +1 id offset — SPTokenizer.swift already encodes it byte-exact).
No token_type_ids (type_vocab_size=1). 1024-dim output.

Recipe mirrors bench/convert_reranker_v2m3.py (torch trace → mlprogram
fp16). Same venv: /tmp/swctx-rerank-venv (torch 2.14 + transformers
4.46.3 + coremltools 9.0).

Usage:
    /tmp/swctx-rerank-venv/bin/python3 bench/convert_bgem3.py \
        --out ~/.swctx/models/bge-m3/model.mlpackage [--install]
"""

import argparse
import os
import shutil

import numpy as np
import torch
import coremltools as ct
from coremltools import RangeDim, TensorType
from transformers import AutoModel, AutoTokenizer

HF_ID = "BAAI/bge-m3"
VOCAB = 250002


class CLSEmbedding(torch.nn.Module):
    """XLMRobertaModel → L2-normalized CLS vector [1,1024]. Inputs arrive
    as int32 and are cast to long — the cast is traced in."""

    def __init__(self, src):
        super().__init__()
        self.model = AutoModel.from_pretrained(src)
        self.model.eval()

    def forward(self, input_ids, attention_mask):
        hs = self.model(
            input_ids=input_ids.long(),
            attention_mask=attention_mask.long(),
        ).last_hidden_state
        cls = hs[:, 0]
        return torch.nn.functional.normalize(cls, p=2, dim=1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=HF_ID,
                    help="local dir with config.json+pytorch_model.bin, or HF id")
    ap.add_argument("--out", required=True, help="output model.mlpackage path")
    ap.add_argument("--precision", default="float16",
                    choices=["float16", "float32"])
    ap.add_argument("--max-seq", type=int, default=512,
                    help="upper bound of the RangeDim sequence axis")
    ap.add_argument("--install", action="store_true",
                    help="copy sentencepiece.bpe.model next to the mlpackage")
    args = ap.parse_args()

    src = args.src if os.path.isdir(args.src) else HF_ID
    wrapper = CLSEmbedding(src)
    tok = AutoTokenizer.from_pretrained(src)

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
        outputs=[TensorType(name="embedding")],
        compute_precision=prec,
        minimum_deployment_target=ct.target.macOS15,
        convert_to="mlprogram",
    )
    out = os.path.expanduser(args.out)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    ml.save(out)
    print(f"saved {out}")

    # ---- parity check: HF CLS embedding vs CoreML on real texts ----
    import coremltools.models as ctm
    m = ctm.MLModel(out)
    texts = [
        "script kiểm tra canonical url cho toàn bộ bài viết",
        "def check_canonical(url):\n    return requests.head(url).status_code",
        "middleware gác cửa kiểm tra đăng nhập bằng vân tay passkey",
        "# Workflow\n\nCác bước push nội dung: viết → review → publish.",
    ]
    max_diff = 0.0
    for t in texts:
        enc = tok(t, truncation=True, max_length=512, return_tensors="np")
        hf = wrapper(
            torch.tensor(enc["input_ids"], dtype=torch.int32),
            torch.tensor(enc["attention_mask"], dtype=torch.int32),
        ).detach().numpy()[0]
        cl = np.asarray(m.predict({
            "input_ids": enc["input_ids"].astype(np.int32),
            "attention_mask": enc["attention_mask"].astype(np.int32),
        })["embedding"])[0]
        cos = float(hf @ cl / (np.linalg.norm(hf) * np.linalg.norm(cl) + 1e-9))
        d1 = float(np.abs(hf - cl).max())
        max_diff = max(max_diff, d1)
        print(f"  cos(HF,CL)={cos:.6f} max|d|={d1:.5f} |CL|={np.linalg.norm(cl):.4f}")
    print(f"max abs diff {max_diff:.5f} ({'OK' if max_diff < 0.05 else 'MISMATCH'})")

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
