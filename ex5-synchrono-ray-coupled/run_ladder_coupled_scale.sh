#!/usr/bin/env bash
# SynChrono/MPI coupled scaling ladder with auto-heal; optional ex4 resume on same cluster.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cluster_profiles/load_cluster.sh
source "${SCRIPT_DIR}/cluster_profiles/load_cluster.sh"

EX5="${CHR_EX5_DIR}"
EX4="${CHR_EX4_DIR}"
VENV="${CHR_VENV}"
MAX_ATTEMPTS=4
LOG="${EX5}/logs/ladder_coupled_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "${LOG}") 2>&1

source "${EX5}/scale_profiles_coupled.sh"
coupled_ladder_for_cluster
LADDER_TIERS=("${COUPLED_LADDER_ACTIVE[@]}")
if [[ -n "${CHR_LADDER_TIERS:-}" ]]; then
  # shellcheck disable=SC2206
  LADDER_TIERS=(${CHR_LADDER_TIERS})
fi

source "${EX4}/slurm_wait.sh"

heal_environment() {
  echo "=== Auto-heal: GPU+MPI coupled deps $(date) cluster=${CHR_CLUSTER_NAME} ==="
  source "${VENV}/bin/activate" || true
  export CHR_RAY_MODE="${CHR_RAY_MODE:-gpu_fsi_mpi}"
  export PYCHRONO_BIN="${CHR_PYCHRONO_BIN}"
  export PYTHONPATH="${PYCHRONO_BIN}:${PYTHONPATH:-}"

  if ! python3 -c "import mpi4py" 2>/dev/null; then
    echo "Installing mpi4py..."
    pip install -q mpi4py numpy
  fi
  if ! python3 -c "import pychrono.fsi" 2>/dev/null; then
    if [[ -f "${CHR_PYCHRONO_BIN}/pychrono/_fsi.so" ]] || [[ -f "${CHR_PYCHRONO_READY}" ]]; then
      echo "PyChrono FSI built (import only on GPU compute nodes)"
    else
      echo "ERROR: PyChrono FSI not built — run setup_pychrono_amd.sh on GPU node"
      return 1
    fi
  else
    echo "PyChrono FSI import OK"
  fi
  echo "Mode: ${CHR_RAY_MODE} (PyChrono FSI + MPI on GPU rank)"
  return 0
}

_summary_passes() {
  local SUMMARY="$1"
  [[ -f "${SUMMARY}" ]] || return 1
  local EC COMP REQ
  EC=$(grep ^exit_code= "${SUMMARY}" | cut -d= -f2)
  COMP=$(grep ^trials_completed= "${SUMMARY}" | cut -d= -f2)
  REQ=$(grep ^trials_requested= "${SUMMARY}" | cut -d= -f2)
  [[ "${EC}" == "0" && "${COMP}" -ge "${REQ}" ]] || return 1
  if [[ "${CHR_REQUIRE_NEW_METRICS:-1}" == "1" ]]; then
    grep -q ^avg_mpi_bcast_latency_us= "${SUMMARY}" || return 1
  fi
  return 0
}

tier_passed() {
  local SCALE="$1"
  local SUMMARY
  for SUMMARY in "${EX5}"/results/coupled${SCALE}rank_*/scale_summary.txt; do
    _summary_passes "${SUMMARY}" && return 0
  done
  return 1
}

check_pass() {
  local JOB="$1" SCALE="$2"
  local RUN="${EX5}/results/coupled${SCALE}rank_${JOB}"
  local SUMMARY="${RUN}/scale_summary.txt"
  [[ -f "${SUMMARY}" ]] || return 1
  cat "${SUMMARY}"
  _summary_passes "${SUMMARY}"
}

wait_for_coupled_slot() {
  local SCALE="$1"
  local TAG=""
  [[ "${CHR_RAY_MULTI_GPU_CONCURRENT:-0}" == "1" ]] && TAG="mg"
  local JOB_PREFIX="chr-coupled-${TAG}${SCALE}r"
  while squeue -u "${USER}" -h -o "%j" 2>/dev/null | grep -q "^${JOB_PREFIX}$"; do
    sleep 30
  done
}

