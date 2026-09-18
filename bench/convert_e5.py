#!/usr/bin/env python3
"""convert_e5.py — intfloat/multilingual-e5-base → CoreML mlpackage.

XLMRobertaModel backbone (12L/768H, 278M params). Sentence-transformers
e5 convention: MEAN pooling over non-pad tokens (attention-mask weighted)
→ L2 normalize, traced into the graph so the CoreML output is unit-length.

NOTE: e5 requires prefixes — "query: " for queries, "passage: " for
documents — applied in Swift via spec.queryPrefix/docPrefix, NOT here.

Same XLM-R sentencepiece.bpe.model family as bge-m3 (verified identical
piece-for-piece in the jina spike). Venv: /tmp/swctx-rerank-venv.

Usage:
    /tmp/swctx-rerank-venv/bin/python3 bench/convert_e5.py \
        --out ~/.swctx/models/multilingual-e5-base/model.mlpackage --install
"""

import argparse
import os
import shutil

import numpy as np
import torch
import coremltools as ct
from coremltools import RangeDim, TensorType
from transformers import AutoModel, AutoTokenizer

HF_ID = "intfloat/multilingual-e5-base"
VOCAB = 250002


class MeanEmbedding(torch.nn.Module):
    """XLMRobertaModel → attention-mask mean pool → L2 norm → [1,768].
    Inputs arrive as int32 and are cast to long — the cast is traced in."""

    def __init__(self, src):
        super().__init__()
        self.model = AutoModel.from_pretrained(src)
        self.model.eval()

    def forward(self, input_ids, attention_mask):
        hs = self.model(
            input_ids=input_ids.long(),
            attention_mask=attention_mask.long(),
        ).last_hidden_state
        m = attention_mask.unsqueeze(-1).float()
        pooled = (hs * m).sum(dim=1) / m.sum(dim=1).clamp(min=1e-9)
        return torch.nn.functional.normalize(pooled, p=2, dim=1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default=HF_ID)
    ap.add_argument("--out", required=True)
    ap.add_argument("--precision", default="float16",
                    choices=["float16", "float32"])
    ap.add_argument("--max-seq", type=int, default=512)
    ap.add_argument("--install", action="store_true")
    args = ap.parse_args()

    src = args.src if os.path.isdir(args.src) else HF_ID
    wrapper = MeanEmbedding(src)
    tok = AutoTokenizer.from_pretrained(src)

    ids = torch.randint(0, VOCAB, (1, 32), dtype=torch.int32)
    mask = torch.ones((1, 32), dtype=torch.int32)
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

    # Parity: HF mean-pool vs CoreML on real texts (prefixes applied here
    # exactly as production: passage: for docs, query: for queries).
    import coremltools.models as ctm
    m = ctm.MLModel(out)
    texts = [
        "passage: def check_canonical(url):\n    return requests.head(url)",
        "passage: # Workflow\n\nCác bước push nội dung: viết → publish.",
        "query: script kiểm tra canonical url cho toàn bộ bài viết",
        "query: middleware gác cửa kiểm tra đăng nhập bằng vân tay passkey",
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
        print(f"  cos={cos:.6f} max|d|={d1:.5f} |CL|={np.linalg.norm(cl):.4f}")
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
