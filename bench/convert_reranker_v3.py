#!/usr/bin/env python3
"""convert_reranker_v3.py — jinaai/jina-reranker-v2-base-multilingual →
CoreML mlpackage for the swctx reranker-v3 spike.

XLMRobertaForSequenceClassification (XLM-R base backbone, 12L/768H,
~278M params, ONE relevance logit — score = logit[0]; jina's
compute_score() applies sigmoid for probabilities but raw-logit
ordering is identical).

Architecture notes (vs convert_reranker_v2m3.py):
  * The repo ships jina's OWN modeling_xlm_roberta.py (fused
    mixer.Wqkv, einops rearrange inside attention) whose traced graph
    hits a coremltools aten::Int conversion failure on shape scalars.
    Instead we remap the safetensors into the STOCK HF
    XLMRobertaForSequenceClassification — the exact class v2m3
    converts cleanly. The remap is verified bit-identical (≤3e-7) to
    jina's own model on probe pairs, and --verify-jina re-checks it
    inside this script. Mapping:
        roberta.emb_ln.*            → roberta.embeddings.LayerNorm.*
        encoder.layers.N.mixer.Wqkv.{w,b}
          → encoder.layer.N.attention.self.{query,key,value}.{w,b}
            (split [q|k|v] on out dim)
        encoder.layers.N.mixer.out_proj.* → .attention.output.dense.*
        encoder.layers.N.norm1.*    → .attention.output.LayerNorm.*
        encoder.layers.N.mlp.fc1.*  → .intermediate.dense.*
        encoder.layers.N.mlp.fc2.*  → .output.dense.*
        encoder.layers.N.norm2.*    → .output.LayerNorm.*
      Equivalence holds because jina's embedding uses the same
      create_position_ids_from_input_ids, F.gelu exact, additive
      -10000 attention mask, post-LN, and the same classifier head.
  * The repo ships NO sentencepiece.bpe.model (tokenizer.json only).
    Verified byte-exact that its unigram vocab equals BGE-M3's spm
    vocab (all 250000 pieces identical strings+scores, same fairseq
    layout), so --install copies bge-m3's .model (--spm-src).

Pair encoding is the standard XLM-R convention `<s> q </s></s> d </s>`
= [0] + q + [2,2] + d + [2] (verified vs compute_score's tokenizer
call and tokenizer.json's pair template). No query/doc prefixes.
num_labels=1 → logit[0]; sigmoid for probability preserves ordering.

Same venv: torch 2.14.0 + transformers 4.46.3 + coremltools 9.0
(+ einops only for --verify-jina).

Usage:
    python3 bench/convert_reranker_v3.py --src /tmp/jina-hf \
        --out <dir>/model.mlpackage [--precision float16|float32] \
        [--spm-src /tmp/bge-reranker-v2-m3-hf/sentencepiece.bpe.model] \
        [--install] [--verify-jina]
"""

import argparse
import json
import os
import shutil

import numpy as np
import torch
import coremltools as ct
from coremltools import RangeDim, TensorType
from transformers import (
    AutoTokenizer,
    XLMRobertaConfig,
    XLMRobertaForSequenceClassification,
)

HF_ID = "jinaai/jina-reranker-v2-base-multilingual"
VOCAB = 250002


def load_stock_model(src):
    """Load jina-format safetensors into the stock HF
    XLMRobertaForSequenceClassification (remaps fused-Wqkv naming)."""
    from safetensors.torch import load_file

    sd = load_file(os.path.join(src, "model.safetensors"))
    if not any(".mixer.Wqkv." in k for k in sd):
        # Already a stock HF checkpoint.
        return XLMRobertaForSequenceClassification.from_pretrained(src)

    cj = json.load(open(os.path.join(src, "config.json")))
    cfg = XLMRobertaConfig(
        vocab_size=cj["vocab_size"],
        hidden_size=cj["hidden_size"],
        num_hidden_layers=cj["num_hidden_layers"],
        num_attention_heads=cj["num_attention_heads"],
        intermediate_size=cj["intermediate_size"],
        hidden_act=cj["hidden_act"],
        hidden_dropout_prob=cj["hidden_dropout_prob"],
        attention_probs_dropout_prob=cj["attention_probs_dropout_prob"],
        max_position_embeddings=cj["max_position_embeddings"],
        type_vocab_size=cj["type_vocab_size"],
        layer_norm_eps=cj["layer_norm_eps"],
        pad_token_id=cj["pad_token_id"],
        bos_token_id=cj["bos_token_id"],
        eos_token_id=cj["eos_token_id"],
        num_labels=cj.get("num_labels", 1),
    )
    h = cfg.hidden_size
    new = {}
    for k, v in sd.items():
        if k.startswith("roberta.emb_ln."):
            new[k.replace("roberta.emb_ln.",
                          "roberta.embeddings.LayerNorm.")] = v.float()
        elif ".mixer.Wqkv." in k:
            base, _, tail = k.partition(".mixer.Wqkv.")
            base = base.replace("encoder.layers.", "encoder.layer.")
            w = v.float()
            for name, sl in [("query", slice(0, h)),
                             ("key", slice(h, 2 * h)),
                             ("value", slice(2 * h, 3 * h))]:
                new[f"{base}.attention.self.{name}.{tail}"] = \
                    w[sl].contiguous()
        else:
            k2 = k.replace("encoder.layers.", "encoder.layer.")
            for a, b in [
                (".mixer.out_proj.", ".attention.output.dense."),
                (".norm1.", ".attention.output.LayerNorm."),
                (".mlp.fc1.", ".intermediate.dense."),
                (".mlp.fc2.", ".output.dense."),
                (".norm2.", ".output.LayerNorm."),
            ]:
                k2 = k2.replace(a, b)
            new[k2] = v.float()
    model = XLMRobertaForSequenceClassification(cfg)
    model.load_state_dict(new, strict=True)
    return model


