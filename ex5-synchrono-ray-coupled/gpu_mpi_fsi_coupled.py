#!/usr/bin/env python3
"""
GPU + MPI coupled FSI trial (PyChrono HIP on 1 rank, CPU ranks sync via MPI).

Models vehicle cosim topology at a minimal level:
  - GPU rank (last): runs FSI-SPH angle-of-repose on AMD GPU (HIP)
  - CPU ranks:       lightweight coupling agents exchanging state each heartbeat

Requires: mpi4py, pychrono.fsi (amd-chronos build-mi355x), ROCm on GPU rank node.

Run:
  srun -n 4 --gres=gpu:1 python3 gpu_mpi_fsi_coupled.py --sim_tend 0.5 --heartbeat 0.02
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
import time

try:
    from mpi4py import MPI
except ImportError:
    print("mpi4py required", file=sys.stderr)
    raise SystemExit(1) from None

import numpy as np

# Slurm gres=gpu:1 lands on the first node; GPU SPH must run on that rank (not last).
def gpu_rank(size: int) -> int:
    raw = os.environ.get("CHR_GPU_MPI_RANK", "0")
    g = int(raw)
    if g < 0:
        g = size - 1
    if g >= size:
        g = size - 1
    return g


def _sample_gpu_metrics() -> dict:
    out = {
        "gpu_bw_util_pct": 0.0,
        "gpu_vram_used_mb": 0.0,
        "gpu_devices": 0,
        "gpu_mem_util_pct": 0.0,
    }
    try:
        import subprocess

        proc = subprocess.run(
            ["rocm-smi", "--showuse", "--showmeminfo", "vram", "--showmemuse"],
            capture_output=True,
            text=True,
            timeout=5,
            start_new_session=True,
        )
        if proc.returncode != 0:
            return out
        text = proc.stdout.lower()
        out["gpu_devices"] = text.count("gpu[")
        for line in proc.stdout.splitlines():
            ll = line.lower()
            if "gpu use" in ll or "gpu utilization" in ll:
                for p in line.split():
                    if p.endswith("%"):
                        out["gpu_bw_util_pct"] = max(out["gpu_bw_util_pct"], float(p.rstrip("%")))
            if "memory use" in ll or "mem use" in ll:
                for p in line.split():
                    if p.endswith("%"):
                        out["gpu_mem_util_pct"] = max(out["gpu_mem_util_pct"], float(p.rstrip("%")))
            if "vram" in ll and "used" in ll:
                for p in line.split():
                    try:
                        val = float(p.replace(",", ""))
                        if val > out["gpu_vram_used_mb"]:
                            out["gpu_vram_used_mb"] = val
                    except ValueError:
                        pass
    except Exception:
        pass
    return out


def _sample_gpu_interconnect() -> dict:
    """Best-effort AMD GPU link / fabric telemetry (xGMI, PCIe, topology)."""
    out = {
        "gpu_link_type": "",
        "gpu_link_speed_gts": 0.0,
        "xgmi_link_count": 0,
        "gpu_topo_summary": "",
    }
    if os.environ.get("CHR_GPU_TOPO_SAMPLE", "0") != "1":
        return out
    try:
        import subprocess

        proc = subprocess.run(
            ["rocm-smi", "--showtopo"],
            capture_output=True,
            text=True,
            timeout=5,
            start_new_session=True,
        )
        if proc.returncode == 0 and proc.stdout.strip():
            out["gpu_topo_summary"] = proc.stdout.strip().replace("\n", " | ")[:500]
            low = proc.stdout.lower()
            if "xgmi" in low:
                out["gpu_link_type"] = "xgmi"
                out["xgmi_link_count"] = low.count("xgmi")
            elif "pcie" in low:
                out["gpu_link_type"] = "pcie"
            for line in proc.stdout.splitlines():
                if "gt/s" in line.lower() or "gts" in line.lower():
                    for tok in line.replace(",", "").split():
                        try:
                            if "gt" in tok.lower():
                                out["gpu_link_speed_gts"] = max(
                                    out["gpu_link_speed_gts"], float(tok.lower().split("gt")[0])
                                )
                        except ValueError:
                            pass
    except Exception:
        pass
    return out


def _mpi_topology(comm: MPI.Intracomm, g_rank: int) -> dict:
    """Node placement for MPI ranks (multi-node network path analysis)."""
    rank = comm.Get_rank()
    size = comm.Get_size()
    host = MPI.Get_processor_name()
    hosts = comm.gather(host, root=g_rank)
    if rank != g_rank:
        return {}
    assert hosts is not None
    unique_nodes = len(set(hosts))
    gpu_host = hosts[g_rank]
    cpu_ranks = [i for i in range(size) if i != g_rank]
    cpu_on_gpu_node = sum(1 for i in cpu_ranks if hosts[i] == gpu_host)
    cpu_remote = len(cpu_ranks) - cpu_on_gpu_node
    return {
        "mpi_unique_nodes": unique_nodes,
        "mpi_gpu_node": gpu_host,
        "mpi_cpu_ranks_on_gpu_node": cpu_on_gpu_node,
        "mpi_cpu_ranks_remote": cpu_remote,
        "mpi_cross_node_traffic": cpu_remote > 0,
    }


def _run_gpu_sph(config: dict, n_steps: int) -> dict:
    """Run GPU FSI-SPH steps; return coupling scalars for MPI exchange."""
    from ChronoRay.ChR_Cluster import setup_trial_gpu_env

    setup_trial_gpu_env()

    import pychrono as chrono
    import pychrono.fsi as fsi

    # Fixed step — matches ex4 FSI-SPH (variable dt from DoE caused hash/domain blow-ups).
    dt = 2e-5
    mu_s = float(config["mu_s"])
    density = float(config["density"])

    sys_mbs = chrono.ChSystemNSC()
    sys_sph = fsi.ChFsiFluidSystemSPH()
    sys_fsi = fsi.ChFsiSystemSPH(sys_mbs, sys_sph)
    sys_fsi.SetStepSizeCFD(dt)
    sys_fsi.SetStepsizeMBD(dt)

    mat_props = fsi.ElasticMaterialProperties()
    mat_props.density = density
    mat_props.Young_modulus = float(config.get("Young_modulus", 1e6))
    mat_props.Poisson_ratio = float(config.get("Poisson_ratio", 0.3))
    mat_props.rheology_model = fsi.RheologyCRM_MCC
    angle_mus = math.atan(mu_s)
    mat_props.mcc_M = (6.0 * math.sin(angle_mus)) / (3.0 - math.sin(angle_mus))
    lam = float(config.get("mcc_lambda", 0.1))
    mat_props.mcc_kappa = float(config.get("kappa_ratio", 0.1)) * lam
    mat_props.mcc_lambda = lam
    sys_sph.SetElasticSPH(mat_props)

    sph_params = fsi.SPHParameters()
    sph_params.initial_spacing = 0.001
    sph_params.d0_multiplier = 1.3
    sph_params.integration_scheme = fsi.IntegrationScheme_RK2
    sph_params.artificial_viscosity = 0.2
    sph_params.shifting_method = fsi.ShiftingMethod_PPST_XSPH
    sph_params.shifting_xsph_eps = 0.5
    sph_params.shifting_ppst_pull = 1.0
    sph_params.shifting_ppst_push = 3.0
    sph_params.free_surface_threshold = 2.0
    sph_params.num_proximity_search_steps = 1
    sph_params.kernel_type = fsi.KernelType_CUBIC_SPLINE
    sph_params.boundary_method = fsi.BoundaryMethod_ADAMI
    sph_params.viscosity_method = fsi.ViscosityMethod_ARTIFICIAL_BILATERAL
    sph_params.use_variable_time_step = True
    sys_sph.SetSPHParameters(sph_params)

    g = 9.81
    sys_sph.SetGravitationalAcceleration(chrono.ChVector3d(0, 0, -g))
    sys_mbs.SetGravitationalAcceleration(sys_sph.GetGravitationalAcceleration())
    sys_fsi.SetVerbose(False)

    spacing = sph_params.initial_spacing
    floor_width = 0.2
    floor_length = 0.2
    floor_thickness = 0.01
    pile_h = 0.04

    c_min = chrono.ChVector3d(
        -floor_width / 2 * 1.2, -floor_length / 2 * 1.2, -floor_thickness * 1.2
    )
    c_max = chrono.ChVector3d(
        floor_width / 2 * 1.2, floor_length / 2 * 1.2, (floor_thickness + pile_h) * 1.5
    )
    sys_sph.SetComputationalDomain(chrono.ChAABB(c_min, c_max), fsi.BC_NONE)

    floor_body = chrono.ChBody()
    floor_body.SetFixed(True)
    sys_mbs.AddBody(floor_body)
    floor_bce = sys_sph.CreatePointsBoxContainer(
        chrono.ChVector3d(floor_width, floor_length, floor_thickness),
        chrono.ChVector3i(0, 0, -1),
    )
    sys_fsi.AddFsiBody(
        floor_body, floor_bce,
        chrono.ChFramed(chrono.ChVector3d(0, 0, floor_thickness / 2), chrono.QUNIT),
        True,
    )

    sampler = chrono.ChGridSamplerd(spacing)
    center = chrono.ChVector3d(0, 0, floor_thickness + pile_h / 2)
    half = chrono.ChVector3d(0.015, 0.015, pile_h / 2 - spacing)
    points = sampler.SampleBox(center, half)
    rho_ini = sys_sph.GetDensity()
    gz = abs(sys_sph.GetGravitationalAcceleration().z)
    for p in points:
        pre_ini = rho_ini * gz * (floor_thickness + pile_h - p.z)
        sys_sph.AddSPHParticle(
            p, rho_ini, pre_ini, sys_sph.GetViscosity(),
            chrono.ChVector3d(0, 0, 0),
            chrono.ChVector3d(-pre_ini, -pre_ini, -pre_ini),
            chrono.ChVector3d(0, 0, 0),
            pre_ini * 2.0,
        )

    sys_fsi.Initialize()

    t0 = time.time()
    for _ in range(n_steps):
        sys_fsi.DoStepDynamics(dt)
    gpu_wall = time.time() - t0

    sim_time = sys_mbs.GetChTime()
    n_particles = float(len(points))

    return {
        "sim_time": sim_time,
        "n_particles": n_particles,
        "gpu_sph_steps": n_steps,
        "gpu_sph_wall_seconds": gpu_wall,
        "coupling_force_z": -gz * n_particles * rho_ini * 1e-9,
        "coupling_ke": 0.5 * n_particles * rho_ini * 1e-6,
    }


def main() -> int:
    comm = MPI.COMM_WORLD
    rank = comm.Get_rank()
    size = comm.Get_size()
    g_rank = gpu_rank(size)

    parser = argparse.ArgumentParser()
    parser.add_argument("--sim_tend", type=float, default=0.5)
    parser.add_argument("--heartbeat", type=float, default=0.02, help="cosim sync interval (s)")
    parser.add_argument("--dt", type=float, default=2e-5)
    parser.add_argument("--mu_s", type=float, default=0.6)
    parser.add_argument("--density", type=float, default=1600.0)
    parser.add_argument("--Young_modulus", type=float, default=1e6)
    parser.add_argument("--Poisson_ratio", type=float, default=0.3)
    parser.add_argument("--mcc_lambda", type=float, default=0.1)
    parser.add_argument("--kappa_ratio", type=float, default=0.1)
    args = parser.parse_args()

    if size < 2:
        if rank == 0:
            print("Need >= 2 MPI ranks (1 GPU SPH + >=1 CPU coupling rank)", file=sys.stderr)
        return 1

    print(f"gpu_mpi_fsi_coupled: rank {rank}/{size} pid={os.getpid()}", flush=True)

    out_dir = os.environ.get("CHR_RAY_TRIAL_OUTPUT", ".")
    os.makedirs(out_dir, exist_ok=True)

    config = vars(args)
    steps_per_heartbeat = max(1, int(args.heartbeat / 2e-5))
    n_heartbeats = max(1, int(math.ceil(args.sim_tend / args.heartbeat)))

    coupling = np.zeros(4, dtype=np.float64)  # [force_z, ke, sim_time, n_particles]
    agent_state = np.array([1.0 + 0.1 * rank], dtype=np.float64)

    sync_count = 0
    heartbeat_wall = 0.0
    mpi_bcast_wall = 0.0
    mpi_allreduce_wall = 0.0
    mpi_bcast_bytes = 0
    mpi_allreduce_bytes = 0
    gpu_sph_total_steps = 0
    gpu_sph_wall = 0.0

    t0 = time.time()

    for hb in range(n_heartbeats):
        t_hb = MPI.Wtime()

        if rank == g_rank:
            # Slurm gres/step binding takes precedence over manual device index.
            if "ROCR_VISIBLE_DEVICES" not in os.environ and "HIP_VISIBLE_DEVICES" not in os.environ:
                os.environ.setdefault("HIP_VISIBLE_DEVICES", "0")
                os.environ.setdefault("ROCR_VISIBLE_DEVICES", "0")
            print(f"gpu_mpi_fsi_coupled: GPU rank {rank} starting SPH ({steps_per_heartbeat} steps/hb)", flush=True)
            metrics = _run_gpu_sph(config, steps_per_heartbeat)
            coupling[0] = metrics["coupling_force_z"]
            coupling[1] = metrics["coupling_ke"]
            coupling[2] = metrics["sim_time"]
            coupling[3] = metrics["n_particles"]
            gpu_sph_total_steps += metrics["gpu_sph_steps"]
            gpu_sph_wall += metrics["gpu_sph_wall_seconds"]
        else:
            agent_state[0] += 0.01 * (rank + 1)

        # --- MPI cosim sync (timed separately from GPU SPH) ---
        t_bc0 = MPI.Wtime()
        comm.Bcast(coupling, root=g_rank)
        t_bc1 = MPI.Wtime()
        mpi_bcast_wall += t_bc1 - t_bc0
        # Root sends payload to (size-1) receivers
        mpi_bcast_bytes += coupling.nbytes * max(size - 1, 0)

        global_state = np.zeros(1, dtype=np.float64)
        global_state[0] = agent_state[0] if rank != g_rank else coupling[0]
        reduced = np.zeros(1, dtype=np.float64)
        t_ar0 = MPI.Wtime()
        comm.Allreduce(global_state, reduced, op=MPI.SUM)
        t_ar1 = MPI.Wtime()
        mpi_allreduce_wall += t_ar1 - t_ar0
        # Allreduce: each rank sends+receives ~1 scalar (8 bytes)
        mpi_allreduce_bytes += global_state.nbytes * 2 * max(size - 1, 0)

        if rank != g_rank:
            agent_state[0] = 0.5 * agent_state[0] + 0.5 * reduced[0] / size

        heartbeat_wall += MPI.Wtime() - t_hb
        sync_count += 1

    elapsed = time.time() - t0
    mpi_comm_wall = mpi_bcast_wall + mpi_allreduce_wall
    mpi_comm_bytes = mpi_bcast_bytes + mpi_allreduce_bytes

    # gather requires all ranks; must not call only on GPU rank.
    topo = _mpi_topology(comm, g_rank)

    if rank == g_rank:
        print("gpu_mpi_fsi_coupled: collecting GPU/MPI metrics", flush=True)
        gpu = _sample_gpu_metrics()
        interconnect = _sample_gpu_interconnect()
        summary = {
            "workload": "gpu_mpi_fsi_coupled",
            "mpi_ranks": size,
            "gpu_rank": g_rank,
            "cpu_coupling_ranks": size - 1,
            "gpus_per_trial": 1,
            "sim_tend": args.sim_tend,
            "heartbeat_sec": args.heartbeat,
            "sync_events": sync_count,
            # End-to-end heartbeat (includes GPU SPH on terrain rank)
            "heartbeat_wall_seconds": round(heartbeat_wall, 4),
            "avg_heartbeat_latency_ms": round(heartbeat_wall / sync_count * 1000, 3) if sync_count else 0,
            # Pure MPI communication (Bcast + Allreduce only)
            "mpi_bcast_wall_seconds": round(mpi_bcast_wall, 6),
            "mpi_allreduce_wall_seconds": round(mpi_allreduce_wall, 6),
            "mpi_comm_wall_seconds": round(mpi_comm_wall, 6),
            "avg_mpi_bcast_latency_us": round(mpi_bcast_wall / sync_count * 1e6, 2) if sync_count else 0,
            "avg_mpi_allreduce_latency_us": round(mpi_allreduce_wall / sync_count * 1e6, 2) if sync_count else 0,
            "mpi_bcast_bytes_total": int(mpi_bcast_bytes),
            "mpi_allreduce_bytes_total": int(mpi_allreduce_bytes),
            "mpi_comm_bytes_total": int(mpi_comm_bytes),
            "mpi_comm_bandwidth_mbps": round(mpi_comm_bytes / mpi_comm_wall / 1e6, 4) if mpi_comm_wall > 0 else 0,
            # Legacy fields (heartbeat includes GPU; use mpi_comm_* for network)
            "sync_wall_seconds": round(heartbeat_wall, 4),
            "avg_sync_latency_ms": round(heartbeat_wall / sync_count * 1000, 3) if sync_count else 0,
            "mpi_sync_bytes_total": int(mpi_comm_bytes),
            "mpi_sync_bandwidth_mbps": round(mpi_comm_bytes / mpi_comm_wall / 1e6, 4) if mpi_comm_wall > 0 else 0,
            "gpu_sph_steps": gpu_sph_total_steps,
            "gpu_sph_wall_seconds": round(gpu_sph_wall, 3),
            "gpu_sph_steps_per_sec": round(gpu_sph_total_steps / gpu_sph_wall, 1) if gpu_sph_wall else 0,
            "gpu_sph_fraction_of_heartbeat": round(gpu_sph_wall / heartbeat_wall, 4) if heartbeat_wall else 0,
            "elapsed_seconds": round(elapsed, 3),
            **gpu,
            **interconnect,
            **topo,
            "config": config,
        }
        path = os.path.join(out_dir, "gpu_coupled_summary.json")
        with open(path, "w") as f:
            json.dump(summary, f, indent=2)
        print(
            f"GPU-MPI PASS: {size} ranks, GPU steps={gpu_sph_total_steps}, "
            f"MPI comm={summary['mpi_comm_bandwidth_mbps']} MB/s "
            f"(bcast {summary['avg_mpi_bcast_latency_us']}us ar {summary['avg_mpi_allreduce_latency_us']}us), "
            f"nodes={summary.get('mpi_unique_nodes', '?')}, "
            f"GPU util={gpu.get('gpu_bw_util_pct', 0)}%",
            flush=True,
        )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
