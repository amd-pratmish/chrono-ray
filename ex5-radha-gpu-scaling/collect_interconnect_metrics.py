#!/usr/bin/env python3
"""Collect GPU interconnect + network + Ray cluster placement metrics for ex5 scaling.

Mirrors the coupled MPI workload fields where applicable (see METRICS_SCHEMA.md).
"""

from __future__ import annotations

import json
import os
import re
import socket
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def _run(cmd: str, timeout: int = 60) -> str:
    try:
        return subprocess.check_output(
            cmd, shell=True, text=True, stderr=subprocess.STDOUT, timeout=timeout
        )
    except Exception as exc:
        return f"ERROR: {exc}"


def parse_rocm_topo(topo_text: str) -> dict[str, Any]:
    """Parse `rocm-smi --showtopo` for xGMI/PCIe link summary."""
    out: dict[str, Any] = {
        "gpu_link_type": "",
        "xgmi_link_count": 0,
        "gpu_link_speed_gts": "",
        "gpu_topo_summary": "",
        "gpu_topo_raw": topo_text[:8000],
    }
    if not topo_text or topo_text.startswith("ERROR"):
        return out

    lines = [ln.strip() for ln in topo_text.splitlines() if ln.strip()]
    out["gpu_topo_summary"] = " | ".join(lines[:12])

    link_types: set[str] = set()
    xgmi = 0
    speeds: list[str] = []
    for ln in lines:
        low = ln.lower()
        if "xgmi" in low:
            link_types.add("xgmi")
            xgmi += ln.lower().count("xgmi")
        if "pcie" in low or "pci" in low:
            link_types.add("pcie")
        m = re.search(r"(\d+(?:\.\d+)?)\s*GT/s", ln, re.I)
        if m:
            speeds.append(m.group(1))

    if "xgmi" in link_types:
        out["gpu_link_type"] = "xgmi"
    elif "pcie" in link_types:
        out["gpu_link_type"] = "pcie"
    out["xgmi_link_count"] = xgmi
    if speeds:
        out["gpu_link_speed_gts"] = ",".join(sorted(set(speeds)))

    return out


def sample_gpu_util() -> dict[str, str]:
    """Best-effort GPU memory and bandwidth utilization from rocm-smi."""
    text = _run(
        "rocm-smi --showuse --showmeminfo vram --showbw 2>/dev/null | head -80",
        timeout=30,
    )
    mem_pct = ""
    bw_pct = ""
    for ln in text.splitlines():
        if "GPU use" in ln or "GPU%" in ln:
            m = re.search(r"(\d+)\s*%", ln)
            if m and not mem_pct:
                mem_pct = m.group(1)
        if "Memory" in ln and "%" in ln:
            m = re.search(r"(\d+)\s*%", ln)
            if m:
                mem_pct = m.group(1)
        if "bw" in ln.lower() or "bandwidth" in ln.lower():
            m = re.search(r"(\d+)\s*%", ln)
            if m:
                bw_pct = m.group(1)
    return {"gpu_mem_util_pct": mem_pct, "gpu_bw_util_pct": bw_pct}


def parse_network() -> dict[str, Any]:
    ip_text = _run("ip -4 -o addr show 2>/dev/null")
    ib_text = _run("ibstat 2>/dev/null | head -40")
    ethtool = _run(
        "for i in $(ls /sys/class/net/ 2>/dev/null | grep -v lo); do "
        "echo \"=== $i ===\"; ethtool $i 2>/dev/null | head -6; done",
        timeout=30,
    )
    nics = []
    for ln in ip_text.splitlines():
        parts = ln.split()
        if len(parts) >= 4 and parts[2] == "inet":
            nics.append({"iface": parts[1], "addr": parts[3].split("/")[0]})
    return {
        "hostname": socket.gethostname(),
        "nics": nics,
        "ibstat_excerpt": ib_text[:2000],
        "ethtool_excerpt": ethtool[:4000],
        "nccl_socket_ifname": os.environ.get("NCCL_SOCKET_IFNAME", ""),
        "gloo_socket_ifname": os.environ.get("GLOO_SOCKET_IFNAME", ""),
    }


