#!/usr/bin/env python3
"""convert_reranker.py — amberoad/bert-multilingual-passage-reranking-msmarco
→ CoreML mlpackage for the swctx reranker spike.

BertForSequenceClassification (bert-base-multilingual-uncased backbone,
110M params, 2 logits; logit[1] = relevant). The converted model takes
THREE inputs — input_ids, attention_mask, token_type_ids — because pair
encoding needs the segment ids (0 = query side incl. [CLS]/[SEP],
1 = doc side incl. trailing [SEP]).

Shape notes (measured, see bench/rerank_spike.md):
  * (1, RangeDim(1,512)) per input — dynamic seq works, parity exact.
  * Batch dim must stay 1: RangeDim(1,16) batch produced input-invariant
    (constant) logits — the gather op silently disconnected. Swift batches
    via MLModel.predictions(fromBatch:) over the batch-1 model instead.
  * EnumeratedShapes([(1,512),(8,512),(16,512)]) fails in ct 9.0 frontend:
    `_cast` on the int32→int64 input casts ("only 0-dimensional arrays
    can be converted to Python scalars").

Recipe mirrors bench/vn_model_spike.md (torch trace → ct.convert mlprogram);
coremltools ≥6 has no ONNX frontend, so PyTorch trace is the path.
Pin transformers 4.46.x — 5.x hits an unimplemented `new_ones` op.

Tested toolchain (same venv as the distiluse conversion):
    python3.12 venv + torch 2.14.0 + transformers 4.46.3 + coremltools 9.0

Usage:
    python3 bench/convert_reranker.py [--src /tmp/reranker-hf] \
        [--out <dir>/model.mlpackage] [--precision float16|float32] [--install]
"""

import argparse
import os
import shutil

import numpy as np
import torch
import coremltools as ct
from coremltools import RangeDim, TensorType
from transformers import BertForSequenceClassification, BertTokenizer

HF_ID = "amberoad/bert-multilingual-passage-reranking-msmarco"


class PairLogits(torch.nn.Module):
    """BertForSequenceClassification → bare logits [1,2]. Inputs arrive as
    int32 (CoreML multiarray dtype) and are cast to long for the embedding
    lookup — the cast is traced into the graph."""

    def __init__(self, src):
        super().__init__()
        self.model = BertForSequenceClassification.from_pretrained(src)
        self.model.eval()

    def forward(self, input_ids, attention_mask, token_type_ids):
        out = self.model(
            input_ids=input_ids.long(),
            attention_mask=attention_mask.long(),
            token_type_ids=token_type_ids.long(),
        )
        return out.logits


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default="/tmp/reranker-hf",
                    help="local dir with config.json+pytorch_model.bin, or HF id")
    ap.add_argument("--out", required=True, help="output model.mlpackage path")
    ap.add_argument("--precision", default="float16",
                    choices=["float16", "float32"])
    ap.add_argument("--install", action="store_true",
                    help="copy vocab.txt next to the mlpackage")
    args = ap.parse_args()

    src = args.src if os.path.isdir(args.src) else HF_ID
    wrapper = PairLogits(src)
    tok = BertTokenizer.from_pretrained(src)

    b, s = 1, 32
    ids = torch.randint(0, 105879, (b, s), dtype=torch.int32)
    mask = torch.ones((b, s), dtype=torch.int32)
    types = torch.zeros((b, s), dtype=torch.int32)
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, (ids, mask, types))

    seq = RangeDim(1, 512)
    prec = ct.precision.FLOAT16 if args.precision == "float16" else ct.precision.FLOAT32
    ml = ct.convert(
        traced,
        inputs=[
            TensorType(name="input_ids", shape=(1, seq), dtype=np.int32),
            TensorType(name="attention_mask", shape=(1, seq), dtype=np.int32),
            TensorType(name="token_type_ids", shape=(1, seq), dtype=np.int32),
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
        ("middleware kiểm tra đăng nhập vân tay passkey",
         "export async function onRequest(context) {\n  // verify WebAuthn "
         "passkey assertion before allowing access\n}"),
    ]
    max_diff = 0.0
    for q, d in pairs:
        enc = tok(q, d, truncation=True, max_length=512, return_tensors="np")
        hf = wrapper(
            torch.tensor(enc["input_ids"], dtype=torch.int32),
            torch.tensor(enc["attention_mask"], dtype=torch.int32),
            torch.tensor(enc["token_type_ids"], dtype=torch.int32),
        ).detach().numpy()[0]
        cl = np.asarray(m.predict({
            "input_ids": enc["input_ids"].astype(np.int32),
            "attention_mask": enc["attention_mask"].astype(np.int32),
            "token_type_ids": enc["token_type_ids"].astype(np.int32),
        })["logits"])[0]
        d1 = float(np.abs(hf - cl).max())
        max_diff = max(max_diff, d1)
        print(f"  HF {hf.tolist()}  CL {cl.tolist()}  diff {d1:.4f}")
    print(f"max abs diff {max_diff:.4f} ({'OK' if max_diff < 0.05 else 'MISMATCH'})")

    if args.install:
        dst = os.path.join(os.path.dirname(out), "vocab.txt")
        src_vocab = os.path.join(args.src, "vocab.txt") if os.path.isdir(args.src) else None
        if src_vocab and os.path.exists(src_vocab):
            shutil.copyfile(src_vocab, dst)
        else:
            from huggingface_hub import hf_hub_download
            shutil.copyfile(hf_hub_download(HF_ID, "vocab.txt"), dst)
        print(f"installed vocab.txt → {dst}")


if __name__ == "__main__":
    main()
