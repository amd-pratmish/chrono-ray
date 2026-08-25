#!/usr/bin/env bash
# Launch independent per-tier workers (parallel, retry-until-pass each).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cluster_profiles/load_cluster.sh
source "${SCRIPT_DIR}/cluster_profiles/load_cluster.sh"

EX5="${CHR_EX5_DIR}"
mkdir -p "${EX5}/logs"

export CHR_RESUME_EX4_AFTER_LADDER=0
export CHR_GPU_MPI_RANK=0
export CHR_RAY_MODE=gpu_fsi_mpi

source "${EX5}/scale_profiles_coupled.sh"
coupled_ladder_for_cluster

# Width tiers + one multi-GPU throughput tier (8 GPUs, independent job name).
WORKERS=()
WORKERS+=("8:multigpu")
for T in "${COUPLED_LADDER_ACTIVE[@]}"; do
  [[ "${T}" -le "${CHR_COUPLED_MAX_TIER:-96}" ]] || continue
  WORKERS+=("${T}:width")
done

LOG="${EX5}/logs/independent_ladder_$(date +%Y%m%d_%H%M%S).log"
echo "=== Independent coupled ladder $(date) ===" | tee -a "${LOG}"
echo "Cluster: ${CHR_CLUSTER_NAME}" | tee -a "${LOG}"
echo "Workers: ${#WORKERS[@]}" | tee -a "${LOG}"

start_worker() {
  local SPEC="$1"
  local SCALE="${SPEC%%:*}"
  local MODE="${SPEC##*:}"
  local PIDFILE="${EX5}/logs/tier_worker_${MODE}${SCALE}.pid"

  if [[ -f "${PIDFILE}" ]]; then
    local OLD
    OLD=$(cat "${PIDFILE}")
    if kill -0 "${OLD}" 2>/dev/null; then
      echo "Skip ${MODE} tier ${SCALE}: worker PID ${OLD} already running" | tee -a "${LOG}"
      return 0
    fi
  fi

  nohup bash "${EX5}/coupled_tier_worker.sh" "${SCALE}" "${MODE}" \
    >> "${EX5}/logs/tier_worker_${MODE}${SCALE}_nohup.out" 2>&1 &
  echo $! > "${PIDFILE}"
  echo "Started ${MODE} tier ${SCALE} worker PID=$(cat "${PIDFILE}")" | tee -a "${LOG}"
}

for SPEC in "${WORKERS[@]}"; do
  start_worker "${SPEC}"
  sleep 2
done

echo "" | tee -a "${LOG}"
echo "All tier workers launched. Monitor:" | tee -a "${LOG}"
echo "  tail -f ${EX5}/logs/tier_worker_*_nohup.out" | tee -a "${LOG}"
echo "  squeue -u \$USER" | tee -a "${LOG}"
echo "Log: ${LOG}" | tee -a "${LOG}"
