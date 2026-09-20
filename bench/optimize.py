#!/usr/bin/env python3
"""optimize.py — self-tuning harness for swctx retrieval knobs.

Runs strict_score (--legs search by default) across manifests for each
knob-value combination. Codex review (2026-09-20, CHAN) split the corpus:

- --tune-on manifests (default: vn22) SELECT the winner — these are the
  tuning corpus, safe to iterate against.
- All other manifests are CONFIRM-only holdouts: measured once per
  variant for the adoption gate, never used to pick the winner. Sets
  used repeatedly for selection stop being blind.

Adoption gate (all must hold, else exit 1):
  1. best variant beats baseline R@5 on the TUNE set,
  2. zero per-query R@5 regressions on EVERY manifest,
  3. no confirm-set R@5 drop vs baseline (non-inferiority, margin 0),
  4. search p95 does not regress >10% on the tune set.

Pre-registration rule: pick the candidate on tune data, then confirm on
holdouts ONE time. Re-sweeping after seeing holdout results turns them
into tuning data — don't.

Usage:

    python3 bench/optimize.py --knob SWCTX_PROBE_BAR --values 1.5,2.0,2.5
    python3 bench/optimize.py --grid '{"SWCTX_PROBE_CORPUS":[0,150,500]}'
    python3 bench/optimize.py --quick                 # vn22 only, no gate
    python3 bench/optimize.py --tune-on vn22,fleet    # custom split

Exit 0 = gate passed (adopt-worthy); 1 = gate failed; 2 = harness error.
"""

import argparse
import itertools
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SETS = {
    "vn22": os.path.join(HERE, "vn_queries.json"),
    "linkeldn": os.path.join(HERE, "linkeldn_holdout.json"),
    "fleet": os.path.join(HERE, "fleet_holdout.json"),
}
DEFAULT_BIN = os.path.join(HERE, "..", ".build", "release", "swctx")


def run_set(bin_path, queries, legs, env, out):
    """Returns the report dict. Refuses stale output: a failed
    subprocess must not let us read a previous variant's file."""
    e = dict(os.environ)
    e.update({k: str(v) for k, v in env.items()})
    start = time.time()
    try:
        os.unlink(out)
    except FileNotFoundError:
        pass
    p = subprocess.run(
        [sys.executable, os.path.join(HERE, "strict_score.py"),
         "--queries", queries, "--swctx-bin", bin_path,
         "--legs", legs, "--out", out],
        env=e, capture_output=True, text=True, timeout=3600)
    if p.returncode != 0:
        raise RuntimeError(f"strict_score rc={p.returncode}: "
                           f"{p.stderr[-400:]}")
    if not os.path.exists(out) or os.path.getmtime(out) < start:
        raise RuntimeError(f"stale or missing output: {out}")
    return json.load(open(out))


def per_query_ranks(report):
    return {r["id"]: r.get("search_rank") or r.get("union_rank") or 0
            for r in report["results"]}


