"""Ray DoE for GPU + MPI coupled scaling ladder (PyChrono FSI on GPU rank)."""

from __future__ import annotations

import json
import os
import time
from pathlib import Path

from ChronoRay import ChRDoE, init_ray
from ChronoRay.ChR_MpiCoupled import make_mpi_simulate_fn, recommended_resources_coupled

EX5 = Path(__file__).resolve().parent
GPU_MPI_SCRIPT = str(EX5 / "gpu_mpi_fsi_coupled.py")
BUILD_BIN = os.environ.get(
    "CHRONO_BUILD_BIN",
    str(Path(os.environ.get("PYCHRONO_BIN", "/home/pratmish/amd-chronos/build-mi355x/bin")).parent / "build-mi355x-synchrono" / "bin"),
)
SYN_SCM_BINARY = os.path.join(BUILD_BIN, "demo_SYN_scm")
PYCHRONO_BIN = os.environ.get(
    "PYCHRONO_BIN", os.environ.get("CHR_PYCHRONO_BIN", "/home/pratmish/amd-chronos/build-mi355x/bin")
)

GPU_FSI_FLAGS = {
    "sim_tend": "sim_tend",
    "heartbeat": "heartbeat",
    "mu_s": "mu_s",
    "density": "density",
    "Young_modulus": "Young_modulus",
    "Poisson_ratio": "Poisson_ratio",
    "mcc_lambda": "mcc_lambda",
    "kappa_ratio": "kappa_ratio",
}

SYNCHRONO_SCM_FLAGS = {
    "end_time": "end_time",
    "heartbeat": "heartbeat",
    "step_size": "step_size",
    "dpu": "dpu",
    "size_x": "sizeX",
    "size_y": "sizeY",
}


def _mode() -> str:
    m = os.environ.get("CHR_RAY_MODE", "gpu_fsi_mpi")
    if m == "auto":
        if os.path.isfile(SYN_SCM_BINARY):
            return "synchrono"
        return "gpu_fsi_mpi"
    return m


def _verify_gpu_fsi() -> None:
    import sys

    sys.path.insert(0, PYCHRONO_BIN)
    import pychrono.fsi  # noqa: F401


def _param_space(mode: str) -> dict:
    if mode == "gpu_fsi_mpi":
        return {
            "sim_tend": ChRDoE.ChR_Distr.uniform(0.3, 0.5),
            "heartbeat": ChRDoE.ChR_Distr.uniform(0.02, 0.03),
            "mu_s": ChRDoE.ChR_Distr.uniform(0.4, 0.8),
            "density": ChRDoE.ChR_Distr.uniform(1400, 1800),
            "Young_modulus": ChRDoE.ChR_Distr.loguniform(1e5, 5e6),
            "Poisson_ratio": ChRDoE.ChR_Distr.uniform(0.25, 0.4),
            "mcc_lambda": ChRDoE.ChR_Distr.uniform(0.05, 0.15),
            "kappa_ratio": ChRDoE.ChR_Distr.uniform(0.08, 0.2),
        }
    if mode == "synchrono":
        return {
            "end_time": ChRDoE.ChR_Distr.uniform(2.0, 6.0),
            "heartbeat": ChRDoE.ChR_Distr.uniform(0.01, 0.04),
            "step_size": ChRDoE.ChR_Distr.uniform(0.002, 0.004),
            "dpu": ChRDoE.ChR_Distr.randint(12, 20),
            "size_x": ChRDoE.ChR_Distr.uniform(80.0, 100.0),
            "size_y": ChRDoE.ChR_Distr.uniform(40.0, 50.0),
        }
    raise ValueError(f"Unknown mode: {mode}")


