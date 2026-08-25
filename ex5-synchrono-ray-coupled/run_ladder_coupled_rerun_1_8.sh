#!/usr/bin/env bash
# Re-run coupled tiers 1–8 with updated MPI/GPU metrics (ignores prior PASS).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cluster_profiles/load_cluster.sh
source "${SCRIPT_DIR}/cluster_profiles/load_cluster.sh"

EX5="${CHR_EX5_DIR}"
VENV="${CHR_VENV}"
MAX_ATTEMPTS=4
RERUN_TIERS=(1 2 4 8)
LOG="${EX5}/logs/ladder_coupled_rerun_1_8_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "${LOG}") 2>&1

source "${EX5}/scale_profiles_coupled.sh"
source "${CHR_EX4_DIR}/slurm_wait.sh"

heal_environment() {
  echo "=== Auto-heal (metrics rerun 1-8) $(date) cluster=${CHR_CLUSTER_NAME} ==="
  source "${VENV}/bin/activate" || true
  export CHR_RAY_MODE="${CHR_RAY_MODE:-gpu_fsi_mpi}"
  export PYCHRONO_BIN="${CHR_PYCHRONO_BIN}"
  export PYTHONPATH="${PYCHRONO_BIN}:${PYTHONPATH:-}"
  if ! python3 -c "import mpi4py" 2>/dev/null; then
    pip install -q mpi4py numpy
  fi
  if ! python3 -c "import pychrono.fsi" 2>/dev/null; then
    echo "PyChrono FSI built (import only on GPU compute nodes)"
  else
    echo "PyChrono FSI import OK"
  fi
  return 0
}

check_pass() {
  local JOB="$1" SCALE="$2"
  local RUN="${EX5}/results/coupled${SCALE}rank_${JOB}"
  local SUMMARY="${RUN}/scale_summary.txt"
  [[ -f "${SUMMARY}" ]] || return 1
  cat "${SUMMARY}"
  local EC COMP REQ METRIC_OK
  EC=$(grep ^exit_code= "${SUMMARY}" | cut -d= -f2)
  COMP=$(grep ^trials_completed= "${SUMMARY}" | cut -d= -f2)
  REQ=$(grep ^trials_requested= "${SUMMARY}" | cut -d= -f2)
  METRIC_OK=$(grep -c ^avg_mpi_bcast_latency_us= "${SUMMARY}" || true)
  [[ "${EC}" == "0" && "${COMP}" -ge "${REQ}" && "${METRIC_OK}" -ge 1 ]]
}

run_tier() {
  local SCALE="$1"
  local attempt=0
  while [[ "${attempt}" -lt "${MAX_ATTEMPTS}" ]]; do
    attempt=$((attempt + 1))
    echo ""
    echo "=== Metrics rerun tier ${SCALE} attempt ${attempt}/${MAX_ATTEMPTS} $(date) ==="
    heal_environment

    local JOB=""
    if squeue -u "${USER}" -h -o "%j" 2>/dev/null | grep -q "chr-coupled-${SCALE}r"; then
      JOB=$(squeue -u "${USER}" -h -o "%i %j" | awk -v s="chr-coupled-${SCALE}r" '$2 ~ s {print $1; exit}')
      echo "Waiting on existing job ${JOB}..."
    else
      local SUBLOG="${EX5}/logs/submit_coupled_rerun_${SCALE}_a${attempt}.log"
      if ! bash "${EX5}/submit_coupled_scale.sh" "${SCALE}" | tee "${SUBLOG}"; then
        echo "Submit failed — see ${SUBLOG}"
        sleep 60
        continue
      fi
      JOB=$(grep -oP 'Submitted coupled tier \d+ \(MPI ranks=\d+\): job \K\d+' "${SUBLOG}" || true)
      [[ -n "${JOB}" ]] || JOB=$(awk '/Submitted batch job/{print $NF}' "${SUBLOG}")
      [[ -n "${JOB}" ]] || { sleep 60; continue; }
    fi

    wait_for_slurm_job "${JOB}" 600 30

    if check_pass "${JOB}" "${SCALE}"; then
      python3 "${EX5}/measure_coupled_performance.py" || true
      return 0
    fi

    echo "Tier ${SCALE} job ${JOB} failed metrics check — tail log:"
    tail -50 "${EX5}/logs/coupled_scale_chr-coupled-${SCALE}r_${JOB}.out" 2>/dev/null || \
      tail -50 "${EX5}/logs/coupled_scale_chr-coupled-scale_${JOB}.out" 2>/dev/null || true
    sleep 60
  done
  return 1
}

echo "=== Coupled metrics rerun tiers 1-8 $(date) ==="
echo "Cluster: ${CHR_CLUSTER_NAME}  Tiers: ${RERUN_TIERS[*]}"
echo "Log: ${LOG}"
heal_environment

FAILED=0
for SCALE in "${RERUN_TIERS[@]}"; do
  if ! run_tier "${SCALE}"; then
    FAILED=$((FAILED + 1))
    echo "Continuing after failure on tier ${SCALE}..."
  fi
done

python3 "${EX5}/measure_coupled_performance.py" || true
echo "=== Metrics rerun 1-8 done — ${FAILED} failed $(date) ==="
exit "${FAILED}"
