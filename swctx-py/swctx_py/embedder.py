"""ONNX embedder — lazy-loaded, cross-platform. Models live in ~/.swctx-py/models/<id>/."""
from __future__ import annotations

import os
from pathlib import Path

import numpy as np

from .store import MODELS

MODELS_KNOWN = {
    "bge-base-en-v1.5": {
        "repo": "BAAI/bge-base-en-v1.5",
        "files": ["onnx/model.onnx", "tokenizer.json"],
        "pool": "cls", "dim": 768, "langs": "en",
    },
    "distiluse-base-multilingual-cased-v2": {
        "repo": "sentence-transformers/distiluse-base-multilingual-cased-v2",
        "files": ["onnx/model.onnx", "tokenizer.json"],
        "pool": "mean", "dim": 768, "langs": "50+ incl. vi",
    },
    "bge-m3": {
        "repo": "BAAI/bge-m3",
        "files": ["onnx/model.onnx", "tokenizer.json"],
        "pool": "cls", "dim": 1024, "langs": "100+ incl. vi (heavy — ~450ms/embed CPU)",
    },
    # Static tier (Model2Vec): token->vector lookup + mean-pool, no
    # neural inference. ~83MB total, ~1ms/embed — for weak machines/CI.
    "potion-multi-int8": {
        "repo": "777Radik/potion-multilingual-128M-int8",
        "files": ["model.safetensors", "tokenizer.json"],
        "kind": "static", "dim": 128,
        "langs": "101 incl. vi (distilled from bge-m3)",
    },
}
MAX_LEN = 256
BATCH = 32


def model_dir(model_id: str) -> Path:
    return MODELS / model_id


def _is_static(model_id: str) -> bool:
    return MODELS_KNOWN.get(model_id, {}).get("kind") == "static"


def model_installed(model_id: str) -> bool:
    d = model_dir(model_id)
    weights = "model.safetensors" if _is_static(model_id) else "model.onnx"
    return (d / weights).exists() and (d / "tokenizer.json").exists()


def _load_safetensors(path: Path) -> np.ndarray:
    """Minimal safetensors reader: one `embeddings` tensor (I8/F32).
    Header = u64 LE length + JSON {name: {dtype, shape, data_offsets}}."""
    import json
    import struct
    with open(path, "rb") as f:
        n = struct.unpack("<Q", f.read(8))[0]
        hdr = json.loads(f.read(n))
        meta = hdr["embeddings"]
        off0, off1 = meta["data_offsets"]
        f.seek(8 + n + off0)
        raw = f.read(off1 - off0)
    dt = np.int8 if meta["dtype"] == "I8" else np.float32
    return np.frombuffer(raw, dtype=dt).reshape(meta["shape"])


def install_model(model_id: str = "bge-base-en-v1.5") -> Path:
    from huggingface_hub import hf_hub_download
    spec = MODELS_KNOWN[model_id]
    d = model_dir(model_id)
    d.mkdir(parents=True, exist_ok=True)
    for rel in spec["files"]:
        tgt = d / Path(rel).name
        if tgt.exists():
            continue
        got = hf_hub_download(repo_id=spec["repo"], filename=rel)
        import shutil
        shutil.copy(got, tgt)
    return d


class Embedder:
    """Lazy ONNX session + tokenizer for one model id."""

    def __init__(self, model_id: str = "bge-base-en-v1.5"):
        self.model_id = model_id
        self._sess = None
        self._tok = None
        self._emb: np.ndarray | None = None  # static tier lookup table

    @property
    def dim(self) -> int:
        return MODELS_KNOWN[self.model_id]["dim"]

    def _load(self):
        if self._sess is not None or self._emb is not None:
            return
        if not model_installed(self.model_id):
            install_model(self.model_id)
        from tokenizers import Tokenizer
        d = model_dir(self.model_id)
        self._tok = Tokenizer.from_file(str(d / "tokenizer.json"))
        self._tok.enable_truncation(MAX_LEN)
        if _is_static(self.model_id):
            # (vocab, dim) int8/float32 table — cast lazily per lookup.
            self._emb = _load_safetensors(d / "model.safetensors")
            return
        import onnxruntime as ort
        so = ort.SessionOptions()
        so.inter_op_num_threads = max(1, (os.cpu_count() or 4) // 2)
        so.intra_op_num_threads = max(1, (os.cpu_count() or 4) // 2)
        self._sess = ort.InferenceSession(
            str(d / "model.onnx"), sess_options=so,
            providers=["CPUExecutionProvider"])
        self._tok.enable_padding(length=MAX_LEN)

    def release(self):
        self._sess = None
        self._tok = None
        self._emb = None

    def embed(self, texts: list[str]) -> np.ndarray:
        self._load()
        if self._emb is not None:
            enc = self._tok.encode_batch(texts)
            vecs = np.stack([
                self._emb[e.ids].astype(np.float32).mean(0)
                for e in enc])
            vecs /= np.maximum(
                np.linalg.norm(vecs, axis=1, keepdims=True), 1e-12)
            return vecs.astype(np.float32)
        outs: list[np.ndarray] = []
        for i in range(0, len(texts), BATCH):
            enc = self._tok.encode_batch(texts[i:i + BATCH])
            ids = np.array([e.ids for e in enc], dtype=np.int64)
            mask = np.array([e.attention_mask for e in enc], dtype=np.int64)
            inputs = {"input_ids": ids, "attention_mask": mask}
            names = {n.name for n in self._sess.get_inputs()}
            if "token_type_ids" in names:
                inputs["token_type_ids"] = np.array(
                    [e.type_ids for e in enc], dtype=np.int64)
            hidden = self._sess.run(None, inputs)[0]  # (B, T, H)
            if MODELS_KNOWN[self.model_id]["pool"] == "mean":
                m = mask[..., None].astype(np.float32)
                vec = (hidden * m).sum(1) / np.maximum(m.sum(1), 1e-9)
            else:
                vec = hidden[:, 0]
            vec = vec / np.maximum(
                np.linalg.norm(vec, axis=1, keepdims=True), 1e-12)
            outs.append(vec.astype(np.float32))
        return np.vstack(outs) if outs else np.zeros((0, self.dim), np.float32)