def main() -> None:
    scale = int(os.environ.get("CHR_COUPLED_SCALE", "8"))
    mpi_ranks = int(os.environ.get("CHR_MPI_RANKS", str(max(2, scale))))
    num_trials = int(os.environ.get("CHR_RAY_NUM_TRIALS", str(2 * scale)))
    max_concurrent = int(os.environ.get("CHR_RAY_MAX_CONCURRENT", "1"))
    if os.environ.get("CHR_RAY_MULTI_GPU_CONCURRENT", "0") != "1":
        max_concurrent = min(max_concurrent, 1)  # 1 nested srun step at a time unless multi-GPU mode
    cpus_per_rank = int(os.environ.get("CHR_MPI_CPUS_PER_RANK", "2"))
    mode = _mode()

    if mode == "gpu_fsi_mpi":
        _verify_gpu_fsi()
        py = os.environ.get("CHR_MPI_PYTHON", os.environ.get("PYTHON", "python3"))
        simulate_fn = make_mpi_simulate_fn(
            binary=py,
            flag_map=GPU_FSI_FLAGS,
            mpi_ranks=mpi_ranks,
            extra_args=[GPU_MPI_SCRIPT],
        )
        resources = recommended_resources_coupled(
            "gpu_fsi_mpi", mpi_ranks=mpi_ranks, cpus_per_rank=cpus_per_rank, gpus_for_terrain=0
        )
        # Per-trial MPI timeout (~15–20 min/trial with metrics; scales with MPI ranks).
        os.environ.setdefault(
            "CHR_MPI_TRIAL_TIMEOUT",
            str(min(14400, max(3600, 1800 + mpi_ranks * 600))),
        )
        os.environ.setdefault("CHR_RAY_GET_TIMEOUT", os.environ["CHR_MPI_TRIAL_TIMEOUT"])
    elif mode == "synchrono":
        simulate_fn = make_mpi_simulate_fn(
            binary=SYN_SCM_BINARY,
            flag_map=SYNCHRONO_SCM_FLAGS,
            mpi_ranks=mpi_ranks,
            extra_args=["--contact_method", "SMC", "--terrain_type", "Flat"],
        )
        resources = recommended_resources_coupled(
            "synchrono_mpi", mpi_ranks=mpi_ranks, cpus_per_rank=cpus_per_rank
        )
    else:
        raise ValueError(f"Unsupported mode: {mode}")

    print("=== ChronoRay ex5 GPU+MPI coupled scale DoE ===", flush=True)
    print(f"  Scale tier:       {scale}", flush=True)
    print(f"  Mode:             {mode}", flush=True)
    print(f"  MPI ranks/trial:  {mpi_ranks} (GPU on rank {os.environ.get('CHR_GPU_MPI_RANK', '0')})", flush=True)
    print(f"  Trials:           {num_trials}", flush=True)
    print(f"  Max concurrent:   {max_concurrent}", flush=True)
    print(f"  Ray resources:    {resources}", flush=True)
    print("==============================================", flush=True)

    init_ray(log_to_driver=True)

    doe = ChRDoE(
        simulate_fn,
        _param_space(mode),
        sampling_design=ChRDoE.SamplingDesign.LATIN_HYPERCUBE,
        num_trials=num_trials,
        max_concurrent_trials=max_concurrent,
        FLAG_log_to_file=False,
        FLAG_auto_run=False,
    )
    doe.set_resources_per_trial(cpu=resources["cpu"], gpu=resources["gpu"])
    doe._build()

    t0 = time.time()
    doe.run()
    elapsed = time.time() - t0

    print(f"Coupled DoE completed in {elapsed:.1f}s ({elapsed / 60:.1f} min)")
    if num_trials > 0 and elapsed > 0:
        print(f"  Throughput: {num_trials / elapsed * 3600:.1f} trials/hr")

    _write_scale_summary(scale, mpi_ranks, num_trials, elapsed, mode)


