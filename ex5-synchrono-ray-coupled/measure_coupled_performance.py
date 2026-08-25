#!/usr/bin/env python3
"""Aggregate ex5 coupled SynChrono/MPI scale metrics."""

from __future__ import annotations

import csv
import json
import re
from pathlib import Path

EX5 = Path(__file__).resolve().parent
RESULTS = EX5 / "results"
REPORT = EX5 / "results" / "performance"


def parse_summary(path: Path) -> dict:
    d: dict = {}
    if path.is_file():
        for line in path.read_text().splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                d[k.strip()] = v.strip()
    return d


def collect() -> list[dict]:
    rows = []
    for run in sorted(RESULTS.glob("coupled*rank_*")):
        if not run.is_dir():
            continue
        s = parse_summary(run / "scale_summary.txt")
        m = re.match(r"coupled(\d+)rank_", run.name)
        tier = int(m.group(1)) if m else int(float(s.get("scale_tier", 0) or 0))
        completed = int(s.get("trials_completed", 0) or 0)
        requested = int(s.get("trials_requested", 0) or 0)
        elapsed = float(s.get("elapsed_seconds", 0) or 0)
        tp = float(s.get("throughput_trials_per_hr", 0) or 0)
        if not tp and elapsed > 0 and completed:
            tp = completed / elapsed * 3600

        rows.append(
            {
                "cluster_name": s.get("cluster_name", ""),
                "scale_tier": tier,
                "mpi_ranks": s.get("mpi_ranks", tier),
                "job_id": s.get("job_id", ""),
                "partition": s.get("partition", ""),
                "mode": s.get("workload_mode", ""),
                "trials": f"{completed}/{requested}",
                "doe_min": f"{elapsed / 60:.1f}" if elapsed else "",
                "throughput_trials_hr": f"{tp:.1f}" if tp else "",
                "avg_mpi_comm_bw_mbps": s.get(
                    "avg_mpi_comm_bandwidth_mbps", s.get("avg_mpi_sync_bandwidth_mbps", "")
                ),
                "avg_mpi_bcast_latency_us": s.get("avg_mpi_bcast_latency_us", ""),
                "avg_mpi_allreduce_latency_us": s.get("avg_mpi_allreduce_latency_us", ""),
                "mpi_unique_nodes_max": s.get("mpi_unique_nodes_max", ""),
                "mpi_cross_node_trials": s.get("mpi_cross_node_trials", ""),
                "gpu_link_type": s.get("gpu_link_type", ""),
                "mpi_comm_bytes_total": s.get(
                    "mpi_comm_bytes_total", s.get("mpi_sync_bytes_total", "")
                ),
                "avg_mpi_sync_bw_mbps": s.get("avg_mpi_sync_bandwidth_mbps", ""),
                "mpi_sync_bytes_total": s.get("mpi_sync_bytes_total", ""),
                "gpu_bw_util_pct": s.get("gpu_bw_util_pct", "0"),
                "gpu_mem_util_pct": s.get("gpu_mem_util_pct", ""),
                "gpus_per_trial": s.get("gpus_per_trial", "1"),
                "avg_gpu_sph_steps_per_sec": s.get("avg_gpu_sph_steps_per_sec", ""),
                "avg_gpu_sph_fraction_of_heartbeat": s.get(
                    "avg_gpu_sph_fraction_of_heartbeat", ""
                ),
                "exit_code": s.get("exit_code", ""),
            }
        )
    return rows


def write_md(rows: list[dict]) -> None:
    REPORT.mkdir(parents=True, exist_ok=True)
    lines = [
        "# SynChrono / MPI Coupled Scale Performance",
        "",
        "Cross-cluster comparison: see `cluster_name` column. Workload: **gpu_fsi_mpi**.",
        "",
        "| Cluster | Scale | MPI ranks | Nodes | Trials | Throughput | MPI comm MB/s | Bcast µs | Allreduce µs | GPU SPH steps/s | GPU link | Mode |",
        "|---------|-------|-----------|-------|--------|------------|---------------|----------|--------------|-----------------|----------|------|",
    ]
    for r in rows:
        if r.get("exit_code") not in ("0", 0, "0.0", ""):
            continue
        lines.append(
            f"| {r.get('cluster_name', '')} | {r['scale_tier']} | {r['mpi_ranks']} | "
            f"{r.get('mpi_unique_nodes_max', '')} | {r['trials']} | "
            f"{r['throughput_trials_hr']} | {r.get('avg_mpi_comm_bw_mbps', '')} | "
            f"{r.get('avg_mpi_bcast_latency_us', '')} | {r.get('avg_mpi_allreduce_latency_us', '')} | "
            f"{r.get('avg_gpu_sph_steps_per_sec', '')} | {r.get('gpu_link_type', '')} | {r['mode']} |"
        )
    (REPORT / "coupled_scale_performance.md").write_text("\n".join(lines) + "\n")

    csv_path = REPORT / "coupled_scale_performance.csv"
    if rows:
        with csv_path.open("w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
            w.writeheader()
            w.writerows(rows)


def main() -> int:
    rows = collect()
    write_md(rows)
    print(f"Wrote {len(rows)} runs -> {REPORT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
