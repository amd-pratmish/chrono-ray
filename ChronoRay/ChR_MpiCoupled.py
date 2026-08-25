"""
Ray orchestration helpers for **coupled** Chrono simulations that require
MPI (or multi-process) synchronization between ranks.

Contrast with ex4 (embarrassingly parallel):
  - ex4: 1 Ray trial = 1 GPU = 1 independent FSI-SPH sim (no inter-GPU physics sync)
  - ex5: 1 Ray trial = 1 mpirun job = N MPI ranks with SynChrono heartbeat sync

Supported Chrono coupled patterns (C++ binaries from amd-chronos):
  - SynChrono MPI  (demo_SYN_scm, demo_SYN_wheeled, ...) — CPU vehicle fleets + SCM terrain
  - Vehicle cosim  (demo_VEH_Cosim_WheeledVehicle_SPH) — MPI ranks + optional GPU SPH terrain

FSI-SPH multi-GPU domain decomposition is NOT supported by Chrono; use ex4 for GPU DoE sweeps.
"""

from __future__ import annotations

import os
import shlex
import subprocess
import time
from pathlib import Path
from typing import Callable, Optional


def recommended_resources_coupled(
    workload: str,
    *,
    mpi_ranks: int = 4,
    cpus_per_rank: int = 4,
    gpus_for_terrain: int = 0,
) -> dict:
    """
    Suggest Ray resources for one coupled MPI trial.

    Parameters
    ----------
    workload : str
        One of 'synchrono_mpi', 'vehicle_cosim_mpi', 'fsi_sph_independent'.
    mpi_ranks : int
        Number of MPI processes launched per trial (SynChrono agents / cosim ranks).
    cpus_per_rank : int
        CPUs reserved per MPI rank on the Ray worker node.
    gpus_for_terrain : int
        GPUs for ranks that run FSI-SPH terrain (vehicle cosim only).
    """
    wl = workload.lower()
    if wl in {"gpu_mpi_fsi", "gpu_fsi_mpi", "gpu_coupled", "cosim"}:
        # GPU is driven by nested srun/MPI (Slurm gres), not Ray actors — avoid double-booking.
        return {"cpu": max(4, cpus_per_rank * 2), "gpu": 0}
    if wl in {"synchrono_mpi", "synchrono", "scm"}:
        return {"cpu": mpi_ranks * cpus_per_rank, "gpu": 0}
    if wl in {"vehicle_cosim_mpi", "cosim", "veh_cosim"}:
        return {"cpu": mpi_ranks * cpus_per_rank, "gpu": gpus_for_terrain}
    if wl in {"fsi_sph_independent", "fsi_sph", "fsi"}:
        return {"cpu": 2, "gpu": 1}
    return {"cpu": mpi_ranks * cpus_per_rank, "gpu": gpus_for_terrain}


def config_to_cli_args(config: dict, flag_map: dict[str, str]) -> list[str]:
    """
    Convert a parameter dict to CLI flags for a Chrono C++ demo.

    flag_map maps config keys to short or long option names, e.g.
        {"end_time": "end_time", "heartbeat": "heartbeat", "dpu": "dpu"}
    """
    args: list[str] = []
    for key, flag in flag_map.items():
        if key not in config:
            continue
        val = config[key]
        if isinstance(val, bool):
            if val:
                args.append(f"--{flag}")
        else:
            args.extend([f"--{flag}", str(val)])
    return args


def _trial_output_dir(base: Path, trial_id: str) -> Path:
    out = base / trial_id
    out.mkdir(parents=True, exist_ok=True)
    return out


