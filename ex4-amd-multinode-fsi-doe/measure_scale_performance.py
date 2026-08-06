#!/usr/bin/env python3
"""Aggregate ChronoRay FSI-SPH scale-run performance across all result directories."""

from __future__ import annotations

import csv
import re
import sys
from pathlib import Path

EX4 = Path("/home/pratmish/chrono-ray/ex4-amd-multinode-fsi-doe")
RESULTS = EX4 / "results"
REPORT_DIR = EX4 / "results" / "performance"


def parse_summary(path: Path) -> dict[str, str]:
    data: dict[str, str] = {}
    if not path.is_file():
        return data
    for line in path.read_text().splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            data[k.strip()] = v.strip()
    return data


def parse_doe_log(path: Path) -> dict[str, float]:
    out: dict[str, float] = {}
    if not path.is_file():
        return out
    text = path.read_text(errors="replace")
    for pat, key in (
        (r"DoE completed in ([0-9.]+)s", "doe_elapsed_s"),
        (r"Avg per trial: ([0-9.]+)s", "avg_sec_per_trial"),
        (r"Throughput:\s+([0-9.]+) trials/hour", "throughput_trials_per_hr"),
    ):
        m = re.search(pat, text)
        if m:
            out[key] = float(m.group(1))
    batches = len(re.findall(r"Batch \d+/\d+: done\.", text))
    if batches:
        out["batches_completed"] = float(batches)
    trial_dones = len(re.findall(r"\[trial done\]", text))
    if trial_dones:
        out["trial_done_log_lines"] = float(trial_dones)
    return out


def infer_scale_from_dir(name: str) -> int | None:
    m = re.match(r"scale(\d+)gpu_", name)
    return int(m.group(1)) if m else None


def fnum(val: str | float | None, ndigits: int = 2) -> str:
    if val is None or val == "":
        return ""
    try:
        return f"{float(val):.{ndigits}f}"
    except (TypeError, ValueError):
        return str(val)


def collect_runs() -> list[dict]:
    rows: list[dict] = []
    if not RESULTS.is_dir():
        return rows

    for run_dir in sorted(RESULTS.glob("scale*gpu_*")):
        if not run_dir.is_dir():
            continue
        summary = parse_summary(run_dir / "scale_summary.txt")
        doe = parse_doe_log(run_dir / "doe_run.log")

        scale = summary.get("scale_gpus") or summary.get("scale_tier")
        if scale is None:
            scale = infer_scale_from_dir(run_dir.name)
        try:
            scale_gpus = int(float(scale)) if scale is not None else None
        except ValueError:
            scale_gpus = None

        requested = int(summary.get("trials_requested", 0) or 0)
        completed = int(summary.get("trials_completed_dirs", 0) or 0)
        if completed == 0 and doe.get("trial_done_log_lines"):
            completed = int(doe["trial_done_log_lines"])

        particles_dir = run_dir / "particles"
        if particles_dir.is_dir():
            particle_dirs = sum(1 for p in particles_dir.iterdir() if p.is_dir())
            completed = max(completed, particle_dirs)

        if requested == 0 and scale_gpus is not None:
            # Default trial counts from scale_profiles.sh when summary missing
            default_trials = {
                1: 2, 2: 4, 8: 16, 16: 32, 24: 48, 32: 64,
                64: 128, 72: 144, 96: 192, 128: 256,
            }
            requested = default_trials.get(scale_gpus, 0)

        cluster_gpus = float(summary.get("cluster_gpus", scale_gpus or 0) or 0)
        max_conc = int(summary.get("max_concurrent", 0) or 0)
        wall_s = float(summary.get("elapsed_seconds", 0) or 0)
        doe_s = doe.get("doe_elapsed_s") or wall_s or 0.0
        avg_trial = doe.get("avg_sec_per_trial")
        if avg_trial is None and completed and doe_s:
            avg_trial = doe_s / completed
        throughput = doe.get("throughput_trials_per_hr")
        if throughput is None and completed and doe_s:
            throughput = completed / doe_s * 3600.0

        gpu_hours = (cluster_gpus * doe_s / 3600.0) if cluster_gpus and doe_s else 0.0
        trials_per_gpu_hr = (completed / gpu_hours) if gpu_hours else 0.0

        exit_code = summary.get("exit_code", "")
        if exit_code == "" and completed and requested:
            exit_code = "0" if completed >= requested else "1"
        elif exit_code == "" and completed:
            exit_code = "0"

        status = "PASS" if exit_code == "0" and completed >= requested and requested else (
            "PARTIAL" if completed > 0 else "FAIL"
        )
        if requested and completed >= requested and exit_code == "0":
            status = "PASS"
        elif completed > 0:
            status = "PARTIAL" if requested and completed < requested else "PASS"
        else:
            status = "FAIL"

        rows.append(
            {
                "run_dir": run_dir.name,
                "job_id": summary.get("job_id", run_dir.name.split("_")[-1]),
                "status": status,
                "scale_gpus": scale_gpus if scale_gpus is not None else "",
                "cluster_gpus": fnum(cluster_gpus, 1),
                "nodes": summary.get("nodes", ""),
                "partition": summary.get("partition", ""),
                "trials_requested": requested,
                "trials_completed": completed,
                "max_concurrent": max_conc,
                "sim_tend_s": summary.get("sim_tend", ""),
                "wall_clock_s": fnum(wall_s, 1),
                "wall_clock_min": fnum(wall_s / 60.0 if wall_s else None, 1),
                "doe_elapsed_s": fnum(doe_s, 1),
                "doe_elapsed_min": fnum(doe_s / 60.0 if doe_s else None, 1),
                "avg_sec_per_trial": fnum(avg_trial, 1),
                "throughput_trials_per_hr": fnum(throughput, 1),
                "gpu_hours": fnum(gpu_hours, 2),
                "trials_per_gpu_hour": fnum(trials_per_gpu_hr, 2),
                "batches_completed": int(doe.get("batches_completed", 0)),
                "nodelist": summary.get("nodelist", ""),
            }
        )

    # Derived: speedup and parallel efficiency vs smallest successful 1-GPU baseline
    baselines = [
        float(r["avg_sec_per_trial"])
        for r in rows
        if r["status"] == "PASS"
        and r["scale_gpus"] == 1
        and r["avg_sec_per_trial"]
    ]
    if not baselines:
        baselines = [
            float(r["avg_sec_per_trial"])
            for r in rows
            if r["avg_sec_per_trial"] and r["scale_gpus"] == 1
        ]
    baseline = baselines[0] if baselines else None

    for r in rows:
        if baseline and r["avg_sec_per_trial"]:
            avg = float(r["avg_sec_per_trial"])
            speedup = baseline / avg
            gpus = float(r["cluster_gpus"] or r["scale_gpus"] or 1)
            eff = (speedup / gpus * 100.0) if gpus else 0.0
            r["speedup_vs_1gpu"] = fnum(speedup, 2)
            r["parallel_efficiency_pct"] = fnum(eff, 1)
        else:
            r["speedup_vs_1gpu"] = ""
            r["parallel_efficiency_pct"] = ""

    rows.sort(
        key=lambda r: (
            r["status"] != "PASS",
            int(r["scale_gpus"] or 0),
            r["run_dir"],
        )
    )
    return rows