class PairLogits(torch.nn.Module):
    """Stock XLMRobertaForSequenceClassification → bare logits [1,1].
    Inputs arrive as int32 and are cast to long — the cast is traced in."""

    def __init__(self, src):
        super().__init__()
        self.model = load_stock_model(src)
        self.model.eval()

    def forward(self, input_ids, attention_mask):
        out = self.model(
            input_ids=input_ids.long(),
            attention_mask=attention_mask.long(),
        )
        return out.logits


PAIRS = [
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


def encode(tok, q, d, max_length=512):
    return tok(q, d, truncation="longest_first", max_length=max_length,
               return_tensors="np")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", default="/tmp/jina-reranker-v2-hf",
                    help="local dir with config.json+model.safetensors")
    ap.add_argument("--out", required=True, help="output model.mlpackage path")
    ap.add_argument("--precision", default="float16",
                    choices=["float16", "float32"])
    ap.add_argument("--max-seq", type=int, default=1024,
                    help="upper bound of the RangeDim sequence axis")
    ap.add_argument("--install", action="store_true",
                    help="copy sentencepiece.bpe.model next to the mlpackage")
    ap.add_argument("--spm-src",
                    default="/tmp/bge-reranker-v2-m3-hf/sentencepiece.bpe.model",
                    help="spm .model to install (jina ships none; bge-m3's "
                         "vocab is verified identical to jina's tokenizer.json)")
    ap.add_argument("--verify-jina", action="store_true",
                    help="also compare remapped-stock logits vs jina's own "
                         "modeling code (requires trust_remote_code + einops)")
    args = ap.parse_args()

    src = args.src if os.path.isdir(args.src) else HF_ID
    wrapper = PairLogits(src)
    tok = AutoTokenizer.from_pretrained(src)

    if args.verify_jina:
        from transformers import AutoModelForSequenceClassification
        jm = AutoModelForSequenceClassification.from_pretrained(
            src, trust_remote_code=True, use_flash_attn=False,
            torch_dtype=torch.float32).eval()
        md = 0.0
        with torch.no_grad():
            for q, d in PAIRS:
                enc = encode(tok, q, d)
                t = {k: torch.tensor(v) for k, v in enc.items()}
                a = jm(**t).logits.item()
                b = wrapper.model(**t).logits.item()
                md = max(md, abs(a - b))
                print(f"  jina {a:.5f}  stock {b:.5f}  diff {abs(a-b):.6f}")
        print(f"jina-vs-stock max diff {md:.6f} "
              f"({'OK' if md < 1e-4 else 'MISMATCH'})")

    b, s = 1, 32
    ids = torch.randint(0, VOCAB, (b, s), dtype=torch.int32)
    mask = torch.ones((b, s), dtype=torch.int32)
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, (ids, mask))

    seq = RangeDim(1, args.max_seq)
    prec = ct.precision.FLOAT16 if args.precision == "float16" \
        else ct.precision.FLOAT32
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
    max_diff = 0.0
    for q, d in PAIRS:
        enc = encode(tok, q, d)
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
    print(f"max abs diff {max_diff:.4f} "
          f"({'OK' if max_diff < 0.05 else 'MISMATCH'})")

    if args.install:
        dst = os.path.join(os.path.dirname(out), "sentencepiece.bpe.model")
        if os.path.exists(args.spm_src):
            shutil.copyfile(args.spm_src, dst)
            print(f"installed sentencepiece.bpe.model → {dst} "
                  f"(from {args.spm_src})")
        else:
            print(f"WARN: --spm-src {args.spm_src} missing; tokenizer.json's "
                  "unigram vocab is verified identical to bge-m3's spm model, "
                  "so any copy of bge-reranker-v2-m3's "
                  f"sentencepiece.bpe.model works. Install manually to {dst}")


if __name__ == "__main__":
    main()
