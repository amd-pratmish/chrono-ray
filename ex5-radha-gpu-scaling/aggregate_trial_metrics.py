#!/usr/bin/env python3
"""Aggregate per-trial metrics and compute Ray scheduling overhead vs GPU SPH time."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


def aggregate_run_dir(run_dir: Path, doe_elapsed_s: float | None = None) -> dict:
    trials: list[dict] = []
    for mf in run_dir.glob("particles/*/trial_metrics.json"):
        try:
            trials.append(json.loads(mf.read_text()))
        except (json.JSONDecodeError, OSError):
            continue

    total_steps = sum(int(t.get("gpu_sph_steps", 0)) for t in trials)
    total_gpu_wall = sum(float(t.get("gpu_sph_wall_seconds", 0)) for t in trials)
    n = len(trials)
    mean_trial_wall = total_gpu_wall / n if n else 0.0
    aggregate_steps_per_s = total_steps / total_gpu_wall if total_gpu_wall > 0 else 0.0
    mean_steps_per_s = (
        sum(float(t.get("gpu_sph_steps_per_s", 0)) for t in trials) / n if n else 0.0
    )

    ray_sched_overhead = 0.0
    gpu_sph_fraction = 0.0
    if doe_elapsed_s and doe_elapsed_s > 0:
        ray_sched_overhead = max(0.0, doe_elapsed_s - total_gpu_wall)
        gpu_sph_fraction = total_gpu_wall / doe_elapsed_s

    return {
        "trials_with_metrics": n,
        "total_gpu_sph_steps": total_steps,
        "total_gpu_sph_wall_seconds": round(total_gpu_wall, 3),
        "mean_trial_wall_seconds": round(mean_trial_wall, 3),
        "aggregate_gpu_sph_steps_per_s": round(aggregate_steps_per_s, 2),
        "mean_gpu_sph_steps_per_s": round(mean_steps_per_s, 2),
        "ray_scheduling_overhead_s": round(ray_sched_overhead, 3),
        "gpu_sph_fraction_of_doe": round(gpu_sph_fraction, 4),
        "heartbeat_wall_seconds": round(mean_trial_wall, 3),
        "gpu_sph_fraction_of_heartbeat": 1.0 if mean_trial_wall > 0 else 0.0,
    }


def parse_doe_elapsed(log_path: Path) -> float | None:
    if not log_path.is_file():
        return None
    m = re.search(r"DoE completed in ([0-9.]+)s", log_path.read_text(errors="replace"))
    return float(m.group(1)) if m else None


def main() -> int:
    run_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(".")
    doe_s = parse_doe_elapsed(run_dir / "doe_run.log")
    agg = aggregate_run_dir(run_dir, doe_s)
    out = run_dir / "doe_metrics.json"
    out.write_text(json.dumps(agg, indent=2))
    for k, v in agg.items():
        print(f"{k}={v}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
