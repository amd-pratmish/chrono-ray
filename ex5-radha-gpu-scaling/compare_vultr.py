#!/usr/bin/env python3
"""Merge ex5 Radha results with ex4 Vultr MI355X baseline for cross-cloud comparison."""

from __future__ import annotations

import csv
import json
import os
from pathlib import Path

RESULTS = Path(
    os.environ.get(
        "RESULTS_ROOT",
        f"/shared/{os.environ.get('USER', 'pratmish')}/amd_chronos_results/phase3/ex5_radha_scaling",
    )
)
VULTR_BASELINE = Path(__file__).resolve().parent / "vultr_ex4_baseline.csv"
OUT_DIR = RESULTS / "comparison"


# ex4 validated MI355X on Vultr (Aug 2026, from amd-pratmish/chrono-ray ex4 README)
VULTR_ROWS = [
    {"platform": "vultr_mi355x", "scale_gpus": 1, "job_id": "19114", "trials_completed": 2, "trials_requested": 2,
     "doe_elapsed_min": "7.9", "throughput_trials_per_hr": "15.2", "speedup_vs_1gpu": "1.0", "partition": "rad"},
    {"platform": "vultr_mi355x", "scale_gpus": 2, "job_id": "19117", "trials_completed": 4, "trials_requested": 4,
     "doe_elapsed_min": "9.5", "throughput_trials_per_hr": "25.3", "speedup_vs_1gpu": "1.7", "partition": "rad"},
    {"platform": "vultr_mi355x", "scale_gpus": 8, "job_id": "19120", "trials_completed": 16, "trials_requested": 16,
     "doe_elapsed_min": "42.5", "throughput_trials_per_hr": "22.6", "speedup_vs_1gpu": "1.5", "partition": "rad"},
    {"platform": "vultr_mi355x", "scale_gpus": 16, "job_id": "19203", "trials_completed": 32, "trials_requested": 32,
     "doe_elapsed_min": "42.9", "throughput_trials_per_hr": "44.8", "speedup_vs_1gpu": "2.9", "partition": "rad"},
]


def load_radha_csv(platform: str) -> list[dict]:
    path = RESULTS / platform / "performance" / "scale_performance.csv"
    if not path.is_file():
        return []
    with path.open() as f:
        rows = list(csv.DictReader(f))
    for r in rows:
        r["platform"] = f"radha_{platform}"
    return rows


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    with (VULTR_BASELINE).open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=VULTR_ROWS[0].keys())
        w.writeheader()
        w.writerows(VULTR_ROWS)

    merged: list[dict] = list(VULTR_ROWS)
    for plat in ("mi350x", "mi300x"):
        merged.extend(load_radha_csv(plat))

    out_csv = OUT_DIR / "radha_vs_vultr_scaling.csv"
    if merged:
        keys = sorted({k for r in merged for k in r.keys()})
        with out_csv.open("w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=keys, extrasaction="ignore")
            w.writeheader()
            w.writerows(merged)

    md = OUT_DIR / "COMPARISON.md"
    lines = [
        "# ex5 Radha vs ex4 Vultr scaling comparison",
        "",
        "Same workload: ChronoRay FSI angle-of-repose DoE (`doe_amd_fsi.py`).",
        "",
        "| Platform | GPUs | Throughput (trials/hr) | DoE (min) | Speedup vs 1 GPU |",
        "|----------|------|------------------------|-----------|-------------------|",
    ]
    for r in sorted(merged, key=lambda x: (x.get("platform", ""), int(x.get("scale_gpus") or 0))):
        lines.append(
            f"| {r.get('platform','?')} | {r.get('scale_gpus','?')} | "
            f"{r.get('throughput_trials_per_hr','?')} | {r.get('doe_elapsed_min','?')} | "
            f"{r.get('speedup_vs_1gpu','?')} |"
        )
    md.write_text("\n".join(lines) + "\n")
    print(f"Wrote {out_csv} and {md}")
    print(json.dumps({"rows": len(merged)}, indent=2))


if __name__ == "__main__":
    main()
