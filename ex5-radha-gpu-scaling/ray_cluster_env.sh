#!/usr/bin/env bash
# Shared Ray + ROCm env for Radha ex5 (head and workers).

source "$(dirname "${BASH_SOURCE[0]}")/paths.env"

ray_cluster_env() {
    export PATH="${VENV}/bin:/opt/rocm/bin:${PATH:-}"
    export LD_LIBRARY_PATH="${CHRONO_HIP_PREFIX}/lib:${LD_LIBRARY_PATH:-}"
    export VIRTUAL_ENV="${VENV}"
    local _pyver
    _pyver="$("${VENV}/bin/python3" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || echo 3.12)"
    local _site="${VENV}/lib/python${_pyver}/site-packages"
    export PYTHONPATH="${EX5}:${CHRONO_RAY_ROOT}:${CHRONO_PYTHON_DIR}:${_site}:${PYTHONPATH:-}"

    export HSA_XNACK=0
    export HIP_LAUNCH_BLOCKING=0
    export GPU_MAX_HW_QUEUES=4
    export RAY_ACCEL_ENV_VAR_OVERRIDE_ON_ZERO=0
    export RAY_ENABLE_UV_RUN_RUNTIME_ENV=0
    export RAY_EXPERIMENTAL_NOSET_HIP_VISIBLE_DEVICES=1
    export RAY_EXPERIMENTAL_NOSET_ROCR_VISIBLE_DEVICES=1
    export RAY_DISABLE_IMPORT_WARNING=1

    if [[ -f /opt/rocm/rccl/env.sh ]]; then
        # shellcheck source=/dev/null
        source /opt/rocm/rccl/env.sh
    fi
}

cluster_ip() {
    local ip
    ip=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^10\.' | head -1)
    if [[ -n "${ip}" ]]; then
        echo "${ip}"
        return
    fi
    ip=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -Ev '^(127\.|169\.254\.)' | head -1)
    echo "${ip}"
}

ray_stop_node() {
    ray stop --force 2>/dev/null || true
}

ray_wait_for_gpus() {
    local RAY_ADDR="$1"
    local TARGET_GPUS="$2"
    local MAX_WAIT="${3:-180}"
    local OUT_FILE="${4:-}"
    local waited=0
    local found=0

    while [[ "${waited}" -lt "${MAX_WAIT}" ]]; do
        if RAY_ADDRESS="${RAY_ADDR}" ray status 2>/dev/null > /tmp/ray_status_$$.txt; then
            found=$(grep -oP '^\s+\d+\.\d+/\K[\d.]+(?=\s+GPU)' /tmp/ray_status_$$.txt | tail -1 || echo "0")
            found=${found%.*}
            if [[ -n "${found}" && "${found}" -ge "${TARGET_GPUS}" ]]; then
                [[ -n "${OUT_FILE}" ]] && cp /tmp/ray_status_$$.txt "${OUT_FILE}"
                rm -f /tmp/ray_status_$$.txt
                echo "${found}"
                return 0
            fi
            echo "  Ray GPUs: ${found:-0}/${TARGET_GPUS} (waited ${waited}s)" >&2
        fi
        sleep 10
        waited=$((waited + 10))
    done
    rm -f /tmp/ray_status_$$.txt
    echo "${found:-0}"
    return 1
}

collect_system_info() {
    local OUT="${1:-${RESULTS_ROOT}/${CHR_RAY_RESULTS_TAG}/system_info/job_${SLURM_JOB_ID:-local}.json}"
    mkdir -p "$(dirname "${OUT}")"
    "${VENV}/bin/python3" - <<'PY' "${OUT}"
import json, os, platform, subprocess, sys
from datetime import datetime, timezone

out = sys.argv[1]

def run(cmd):
    try:
        return subprocess.check_output(cmd, shell=True, text=True, stderr=subprocess.STDOUT, timeout=60)
    except Exception as e:
        return str(e)

info = {
    "timestamp_utc": datetime.now(timezone.utc).isoformat(),
    "hostname": platform.node(),
    "platform": os.environ.get("CHR_RAY_PLATFORM", ""),
    "scale_gpus": os.environ.get("CHR_RAY_SCALE", ""),
    "slurm": {
        "job_id": os.environ.get("SLURM_JOB_ID", ""),
        "partition": os.environ.get("SLURM_JOB_PARTITION", ""),
        "nodelist": os.environ.get("SLURM_JOB_NODELIST", ""),
        "nnodes": os.environ.get("SLURM_NNODES", ""),
    },
    "cpu": run("lscpu"),
    "memory": run("free -h"),
    "rocm_smi": run("rocm-smi --showproductname 2>/dev/null; rocm-smi --showmeminfo vram 2>/dev/null | head -40"),
    "hip_version": run("hipconfig --version 2>/dev/null || true"),
    "network": {
        "ip_addr": run("ip -4 addr"),
        "ibstat": run("ibstat 2>/dev/null | head -30 || true"),
        "ethtool": run("for i in $(ls /sys/class/net/ 2>/dev/null); do echo \"=== $i ===\"; ethtool $i 2>/dev/null | head -8; done"),
    },
    "ray_version": run(f"{os.environ.get('VENV','')}/bin/python3 -c \"import ray; print(ray.__version__)\" 2>/dev/null"),
    "python": run("python3 --version; which python3"),
}
with open(out, "w") as f:
    json.dump(info, f, indent=2)
print(out)
PY
}
