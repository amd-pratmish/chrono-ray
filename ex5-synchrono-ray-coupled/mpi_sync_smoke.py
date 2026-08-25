#!/usr/bin/env python3
"""
MPI smoke test with configurable sync payload — models SynChrono heartbeat traffic.

Measures:
  - mpi_sync_bytes_total / mpi_sync_wall_seconds → sync bandwidth (MB/s)
  - avg_sync_latency_ms per Allreduce
  - gpu metrics: N/A for SCM smoke (gpu_bw_util_pct=0); populated for cosim runs

Run:
  mpirun -np 8 python3 mpi_sync_smoke.py --steps 500 --heartbeat 10 --payload_kb 256
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time

try:
    from mpi4py import MPI
except ImportError as exc:
    print("mpi4py required: pip install mpi4py", file=sys.stderr)
    raise SystemExit(1) from exc

try:
    import numpy as np
except ImportError:
    np = None  # type: ignore


def _sample_gpu_metrics() -> dict:
    """Best-effort GPU bandwidth/util via rocm-smi (0 if unavailable or CPU-only run)."""
    out = {
        "gpu_bw_util_pct": 0.0,
        "gpu_mem_bw_gbps": 0.0,
        "gpu_devices": 0,
        "gpu_note": "cpu_only_workload",
    }
    try:
        import subprocess

        rocm = subprocess.run(
            ["rocm-smi", "--showuse", "--showmeminfo", "vram"],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if rocm.returncode != 0:
            out["gpu_note"] = "rocm-smi_unavailable"
            return out
        # Count GPU lines heuristically
        out["gpu_devices"] = rocm.stdout.lower().count("gpu[")
        out["gpu_note"] = "sampled_at_trial_end"
    except Exception as exc:
        out["gpu_note"] = f"gpu_sample_failed:{exc}"
    return out


def main() -> int:
    comm = MPI.COMM_WORLD
    rank = comm.Get_rank()
    size = comm.Get_size()

    parser = argparse.ArgumentParser()
    parser.add_argument("--steps", type=int, default=500)
    parser.add_argument("--heartbeat", type=int, default=10, help="sync every N steps")
    parser.add_argument("--dt", type=float, default=0.01)
    parser.add_argument("--seed", type=float, default=1.0)
    parser.add_argument("--payload_kb", type=int, default=256, help="Allreduce payload per sync (KB)")
    parser.add_argument("--output", type=str, default=".")
    args = parser.parse_args()

    if size < 2:
        if rank == 0:
            print("Need >= 2 MPI ranks for coupled smoke test", file=sys.stderr)
        return 1

    if np is None:
        if rank == 0:
            print("numpy required for payload sync benchmark", file=sys.stderr)
        return 1

    out_dir = os.environ.get("CHR_RAY_TRIAL_OUTPUT", args.output)
    os.makedirs(out_dir, exist_ok=True)

    payload_elems = max(1, (args.payload_kb * 1024) // 8)  # float64
    payload = np.zeros(payload_elems, dtype=np.float64)
    payload[0] = args.seed + rank

    local_state = args.seed + rank * 0.1
    sync_count = 0
    sync_wall = 0.0
    t0 = time.time()

    for step in range(args.steps):
        local_state += args.dt * (1.0 + 0.01 * rank)
        payload[0] = local_state

        if step % args.heartbeat == 0:
            t_sync = time.time()
            # Scalar coupling (SynChrono manager handshake analog)
            global_sum = comm.allreduce(local_state, op=MPI.SUM)
            avg = global_sum / size
            local_state = 0.5 * local_state + 0.5 * avg
            # Payload exchange (agent state vector analog)
            recv = np.empty_like(payload)
            comm.Allreduce(payload, recv, op=MPI.SUM)
            payload = recv / size
            sync_wall += time.time() - t_sync
            sync_count += 1

    elapsed = time.time() - t0
    final_sum = comm.allreduce(local_state, op=MPI.SUM)

    # Bytes moved: each Allreduce moves ~2*P bytes per rank (typical tree/butterfly factor ~2)
    payload_bytes = payload_elems * 8
    bytes_per_sync = int(2 * payload_bytes * size)
    total_sync_bytes = bytes_per_sync * sync_count

    sync_stats = {
        "sync_events": sync_count,
        "sync_wall_seconds": round(sync_wall, 6),
        "avg_sync_latency_ms": round((sync_wall / sync_count * 1000) if sync_count else 0, 4),
        "payload_kb": args.payload_kb,
        "bytes_per_sync": bytes_per_sync,
        "mpi_sync_bytes_total": total_sync_bytes,
        "mpi_sync_bandwidth_mbps": round(
            (total_sync_bytes / sync_wall / 1e6) if sync_wall > 0 else 0, 2
        ),
    }

    if rank == 0:
        gpu = _sample_gpu_metrics()
        summary = {
            "mpi_ranks": size,
            "steps": args.steps,
            "heartbeat_interval": args.heartbeat,
            "final_global_sum": float(final_sum),
            "elapsed_seconds": round(elapsed, 4),
            "workload": "mpi_sync_smoke",
            **sync_stats,
            **gpu,
        }
        path = os.path.join(out_dir, "smoke_summary.json")
        with open(path, "w") as f:
            json.dump(summary, f, indent=2)
        print(
            f"Smoke PASS: {size} ranks, {sync_count} syncs, "
            f"MPI BW={summary['mpi_sync_bandwidth_mbps']} MB/s, {elapsed:.3f}s",
            flush=True,
        )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
