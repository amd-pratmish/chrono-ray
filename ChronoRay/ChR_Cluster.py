"""
Cluster-aware Ray initialization and AMD/NVIDIA GPU device helpers for ChronoRay.

Multi-node usage (Slurm + Ray):
  1. Launch a Ray cluster via scripts/start_ray_cluster_amd.sh
  2. Set RAY_ADDRESS on the driver node, or rely on auto-detection below
  3. Configure resources_per_trial with gpu=1 for FSI/SPH workloads
"""

from __future__ import annotations

import logging
import os
from typing import Optional


def detect_gpu_backend() -> str:
    """Return 'rocm', 'cuda', or 'none' based on environment and Ray resources."""
    if os.environ.get("ROCM_PATH") or os.environ.get("ROCR_VISIBLE_DEVICES") is not None:
        return "rocm"
    if os.environ.get("CUDA_VISIBLE_DEVICES") is not None:
        return "cuda"
    try:
        import ray

        if not ray.is_initialized():
            return "none"
        resources = ray.cluster_resources()
        if resources.get("GPU", 0) > 0:
            # Ray exposes GPU on both NVIDIA and AMD when ROCm/CUDA drivers are present
            return "rocm" if os.path.isdir("/opt/rocm") else "cuda"
    except Exception:
        pass
    return "none"


def recommended_resources(chrono_module: Optional[str] = None) -> dict:
    """
    Suggest per-trial Ray resources based on Chrono module workload.

    Parameters
    ----------
    chrono_module : str, optional
        One of 'fsi', 'fsi_sph', 'dem', 'vehicle', 'sensor', or None (CPU default).
    """
    module = (chrono_module or "").lower()
    gpu_modules = {"fsi", "fsi_sph", "dem", "sph"}
    if module in gpu_modules:
        return {"cpu": 2, "gpu": 1}
    if module == "vehicle":
        return {"cpu": 4, "gpu": 0}
    return {"cpu": 1, "gpu": 0}


def init_ray(
    *,
    logging_level: int = logging.ERROR,
    log_to_driver: bool = False,
    configure_logging: bool = False,
) -> None:
    """
    Initialize Ray for local or multi-node clusters.

    Connection priority:
      1. Already initialized — no-op
      2. RAY_ADDRESS env var (explicit cluster)
      3. SLURM multi-node job — connect to head at slurm-head:6379
      4. Local single-node fallback
    """
    import ray

    if ray.is_initialized():
        return

    init_kwargs = {
        "logging_level": logging_level,
        "log_to_driver": log_to_driver,
        "configure_logging": configure_logging,
    }

    address = os.environ.get("RAY_ADDRESS")
    if address:
        ray.init(address=address, **init_kwargs)
        return

    if os.environ.get("SLURM_JOB_ID") and os.environ.get("CHR_RAY_HEAD_HOST"):
        head = os.environ["CHR_RAY_HEAD_HOST"]
        port = os.environ.get("CHR_RAY_HEAD_PORT", "6379")
        ray.init(address=f"ray://{head}:{port}", **init_kwargs)
        return

    ray.init(**init_kwargs)


def trial_runtime_env() -> dict:
    """Environment variables propagated to Ray trial workers (PyChrono + ROCm)."""
    import os

    env_vars = {
        "HSA_XNACK": "0",
        "HIP_LAUNCH_BLOCKING": "0",
        "GPU_MAX_HW_QUEUES": "4",
        "RAY_ACCEL_ENV_VAR_OVERRIDE_ON_ZERO": "0",
    }
    venv = "/home/pratmish/chrono-ray/.venv"
    env_vars["VIRTUAL_ENV"] = venv
    env_vars["PATH"] = f"{venv}/bin:/usr/local/bin:/usr/bin:/bin"
    site_packages = f"{venv}/lib/python3.12/site-packages"
    for key in ("PYTHONPATH", "PATH", "LD_LIBRARY_PATH", "ROCM_PATH"):
        val = os.environ.get(key)
        if val:
            if key == "PATH":
                env_vars[key] = f"{venv}/bin:/usr/local/bin:/usr/bin:/bin:{val}"
            elif key == "PYTHONPATH":
                env_vars[key] = f"{site_packages}:{val}"
            else:
                env_vars[key] = val
        elif key == "PYTHONPATH":
            env_vars[key] = site_packages
    ex4 = "/home/pratmish/chrono-ray/ex4-amd-multinode-fsi-doe"
    env_vars["PYTHONPATH"] = f"{ex4}:{env_vars.get('PYTHONPATH', '')}"
    out_dir = os.environ.get("CHR_RAY_OUTPUT_DIR")
    if out_dir:
        env_vars["CHR_RAY_OUTPUT_DIR"] = out_dir
    return {"env_vars": env_vars}


def setup_trial_gpu_env() -> None:
    """
    Configure GPU visibility for the current Ray worker trial.

    When resources_per_trial requests gpu=1, Ray assigns the correct device via
    CUDA_VISIBLE_DEVICES (NVIDIA) or ROCR/HIP env vars (AMD ROCm). Do not override
    these — previous hardcoded CUDA_VISIBLE_DEVICES=0 broke multi-GPU scheduling.

    Applies amd-chronos baseline ROCm runtime settings when unset.
    """
    backend = detect_gpu_backend()

    if backend == "rocm":
        os.environ.setdefault("HSA_XNACK", "0")
        os.environ.setdefault("HIP_LAUNCH_BLOCKING", "0")
        os.environ.setdefault("GPU_MAX_HW_QUEUES", "2")

    os.environ.setdefault("RAY_ACCEL_ENV_VAR_OVERRIDE_ON_ZERO", "0")
