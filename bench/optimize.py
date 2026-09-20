#!/usr/bin/env python3
"""optimize.py — self-tuning harness for swctx retrieval knobs.

Runs strict_score (--legs search by default) across the registered
manifests for each knob-value combination, reports per-set and combined
Recall@5/MRR, and flags per-query regressions against the baseline run.

Knobs are the SWCTX_* env overrides baked into Search.swift/Tools.swift
(same contract as SWCTX_RRF_W): defaults are the measured winners;
this script exists so tuning is `python3 bench/optimize.py --grid ...`
instead of manual whack-a-mole.

Usage:

    python3 bench/optimize.py --knob SWCTX_PROBE_BAR --values 1.5,2.0,2.5
    python3 bench/optimize.py --grid '{"SWCTX_PROBE_CORPUS":[0,300,500],
                                       "SWCTX_PROBE_CAP":[4,6,8]}'
    python3 bench/optimize.py --legs search --quick   # vn22 only

Exit 0 always; the verdict line prints whether the best variant beats
baseline without any per-set regression (Codex gate).
"""

import argparse
import itertools
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SETS = {
    "vn22": os.path.join(HERE, "vn_queries.json"),
    "linkeldn": os.path.join(HERE, "linkeldn_holdout.json"),
    "fleet": os.path.join(HERE, "fleet_holdout.json"),
}
DEFAULT_BIN = os.path.join(HERE, "..", ".build", "release", "swctx")


def run_set(bin_path, queries, legs, env, out):
    e = dict(os.environ)
    e.update({k: str(v) for k, v in env.items()})
    subprocess.run(
        [sys.executable, os.path.join(HERE, "strict_score.py"),
         "--queries", queries, "--swctx-bin", bin_path,
         "--legs", legs, "--out", out],
        env=e, capture_output=True, text=True, timeout=3600)
    return json.load(open(out))


def per_query_ranks(report):
    return {r["id"]: r.get("search_rank") or r.get("union_rank") or 0
            for r in report["results"]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--knob")
    ap.add_argument("--values")
    ap.add_argument("--grid", help="JSON {knob: [values]} — full product")
    ap.add_argument("--legs", default="search")
    ap.add_argument("--swctx-bin", default=DEFAULT_BIN)
    ap.add_argument("--quick", action="store_true", help="vn22 only")
    ap.add_argument("--outdir", default="/tmp/swctx_opt")
    args = ap.parse_args()

    sets = {"vn22": SETS["vn22"]} if args.quick else SETS

    if args.grid:
        grid = json.loads(args.grid)
    elif args.knob and args.values:
        grid = {args.knob: [float(v) if "." in v else int(v)
                          for v in args.values.split(",")]}
    else:
        # default sweep: the knobs this session introduced
        grid = {"SWCTX_PROBE_BAR": [1.5, 2.0, 2.5],
                "SWCTX_PROBE_CAP": [4, 6, 8]}

    knobs = sorted(grid)
    combos = [dict(zip(knobs, vals)) for vals in
              itertools.product(*(grid[k] for k in knobs))]
    combos.insert(0, {})  # baseline first

    os.makedirs(args.outdir, exist_ok=True)
    results = []
    base_ranks = {}
    for i, env in enumerate(combos):
        label = "baseline" if not env else \
            " ".join(f"{k}={v}" for k, v in env.items())
        per_set, ranks_all = {}, {}
        for name, qfile in sets.items():
            out = os.path.join(args.outdir, f"v{i}_{name}.json")
            rep = run_set(args.swctx_bin, qfile, args.legs, env, out)
            leg = "search" if "search" in rep["legs"] else "union"
            m = rep["legs"][leg]
            per_set[name] = (m["recall@5"], m["n"], m["mrr"])
            ranks_all[name] = per_query_ranks(rep)
        results.append((label, env, per_set, ranks_all))
        if i == 0:
            base_ranks = ranks_all
        tot = sum(r5 for r5, n, _ in per_set.values())
        n_all = sum(n for _, n, _ in per_set.values())
        print(f"[{i}] {label:44s} "
              + " ".join(f"{n}={r5}/{nn}" for n, (r5, nn, _)
                         in per_set.items())
              + f"  total={tot}/{n_all}", flush=True)

    # regression check vs baseline: any query that was <=5 and now >5
    best = max(results[1:], key=lambda r: sum(s[0] for s in r[2].values()),
               default=None)
    print("\n== verdict ==")
    if not best:
        print("no variants ran")
        return
    regress = []
    for name in sets:
        for qid, br in base_ranks[name].items():
            nr = best[3][name].get(qid, 0)
            if 0 < br <= 5 and (nr == 0 or nr > 5):
                regress.append(f"{name}:{qid} r{br}->r{nr}")
    tot_b = sum(s[0] for s in best[2].values())
    tot_0 = sum(s[0] for s in results[0][2].values())
    print(f"best: {best[0]}  total R@5 {tot_b} vs baseline {tot_0}")
    if regress:
        print(f"REGRESSIONS: {', '.join(regress)}")
    else:
        print("no per-query R@5 regressions vs baseline")


if __name__ == "__main__":
    main()
