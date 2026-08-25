#!/usr/bin/env bash
# Independent worker: one scale tier retries until PASS (no global slot lock).
# Usage: coupled_tier_worker.sh SCALE [width|multigpu]
set -uo pipefail

SCALE="${1:?Usage: coupled_tier_worker.sh SCALE [width|multigpu]}"
MODE="${2:-width}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cluster_profiles/load_cluster.sh
source "${SCRIPT_DIR}/cluster_profiles/load_cluster.sh"
# shellcheck source=coupled_tier_heal.sh
source "${SCRIPT_DIR}/coupled_tier_heal.sh"

EX5="${CHR_EX5_DIR}"
VENV="${CHR_VENV}"
TAG=""
JOB_PREFIX="chr-coupled-${SCALE}r"
RESULT_PREFIX="coupled${SCALE}rank"

if [[ "${MODE}" == "multigpu" ]]; then
  TAG="mg"
  JOB_PREFIX="chr-coupled-mg${SCALE}r"
  RESULT_PREFIX="coupledmg${SCALE}rank"
  export CHR_RAY_MULTI_GPU_CONCURRENT=1
else
  export CHR_RAY_MULTI_GPU_CONCURRENT=0
fi

export CHR_GPU_MPI_RANK=0
export CHR_RAY_MODE=gpu_fsi_mpi
export CHR_RESUME_EX4_AFTER_LADDER=0

LOG="${EX5}/logs/tier_worker_${TAG}${SCALE}_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "${LOG}") 2>&1

echo "=== Tier worker ${TAG}${SCALE} mode=${MODE} PID=$$ $(date) ==="
echo "Log: ${LOG}"

source "${CHR_EX4_DIR}/slurm_wait.sh"

tier_passed() {
  local SUMMARY
  local RESULTS="${EX5}/results"
  for SUMMARY in \
    "${RESULTS}/${RESULT_PREFIX}"_*/scale_summary.txt \
    "${RESULTS}/coupled${SCALE}rank_"*/scale_summary.txt; do
    [[ -f "${SUMMARY}" ]] || continue
    if [[ "${MODE}" == "multigpu" ]]; then
      MC=$(grep ^max_concurrent= "${SUMMARY}" 2>/dev/null | cut -d= -f2)
      [[ -n "${MC}" && "${MC}" -gt 1 ]] || continue
    fi
    local EC COMP REQ
    EC=$(grep ^exit_code= "${SUMMARY}" | cut -d= -f2)
    COMP=$(grep ^trials_completed= "${SUMMARY}" | cut -d= -f2)
    REQ=$(grep ^trials_requested= "${SUMMARY}" | cut -d= -f2)
    [[ "${EC}" == "0" && "${COMP}" -ge "${REQ}" && "${REQ}" -gt 0 ]] && return 0
  done
  return 1
}

tier_job_id() {
  squeue -u "${USER}" -h -o "%i %j" 2>/dev/null | awk -v p="${JOB_PREFIX}" '$2 == p {print $1; exit}'
}

job_budget_sec() {
  source "${EX5}/scale_profiles_coupled.sh"
  apply_coupled_scale_profile "${SCALE}" >/dev/null 2>&1 || true
  local t="${CHR_RAY_TIME:-02:00:00}"
  local h m s
  IFS=: read -r h m s <<< "${t}"
  s="${s:-0}"
  echo $((10#${h} * 3600 + 10#${m} * 60 + 10#${s} - 600))
}

heal_deps() {
  source "${VENV}/bin/activate" 2>/dev/null || true
  if ! python3 -c "import mpi4py" 2>/dev/null; then
    pip install -q mpi4py numpy
  fi
}

attempt=0
while true; do
  if [[ "${CHR_FORCE_RERUN:-0}" != "1" ]] && tier_passed; then
    echo "PASS tier ${TAG}${SCALE} — already succeeded"
    python3 "${EX5}/measure_coupled_performance.py" 2>/dev/null || true
    exit 0
  fi

  JOB=$(tier_job_id)
  if [[ -n "${JOB}" ]]; then
    echo "Tier ${TAG}${SCALE}: waiting on existing job ${JOB}..."
    wait_for_slurm_job "${JOB}" 600 30 "$(job_budget_sec)" || true
  else
    attempt=$((attempt + 1))
    echo ""
    echo "=== Tier ${TAG}${SCALE} submit attempt ${attempt} $(date) ==="
    heal_deps
    coupled_tier_heal "${SCALE}" "${MODE}" "${CHR_LAST_FAILED_JOB:-}"

    SUBLOG="${EX5}/logs/submit_${TAG}${SCALE}_a${attempt}.log"
    export CHR_COUPLED_JOB_TAG="${TAG}"
    if bash "${EX5}/submit_coupled_scale.sh" "${SCALE}" > "${SUBLOG}" 2>&1; then
      :
    fi
    JOB=$(awk '/Submitted batch job/{print $NF; exit} /Submitted coupled tier.*job/{print $NF; exit}' "${SUBLOG}")
    [[ -z "${JOB}" ]] && JOB=$(grep -oP 'Submitted coupled tier \d+ \(MPI ranks=\d+\): job \K\d+' "${SUBLOG}" | tail -1)

    if [[ -z "${JOB}" ]]; then
      echo "Submit failed — log:"
      cat "${SUBLOG}" || true
      coupled_tier_heal "${SCALE}" "${MODE}" ""
      sleep 90
      continue
    fi

    echo "Submitted tier ${TAG}${SCALE} job ${JOB}"
    wait_for_slurm_job "${JOB}" 600 30 "$(job_budget_sec)" || true
  fi

  SUMMARY="${EX5}/${RESULT_PREFIX}_${JOB}/scale_summary.txt"
  if [[ -f "${SUMMARY}" ]]; then
    EC=$(grep ^exit_code= "${SUMMARY}" | cut -d= -f2)
    COMP=$(grep ^trials_completed= "${SUMMARY}" | cut -d= -f2)
    REQ=$(grep ^trials_requested= "${SUMMARY}" | cut -d= -f2)
    if [[ "${EC}" == "0" && "${COMP}" -ge "${REQ}" ]]; then
      echo "PASS tier ${TAG}${SCALE} job ${JOB} (${COMP}/${REQ} trials)"
      python3 "${EX5}/measure_coupled_performance.py" 2>/dev/null || true
      exit 0
    fi
  fi

  echo "FAIL tier ${TAG}${SCALE} job ${JOB} — will heal and retry"
  CHR_LAST_FAILED_JOB="${JOB}"
  export CHR_LAST_FAILED_JOB
  coupled_tier_heal "${SCALE}" "${MODE}" "${JOB}"
  tail -30 "${EX5}/logs/coupled_scale_${JOB_PREFIX}_${JOB}.out" 2>/dev/null || true
  sleep 60
done