def _aggregate_trial_json(run_dir: Path) -> tuple[int, dict]:
    trial_dirs: set[Path] = set()
    totals = {
        "sync_bytes": 0,
        "comm_bw_sum": 0.0,
        "comm_bw_n": 0,
        "bcast_lat_sum": 0.0,
        "bcast_lat_n": 0,
        "allreduce_lat_sum": 0.0,
        "allreduce_lat_n": 0,
        "comm_wall_sum": 0.0,
        "comm_wall_n": 0,
        "gpu_util": 0.0,
        "gpu_mem_util": 0.0,
        "gpu_sph_steps": 0,
        "gpu_sph_steps_per_sec": 0.0,
        "gpu_sph_n": 0,
        "gpu_sph_frac_sum": 0.0,
        "gpu_sph_frac_n": 0,
        "mpi_unique_nodes_max": 0,
        "mpi_cross_node_trials": 0,
        "gpu_link_type": "",
        "xgmi_link_count_max": 0,
    }
    for name in ("gpu_coupled_summary.json", "smoke_summary.json"):
        for p in run_dir.rglob(name):
            trial_dirs.add(p.parent)
            try:
                d = json.loads(p.read_text())
                totals["sync_bytes"] += int(
                    d.get("mpi_comm_bytes_total", d.get("mpi_sync_bytes_total", 0))
                )
                comm_bw = d.get("mpi_comm_bandwidth_mbps", d.get("mpi_sync_bandwidth_mbps"))
                if comm_bw:
                    totals["comm_bw_sum"] += float(comm_bw)
                    totals["comm_bw_n"] += 1
                if d.get("avg_mpi_bcast_latency_us"):
                    totals["bcast_lat_sum"] += float(d["avg_mpi_bcast_latency_us"])
                    totals["bcast_lat_n"] += 1
                if d.get("avg_mpi_allreduce_latency_us"):
                    totals["allreduce_lat_sum"] += float(d["avg_mpi_allreduce_latency_us"])
                    totals["allreduce_lat_n"] += 1
                if d.get("mpi_comm_wall_seconds"):
                    totals["comm_wall_sum"] += float(d["mpi_comm_wall_seconds"])
                    totals["comm_wall_n"] += 1
                totals["gpu_util"] = max(totals["gpu_util"], float(d.get("gpu_bw_util_pct", 0)))
                totals["gpu_mem_util"] = max(
                    totals["gpu_mem_util"], float(d.get("gpu_mem_util_pct", 0))
                )
                if d.get("gpu_sph_steps"):
                    totals["gpu_sph_steps"] += int(d["gpu_sph_steps"])
                    totals["gpu_sph_n"] += 1
                if d.get("gpu_sph_steps_per_sec"):
                    totals["gpu_sph_steps_per_sec"] += float(d["gpu_sph_steps_per_sec"])
                if d.get("gpu_sph_fraction_of_heartbeat"):
                    totals["gpu_sph_frac_sum"] += float(d["gpu_sph_fraction_of_heartbeat"])
                    totals["gpu_sph_frac_n"] += 1
                if d.get("mpi_unique_nodes"):
                    totals["mpi_unique_nodes_max"] = max(
                        totals["mpi_unique_nodes_max"], int(d["mpi_unique_nodes"])
                    )
                if d.get("mpi_cross_node_traffic"):
                    totals["mpi_cross_node_trials"] += 1
                if d.get("gpu_link_type") and not totals["gpu_link_type"]:
                    totals["gpu_link_type"] = str(d["gpu_link_type"])
                if d.get("xgmi_link_count"):
                    totals["xgmi_link_count_max"] = max(
                        totals["xgmi_link_count_max"], int(d["xgmi_link_count"])
                    )
            except Exception:
                pass
    for p in run_dir.rglob("trial_summary.txt"):
        trial_dirs.add(p.parent)
    return len(trial_dirs), totals