def ray_cluster_placement() -> dict[str, Any]:
    """Ray analogue of MPI rank/node placement (1 GPU actor per trial)."""
    placement: dict[str, Any] = {
        "ray_unique_nodes": 0,
        "ray_head_node": "",
        "ray_worker_nodes": [],
        "ray_node_gpu_counts": {},
        "ray_cross_node_traffic": False,
        "ray_address": os.environ.get("RAY_ADDRESS", ""),
    }
    slurm_nodes = os.environ.get("SLURM_JOB_NODELIST", "")
    placement["slurm_unique_nodes"] = len(_expand_nodelist(slurm_nodes))
    placement["slurm_nodelist"] = slurm_nodes
    placement["mpi_unique_nodes"] = placement["slurm_unique_nodes"]  # alias for CSV join
    placement["mpi_gpu_node"] = _expand_nodelist(slurm_nodes)[0] if slurm_nodes else socket.gethostname()
    placement["mpi_cross_node_traffic"] = placement["slurm_unique_nodes"] > 1

    try:
        import ray

        if not ray.is_initialized():
            addr = os.environ.get("RAY_ADDRESS")
            if addr:
                ray.init(address=addr, ignore_reinit_error=True)
            else:
                return placement

        nodes = ray.nodes()
        alive = [n for n in nodes if n.get("Alive")]
        node_ids = []
        gpu_counts: dict[str, float] = {}
        for n in alive:
            host = n.get("NodeManagerAddress") or n.get("node_id", "")
            node_ids.append(host)
            res = n.get("Resources") or {}
            gpu_counts[host] = float(res.get("GPU", 0) or 0)
        placement["ray_unique_nodes"] = len(set(node_ids))
        placement["ray_node_gpu_counts"] = gpu_counts
        placement["ray_worker_nodes"] = sorted(set(node_ids))
        if placement["ray_worker_nodes"]:
            placement["ray_head_node"] = placement["ray_worker_nodes"][0]
        placement["ray_cross_node_traffic"] = placement["ray_unique_nodes"] > 1
    except Exception as exc:
        placement["ray_error"] = str(exc)

    return placement


def _expand_nodelist(nodelist: str) -> list[str]:
    if not nodelist:
        return []
    try:
        out = subprocess.check_output(
            ["scontrol", "show", "hostnames", nodelist],
            text=True,
            timeout=15,
        )
        return [ln.strip() for ln in out.splitlines() if ln.strip()]
    except Exception:
        return [nodelist]


def collect_all(out_path: Path | None = None) -> dict[str, Any]:
    topo = _run("rocm-smi --showtopo 2>/dev/null")
    interconnect = parse_rocm_topo(topo)
    interconnect.update(sample_gpu_util())
    interconnect.update(parse_network())
    interconnect.update(ray_cluster_placement())
    interconnect["timestamp_utc"] = datetime.now(timezone.utc).isoformat()
    interconnect["platform"] = os.environ.get("CHR_RAY_PLATFORM", "")
    interconnect["scale_tier"] = os.environ.get("CHR_RAY_SCALE", "")
    interconnect["slurm_job_id"] = os.environ.get("SLURM_JOB_ID", "")
    interconnect["partition"] = os.environ.get("SLURM_JOB_PARTITION", "")

    if out_path:
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(interconnect, indent=2))
    return interconnect


def flatten_for_summary(data: dict[str, Any]) -> dict[str, str]:
    """Key=value lines for scale_summary.txt (coupled-workload compatible names)."""
    flat = {
        "gpu_link_type": str(data.get("gpu_link_type", "")),
        "xgmi_link_count": str(data.get("xgmi_link_count", "")),
        "gpu_link_speed_gts": str(data.get("gpu_link_speed_gts", "")),
        "gpu_topo_summary": str(data.get("gpu_topo_summary", ""))[:500],
        "gpu_mem_util_pct": str(data.get("gpu_mem_util_pct", "")),
        "gpu_bw_util_pct": str(data.get("gpu_bw_util_pct", "")),
        "mpi_unique_nodes": str(data.get("mpi_unique_nodes", data.get("slurm_unique_nodes", ""))),
        "mpi_gpu_node": str(data.get("mpi_gpu_node", "")),
        "mpi_cross_node_traffic": str(data.get("mpi_cross_node_traffic", "")),
        "ray_unique_nodes": str(data.get("ray_unique_nodes", "")),
        "ray_cross_node_traffic": str(data.get("ray_cross_node_traffic", "")),
        "slurm_nodelist": str(data.get("slurm_nodelist", "")),
    }
    return flat


def main() -> int:
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("interconnect_metrics.json")
    data = collect_all(out)
    print(json.dumps(flatten_for_summary(data), indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