def p95(report):
    return (report.get("latency_ms", {}).get("search") or {}).get("p95", 0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--knob")
    ap.add_argument("--values")
    ap.add_argument("--grid", help="JSON {knob: [values]} — full product")
    ap.add_argument("--legs", default="search")
    ap.add_argument("--swctx-bin", default=DEFAULT_BIN)
    ap.add_argument("--tune-on", default="vn22",
                    help="comma-list of manifests used to SELECT the "
                         "winner; the rest are confirm-only holdouts")
    ap.add_argument("--quick", action="store_true",
                    help="vn22 only, no holdout gate (exploration mode)")
    ap.add_argument("--outdir", default="/tmp/swctx_opt")
    args = ap.parse_args()

    tune_names = set(args.tune_on.split(","))
    unknown = tune_names - set(SETS)
    if unknown:
        print(f"unknown --tune-on manifests: {unknown}", file=sys.stderr)
        sys.exit(2)
    sets = {"vn22": SETS["vn22"]} if args.quick else SETS
    confirm_names = [n for n in sets if n not in tune_names]

    if args.grid:
        grid = json.loads(args.grid)
    elif args.knob and args.values:
        grid = {args.knob: [float(v) if "." in v else int(v)
                          for v in args.values.split(",")]}
    else:
        grid = {"SWCTX_PROBE_BAR": [1.5, 2.0, 2.5],
                "SWCTX_PROBE_CAP": [4, 6, 8]}

    knobs = sorted(grid)
    combos = [dict(zip(knobs, vals)) for vals in
              itertools.product(*(grid[k] for k in knobs))]
    combos.insert(0, {})  # baseline first

    outdir = args.outdir
    os.makedirs(outdir, exist_ok=True)
    results = []
    base_ranks, base_p95 = {}, {}
    try:
        for i, env in enumerate(combos):
            label = "baseline" if not env else \
                " ".join(f"{k}={v}" for k, v in env.items())
            per_set, ranks_all, lat = {}, {}, {}
            for name, qfile in sets.items():
                out = os.path.join(outdir, f"v{i}_{name}.json")
                rep = run_set(args.swctx_bin, qfile, args.legs, env, out)
                leg = "search" if "search" in rep["legs"] else "union"
                m = rep["legs"][leg]
                per_set[name] = (m["recall@5"], m["n"], m["mrr"])
                ranks_all[name] = per_query_ranks(rep)
                lat[name] = p95(rep)
            results.append((label, env, per_set, ranks_all, lat))
            if i == 0:
                base_ranks, base_p95 = ranks_all, lat
            print(f"[{i}] {label:44s} "
                  + " ".join(f"{n}={r5}/{nn}" for n, (r5, nn, _)
                             in per_set.items())
                  + f"  total={sum(s[0] for s in per_set.values())}"
                  f"/{sum(s[1] for s in per_set.values())}", flush=True)
    except RuntimeError as e:
        print(f"harness error: {e}", file=sys.stderr)
        sys.exit(2)

    def tune_score(r):
        return sum(r[2][n][0] for n in tune_names if n in r[2])

    best = max(results[1:], key=tune_score, default=None)
    print("\n== verdict ==")
    if not best:
        print("no variants ran")
        sys.exit(1)
    print(f"best on tune ({','.join(sorted(tune_names))}): {best[0]} "
          f"R@5={tune_score(best)} vs baseline {tune_score(results[0])}")

    fails = []
    # gate 1: tune improvement
    if tune_score(best) <= tune_score(results[0]):
        fails.append("no tune-set improvement")
    # gate 2: per-query regressions on every manifest
    for name in sets:
        for qid, br in base_ranks.get(name, {}).items():
            nr = best[3][name].get(qid, 0)
            if 0 < br <= 5 and (nr == 0 or nr > 5):
                fails.append(f"regression {name}:{qid} r{br}->r{nr}")
    # gate 3: confirm-set non-inferiority
    for name in confirm_names:
        b0 = results[0][2][name][0]
        bn = best[2][name][0]
        if bn < b0:
            fails.append(f"confirm {name} R@5 {bn}<{b0}")
    # gate 4: p95 on tune sets within 10%
    for name in tune_names:
        b0, bn = base_p95.get(name, 0), best[4].get(name, 0)
        if b0 > 0 and bn > b0 * 1.10:
            fails.append(f"p95 {name} {bn}ms>{b0}ms*1.1")

    if fails:
        print("GATE FAIL:")
        for f in fails[:12]:
            print(f"  - {f}")
        sys.exit(1)
    print(f"GATE PASS — candidate adopt-worthy: {best[0]}")
    if confirm_names:
        print("confirmed holdouts non-inferior: "
              + ", ".join(f"{n}={best[2][n][0]}/{best[2][n][1]}"
                          for n in confirm_names))
    print("next: bake default, swift test, ONE untouched-holdout verify")
    sys.exit(0)


if __name__ == "__main__":
    main()