FIELDNAMES = [
    "run_dir",
    "job_id",
    "status",
    "scale_gpus",
    "cluster_gpus",
    "nodes",
    "partition",
    "trials_requested",
    "trials_completed",
    "max_concurrent",
    "sim_tend_s",
    "wall_clock_min",
    "doe_elapsed_min",
    "avg_sec_per_trial",
    "throughput_trials_per_hr",
    "gpu_hours",
    "trials_per_gpu_hour",
    "speedup_vs_1gpu",
    "parallel_efficiency_pct",
    "batches_completed",
    "nodelist",
]


def write_csv(rows: list[dict], path: Path) -> None:
    with path.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=FIELDNAMES, extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)


def write_markdown(rows: list[dict], path: Path) -> None:
    lines = [
        "# ChronoRay FSI-SPH Scale Performance",
        "",
        "| GPUs | Job | Status | Trials | DoE (min) | Avg trial (s) | Throughput (trials/hr) | GPU-hrs | Trials/GPU-hr | Speedup | Par. eff. |",
        "|------|-----|--------|--------|-----------|---------------|------------------------|---------|---------------|---------|-----------|",
    ]
    for r in rows:
        if r["status"] == "FAIL" and not r["trials_completed"]:
            continue
        lines.append(
            f"| {r['scale_gpus']} | {r['job_id']} | {r['status']} | "
            f"{r['trials_completed']}/{r['trials_requested']} | {r['doe_elapsed_min']} | "
            f"{r['avg_sec_per_trial']} | {r['throughput_trials_per_hr']} | {r['gpu_hours']} | "
            f"{r['trials_per_gpu_hour']} | {r['speedup_vs_1gpu']} | {r['parallel_efficiency_pct']}% |"
        )
    lines.extend(["", "## All runs (including partial/failed)", ""])
    for r in rows:
        lines.append(
            f"- **{r['run_dir']}** [{r['status']}]: "
            f"{r['trials_completed']}/{r['trials_requested']} trials, "
            f"DoE {r['doe_elapsed_min']} min, throughput {r['throughput_trials_per_hr']} trials/hr, "
            f"partition={r['partition'] or '?'}"
        )
    path.write_text("\n".join(lines) + "\n")


def main() -> int:
    rows = collect_runs()
    REPORT_DIR.mkdir(parents=True, exist_ok=True)
    csv_path = REPORT_DIR / "scale_performance.csv"
    md_path = REPORT_DIR / "scale_performance.md"
    write_csv(rows, csv_path)
    write_markdown(rows, md_path)

    print(f"Wrote {len(rows)} runs -> {csv_path}")
    print(f"Wrote summary -> {md_path}")
    print()
    print(
        f"{'GPUs':>4} {'Job':>6} {'Status':>7} {'Trials':>9} "
        f"{'DoE min':>8} {'Avg s':>7} {'Trials/hr':>10} {'Spdup':>6}"
    )
    for r in rows:
        if r["status"] == "FAIL" and not r["trials_completed"]:
            continue
        print(
            f"{str(r['scale_gpus']):>4} {str(r['job_id']):>6} {r['status']:>7} "
            f"{r['trials_completed']:>3}/{r['trials_requested']:<5} "
            f"{r['doe_elapsed_min']:>8} {r['avg_sec_per_trial']:>7} "
            f"{r['throughput_trials_per_hr']:>10} {r['speedup_vs_1gpu']:>6}"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