def _write_scale_summary(scale: int, mpi_ranks: int, num_trials: int, elapsed: float, mode: str) -> None:
    run_dir = Path(os.environ.get("CHR_RAY_OUTPUT_DIR", EX5 / "results"))
    job_id = os.environ.get("SLURM_JOB_ID", "local")

    completed, totals = _aggregate_trial_json(run_dir)
    avg_comm_bw = totals["comm_bw_sum"] / totals["comm_bw_n"] if totals["comm_bw_n"] else 0.0
    avg_bcast_us = totals["bcast_lat_sum"] / totals["bcast_lat_n"] if totals["bcast_lat_n"] else 0.0
    avg_ar_us = (
        totals["allreduce_lat_sum"] / totals["allreduce_lat_n"] if totals["allreduce_lat_n"] else 0.0
    )
    avg_comm_wall = (
        totals["comm_wall_sum"] / totals["comm_wall_n"] if totals["comm_wall_n"] else 0.0
    )
    avg_sph_rate = (
        totals["gpu_sph_steps_per_sec"] / totals["gpu_sph_n"] if totals["gpu_sph_n"] else 0.0
    )
    avg_sph_frac = (
        totals["gpu_sph_frac_sum"] / totals["gpu_sph_frac_n"] if totals["gpu_sph_frac_n"] else 0.0
    )

    summary_path = run_dir / "scale_summary.txt"
    cluster = os.environ.get("CHR_CLUSTER_NAME", os.environ.get("CHR_CLUSTER", "unknown"))
    partition = os.environ.get("SLURM_JOB_PARTITION", "")
    nodelist = os.environ.get("SLURM_JOB_NODELIST", "")
    lines = [
        f"cluster_name={cluster}",
        f"scale_tier={scale}",
        f"mpi_ranks={mpi_ranks}",
        f"gpus_per_trial=1",
        f"gpus_per_node={os.environ.get('CHR_RAY_GPUS_PER_NODE', '1')}",
        f"max_concurrent={os.environ.get('CHR_RAY_MAX_CONCURRENT', '1')}",
        f"workload_mode={mode}",
        f"trials_requested={num_trials}",
        f"trials_completed={completed}",
        f"elapsed_seconds={elapsed:.1f}",
        f"throughput_trials_per_hr={num_trials / elapsed * 3600 if elapsed > 0 else 0:.1f}",
        f"mpi_comm_bytes_total={totals['sync_bytes']}",
        f"avg_mpi_comm_bandwidth_mbps={avg_comm_bw:.4f}",
        f"avg_mpi_bcast_latency_us={avg_bcast_us:.2f}",
        f"avg_mpi_allreduce_latency_us={avg_ar_us:.2f}",
        f"avg_mpi_comm_wall_seconds={avg_comm_wall:.4f}",
        f"mpi_unique_nodes_max={totals['mpi_unique_nodes_max']}",
        f"mpi_cross_node_trials={totals['mpi_cross_node_trials']}",
        f"gpu_link_type={totals['gpu_link_type']}",
        f"xgmi_link_count_max={totals['xgmi_link_count_max']}",
        # Legacy alias (comm-only bandwidth, not heartbeat-inflated)
        f"mpi_sync_bytes_total={totals['sync_bytes']}",
        f"avg_mpi_sync_bandwidth_mbps={avg_comm_bw:.4f}",
        f"gpu_bw_util_pct={totals['gpu_util']:.2f}",
        f"gpu_mem_util_pct={totals['gpu_mem_util']:.2f}",
        f"gpu_sph_steps_total={totals['gpu_sph_steps']}",
        f"avg_gpu_sph_steps_per_sec={avg_sph_rate:.1f}",
        f"avg_gpu_sph_fraction_of_heartbeat={avg_sph_frac:.4f}",
        f"gpu_note=fsi_sph_on_rank_{mpi_ranks - 1}; gpu_gpu_fabric=single_gpu_per_trial",
        f"exit_code=0",
        f"job_id={job_id}",
        f"partition={partition}",
        f"nodelist={nodelist}",
    ]
    summary_path.write_text("\n".join(lines) + "\n")
    print(f"Wrote {summary_path}", flush=True)


if __name__ == "__main__":
    main()