def run_mpi_coupled_trial(
    *,
    binary: str,
    config: dict,
    flag_map: dict[str, str],
    mpi_ranks: int,
    trial_id: Optional[str] = None,
    output_root: Optional[str] = None,
    extra_args: Optional[list[str]] = None,
    timeout_sec: int = 0,
    launcher: Optional[str] = None,
) -> dict:
    """
    Run one coupled Chrono simulation as an MPI subprocess.

    Under Slurm, uses ``srun`` so ranks can span nodes allocated to the batch job.
    Locally, uses ``mpirun -np N``.

    Returns a result dict with exit_code, elapsed_seconds, log paths.
    """
    if mpi_ranks < 2:
        raise ValueError("Coupled SynChrono trials require mpi_ranks >= 2 for inter-rank sync")

    root = Path(output_root or os.environ.get("CHR_RAY_OUTPUT_DIR", os.getcwd()))
    tid = trial_id or _make_trial_id(config)
    out_dir = _trial_output_dir(root, tid)

    cli_args = config_to_cli_args(config, flag_map)
    if extra_args:
        cli_args = extra_args + cli_args

    stdout_log = out_dir / "mpi_stdout.log"
    stderr_log = out_dir / "mpi_stderr.log"

    use_srun = launcher == "srun" or (
        launcher is None and os.environ.get("SLURM_JOB_ID") and os.environ.get("CHR_MPI_USE_SRUN", "1") != "0"
    )

    if use_srun:
        # --overlap: batch script + nested MPI steps share the job's ntasks allocation.
        # --mpi=pmix: wire mpi4py/OpenMPI to Slurm-launched ranks (default srun gives size=1).
        srun_extra = os.environ.get("CHR_SRUN_EXTRA", "--overlap").split()
        mpi_flavor = os.environ.get("CHR_SRUN_MPI", "pmix")
        cmd = [
            "srun",
            *srun_extra,
            f"--mpi={mpi_flavor}",
            "--ntasks", str(mpi_ranks),
            "--cpus-per-task", os.environ.get("CHR_MPI_CPUS_PER_RANK", "1"),
            "--kill-on-bad-exit=1",
        ]
        ntasks_per_node = os.environ.get("CHR_SRUN_NTASKS_PER_NODE", "").strip()
        if ntasks_per_node:
            cmd.extend(["--ntasks-per-node", ntasks_per_node])
        distribution = os.environ.get("CHR_SRUN_DISTRIBUTION", "").strip()
        if distribution:
            cmd.extend(["--distribution", distribution])
        # Pin GPU rank to Slurm GPU binding on multi-node steps (rank 0 = first node / gres).
        if os.environ.get("CHR_SRUN_GPU_BIND", "1") == "1":
            cmd.extend(["--gpu-bind", "single:1"])
        if os.environ.get("CHR_SRUN_GRES_GPU", "0") == "1":
            gres_one = os.environ.get("CHR_SRUN_GRES_ONE", "gpu:amd_instinct_mi355_oam:1")
            cmd.extend([f"--gres={gres_one}"])
        cmd.extend([binary, *cli_args])
    else:
        mpi_launcher = os.environ.get("CHR_MPIRUN", "mpirun")
        cmd = [
            mpi_launcher,
            "-np", str(mpi_ranks),
            "--bind-to", "none",
            binary,
            *cli_args,
        ]

    env = os.environ.copy()
    # Nested MPI must use Slurm GPU binding, not Ray worker accelerator pinning.
    for _k in ("CUDA_VISIBLE_DEVICES", "ROCR_VISIBLE_DEVICES", "HIP_VISIBLE_DEVICES"):
        env.pop(_k, None)
    env["CHR_RAY_TRIAL_ID"] = tid
    env["CHR_RAY_TRIAL_OUTPUT"] = str(out_dir)

    if timeout_sec <= 0:
        timeout_sec = int(os.environ.get("CHR_MPI_TRIAL_TIMEOUT", "7200"))

    print(f"[mpi trial {tid}] ranks={mpi_ranks} launcher={'srun' if use_srun else 'mpirun'}", flush=True)
    print(f"[mpi trial {tid}] cmd: {shlex.join(cmd)}", flush=True)

    t0 = time.time()
    with stdout_log.open("w") as fout, stderr_log.open("w") as ferr:
        proc = subprocess.run(
            cmd,
            stdout=fout,
            stderr=ferr,
            env=env,
            timeout=timeout_sec,
            cwd=str(out_dir),
        )
    elapsed = time.time() - t0

    summary_path = out_dir / "trial_summary.txt"
    summary_path.write_text(
        "\n".join(
            [
                f"trial_id={tid}",
                f"mpi_ranks={mpi_ranks}",
                f"binary={binary}",
                f"exit_code={proc.returncode}",
                f"elapsed_seconds={elapsed:.1f}",
                f"launcher={'srun' if use_srun else 'mpirun'}",
                f"config={config}",
            ]
        )
        + "\n"
    )

    result = {
        "trial_id": tid,
        "exit_code": proc.returncode,
        "elapsed_seconds": elapsed,
        "output_dir": str(out_dir),
        "stdout_log": str(stdout_log),
        "stderr_log": str(stderr_log),
    }
    print(f"[mpi trial {tid}] done exit={proc.returncode} elapsed={elapsed:.1f}s", flush=True)
    return result


def _make_trial_id(config: dict) -> str:
    parts = []
    for k in sorted(config.keys()):
        v = config[k]
        if isinstance(v, float):
            parts.append(f"{k}={v:.4g}")
        else:
            parts.append(f"{k}={v}")
    return "t_" + "_".join(parts)[:120]


def make_mpi_simulate_fn(
    *,
    binary: str,
    flag_map: dict[str, str],
    mpi_ranks: int,
    extra_args: Optional[list[str]] = None,
    fail_on_nonzero: bool = True,
) -> Callable[[dict], None]:
    """
    Factory: returns a simulate_fn(config) suitable for ChRDoE.run().

    Each call launches one full MPI job with SynChrono (or cosim) synchronization.
    Reserve Ray resources with recommended_resources_coupled() before running DoE.
    """

    def simulate_fn(config: dict) -> None:
        result = run_mpi_coupled_trial(
            binary=binary,
            config=config,
            flag_map=flag_map,
            mpi_ranks=mpi_ranks,
            extra_args=extra_args,
        )
        if fail_on_nonzero and result["exit_code"] != 0:
            raise RuntimeError(
                f"MPI trial {result['trial_id']} failed with exit {result['exit_code']}; "
                f"see {result['stderr_log']}"
            )

    return simulate_fn