_slurm_time_to_sec() {
  local t="$1" h m s
  IFS=: read -r h m s <<< "${t}"
  s="${s:-0}"
  echo $((10#${h} * 3600 + 10#${m} * 60 + 10#${s}))
}

tier_job_budget_sec() {
  local SCALE="$1"
  source "${EX5}/scale_profiles_coupled.sh"
  apply_coupled_scale_profile "${SCALE}" >/dev/null
  local wall
  wall=$(_slurm_time_to_sec "${CHR_RAY_TIME}")
  # Cancel 10 min before Slurm TIMEOUT so jobs can flush logs/summary.
  echo $((wall - 600))
}

run_tier() {
  local SCALE="$1"
  if [[ "${CHR_FORCE_RERUN:-0}" != "1" ]] && tier_passed "${SCALE}"; then
    echo "SKIP tier ${SCALE} (passed with current metrics)"
    return 0
  fi

  local attempt=0
  while [[ "${attempt}" -lt "${MAX_ATTEMPTS}" ]]; do
    attempt=$((attempt + 1))
    echo ""
    echo "=== Coupled tier ${SCALE} attempt ${attempt}/${MAX_ATTEMPTS} $(date) ==="
    heal_environment

    wait_for_coupled_slot "${SCALE}"

    local JOB=""
    if squeue -u "${USER}" -h -o "%j" 2>/dev/null | grep -q "chr-coupled-${SCALE}r"; then
      JOB=$(squeue -u "${USER}" -h -o "%i %j" | awk -v s="chr-coupled-${SCALE}r" '$2 ~ s {print $1; exit}')
      echo "Waiting on job ${JOB}..."
    else
      local SUBLOG="${EX5}/logs/submit_coupled_${SCALE}_a${attempt}.log"
      if ! bash "${EX5}/submit_coupled_scale.sh" "${SCALE}" | tee "${SUBLOG}"; then
        echo "Submit failed — see ${SUBLOG}"
        sleep 90
        continue
      fi
      JOB=$(grep -oP 'Submitted coupled tier \d+ \(MPI ranks=\d+\): job \K\d+' "${SUBLOG}" || true)
      [[ -n "${JOB}" ]] || JOB=$(awk '/Submitted batch job/{print $NF}' "${SUBLOG}")
      [[ -n "${JOB}" ]] || { sleep 90; continue; }
    fi

    local BUDGET
    BUDGET="$(tier_job_budget_sec "${SCALE}")"
    wait_for_slurm_job "${JOB}" 600 30 "${BUDGET}"

    if check_pass "${JOB}" "${SCALE}"; then
      python3 "${EX5}/measure_coupled_performance.py" || true
      return 0
    fi

    echo "Tier ${SCALE} failed — tail log:"
    tail -50 "${EX5}/logs/coupled_scale_chr-coupled-${SCALE}r_${JOB}.out" 2>/dev/null || \
      tail -50 "${EX5}/logs/coupled_scale_chr-coupled-scale_${JOB}.out" 2>/dev/null || true
    heal_environment
    sleep 90
  done
  return 1
}

resume_ex4_96() {
  [[ "${CHR_RESUME_EX4_AFTER_LADDER:-0}" == "1" ]] || {
    echo "Skipping ex4 resume (CHR_RESUME_EX4_AFTER_LADDER=0)"
    return 0
  }
  echo ""
  echo "=== Resuming ex4 FSI 96-GPU tier $(date) ==="
  if compgen -G "${EX4}/results/scale96gpu_"*/scale_summary.txt >/dev/null; then
    echo "96 GPU already passed — skip"
    return 0
  fi
  bash "${EX4}/submit_scale.sh" 96 | tee "${EX4}/logs/submit_96_after_coupled.log" || true
  nohup bash "${EX4}/run_ladder_64_96.sh" >> "${EX4}/logs/ladder_64_96_resume.log" 2>&1 &
  echo "ex4 96+ ladder resumed PID=$!"
}

echo "=== Coupled SynChrono scaling ladder $(date) ==="
echo "Cluster: ${CHR_CLUSTER_NAME} (CHR_CLUSTER=${CHR_CLUSTER})"
echo "Tiers: ${LADDER_TIERS[*]} (max_tier=${CHR_COUPLED_MAX_TIER:-128})"
echo "Require new metrics: ${CHR_REQUIRE_NEW_METRICS:-1}"
echo "Log: ${LOG}"

# Pause competing ex4 jobs (only when resuming ex4 on this cluster)
if [[ "${CHR_RESUME_EX4_AFTER_LADDER:-0}" == "1" ]]; then
  scancel -u "${USER}" --name=chr-doe-96gpu 2>/dev/null || true
  pkill -f run_ladder_64_96.sh 2>/dev/null || true
  sleep 2
fi

heal_environment

FAILED=0
for SCALE in "${LADDER_TIERS[@]}"; do
  if ! run_tier "${SCALE}"; then
    FAILED=$((FAILED + 1))
    echo "Continuing after failure on tier ${SCALE}..."
  fi
done

python3 "${EX5}/measure_coupled_performance.py" || true
echo "=== Coupled ladder done — ${FAILED} failed $(date) ==="

resume_ex4_96
