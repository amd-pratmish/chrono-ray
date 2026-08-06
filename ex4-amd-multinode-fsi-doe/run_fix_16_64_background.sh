#!/usr/bin/env bash
# Background fix-and-scale loop: retry tier 16 until success, then tier 64.
set -uo pipefail

EX4="/home/pratmish/chrono-ray/ex4-amd-multinode-fsi-doe"
LOG="${EX4}/logs/fix_16_64_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "${LOG}") 2>&1

wait_job() {
  local JOB="$1" SCALE="$2"
  echo "Waiting for job ${JOB} (tier ${SCALE})..."
  while squeue -j "${JOB}" -h 2>/dev/null | grep -q "${JOB}"; do
    sleep 45
  done
  sleep 5
}

check_pass() {
  local JOB="$1" SCALE="$2"
  local SUMMARY="${EX4}/results/scale${SCALE}gpu_${JOB}/scale_summary.txt"
  if [[ ! -f "${SUMMARY}" ]]; then
    echo "FAIL tier ${SCALE} job ${JOB}: no scale_summary.txt"
    return 1
  fi
  cat "${SUMMARY}"
  local COMPLETED EXIT_CODE REQUESTED
  COMPLETED=$(grep trials_completed_dirs "${SUMMARY}" | cut -d= -f2)
  EXIT_CODE=$(grep exit_code "${SUMMARY}" | cut -d= -f2)
  REQUESTED=$(grep trials_requested "${SUMMARY}" | cut -d= -f2)
  [[ "${EXIT_CODE}" == "0" && "${COMPLETED}" -ge "${REQUESTED}" ]]
}

run_tier_with_retries() {
  local SCALE="$1"
  local MAX_ATTEMPTS="${2:-8}"
  local attempt=0

  while [[ "${attempt}" -lt "${MAX_ATTEMPTS}" ]]; do
    attempt=$((attempt + 1))
    echo ""
    echo "=== Tier ${SCALE} attempt ${attempt}/${MAX_ATTEMPTS} $(date) ==="
    JOB=$(bash "${EX4}/submit_scale.sh" "${SCALE}" | awk '/Submitted/{print $NF}')
    echo "Submitted job ${JOB}"
    wait_job "${JOB}" "${SCALE}"

    if check_pass "${JOB}" "${SCALE}"; then
      echo "PASS tier ${SCALE} job ${JOB}"
      return 0
    fi

    echo "Tier ${SCALE} attempt ${attempt} failed — tail log:"
    tail -30 "${EX4}/logs/scale_chr-doe-${SCALE}gpu_${JOB}.out" 2>/dev/null || true
    echo "Retrying in 90s..."
    sleep 90
  done
  echo "GAVE UP tier ${SCALE} after ${MAX_ATTEMPTS} attempts"
  return 1
}

echo "Fix-and-scale loop started $(date)"
echo "Log: ${LOG}"

run_tier_with_retries 16 8 || exit 1
run_tier_with_retries 64 5 || exit 1

echo ""
echo "=== Ladder 16 → 64 complete $(date) ==="
