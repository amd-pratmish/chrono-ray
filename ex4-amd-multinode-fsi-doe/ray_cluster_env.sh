#!/usr/bin/env bash
# Shared environment for Ray head/worker processes on Slurm compute nodes.
ray_cluster_env() {
  local EX4="/home/pratmish/chrono-ray/ex4-amd-multinode-fsi-doe"
  local VENV="/home/pratmish/chrono-ray/.venv"
  local BUILD="/home/pratmish/amd-chronos/build-mi355x"
  local PY_BIN="${BUILD}/bin"

  export PATH="${VENV}/bin:/usr/local/bin:/usr/bin:/bin:/opt/rocm/bin:${PATH:-}"
  export LD_LIBRARY_PATH="${PY_BIN}:${LD_LIBRARY_PATH:-}"
  export VIRTUAL_ENV="${VENV}"
  SITE_PACKAGES="${VENV}/lib/python3.12/site-packages"
  export PYTHONPATH="${EX4}:/home/pratmish/chrono-ray:${PY_BIN}:${SITE_PACKAGES}:${PYTHONPATH:-}"
  export HSA_XNACK=0
  export HIP_LAUNCH_BLOCKING=0
  export GPU_MAX_HW_QUEUES=4
  export RAY_ACCEL_ENV_VAR_OVERRIDE_ON_ZERO=0
  # Avoid Ray Client server (ray_client_server) — not needed for batch DoE driver.
  export RAY_ENABLE_UV_RUN_RUNTIME_ENV=0
}

cluster_ip() {
  # Prefer cluster-internal 10.x addresses (rad/lux private network).
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
  local waited=0
  local found=0

  while [[ "${waited}" -lt "${MAX_WAIT}" ]]; do
    if RAY_ADDRESS="${RAY_ADDR}" ray status 2>/dev/null > /tmp/ray_status_$$.txt; then
      found=$(grep -oP '^\s+\d+\.\d+/\K[\d.]+(?=\s+GPU)' /tmp/ray_status_$$.txt | tail -1 || echo "0")
      found=${found%.*}
      if [[ -n "${found}" && "${found}" -ge "${TARGET_GPUS}" ]]; then
        if [[ -n "${4:-}" ]]; then
          cp /tmp/ray_status_$$.txt "${4}"
        fi
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
