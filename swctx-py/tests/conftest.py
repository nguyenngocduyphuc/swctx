"""Test isolation: point swctx-py's state dir (indexes/, records.db,
workspaces.json) at a per-session temp dir before any swctx_py import —
mirrors the Swift harness's SWCTX_HOME seam (store.py reads it at import).
"""
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

os.environ["SWCTX_PY_HOME"] = tempfile.mkdtemp(prefix="swctx-py-test-home-")
