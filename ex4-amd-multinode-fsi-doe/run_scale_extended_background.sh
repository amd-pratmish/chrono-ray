#!/usr/bin/env bash
# Background scale ladder: 16 (skip if passed) → 32 → 64 → 72 → 96 → 128
# Retries each tier until success or max attempts. 8 h wall clock per job.
set -uo pipefail

EX4="/home/pratmish/chrono-ray/ex4-amd-multinode-fsi-doe"
LOG="${EX4}/logs/scale_extended_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "${LOG}") 2>&1

LADDER=(16 32 64 72 96 128)

wait_job() {
  # shellcheck source=slurm_wait.sh
  source "${EX4}/slurm_wait.sh"
  wait_for_slurm_job "$1" 600 45
}

tier_already_passed() {
  local SCALE="$1"
  local SUMMARY
  for SUMMARY in "${EX4}"/results/scale${SCALE}gpu_*/scale_summary.txt; do
    [[ -f "${SUMMARY}" ]] || continue
    local COMPLETED EXIT_CODE REQUESTED
    COMPLETED=$(grep trials_completed_dirs "${SUMMARY}" | cut -d= -f2)
    EXIT_CODE=$(grep exit_code "${SUMMARY}" | cut -d= -f2)
    REQUESTED=$(grep trials_requested "${SUMMARY}" | cut -d= -f2)
    if [[ "${EXIT_CODE}" == "0" && "${COMPLETED}" -ge "${REQUESTED}" ]]; then
      echo "SKIP tier ${SCALE}: already passed (${SUMMARY})"
      cat "${SUMMARY}"
      return 0
    fi
  done
  return 1
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

tier_job_running() {
  local SCALE="$1"
  squeue -u "${USER:-pratmish}" -h -o "%j" 2>/dev/null | grep -q "chr-doe-${SCALE}gpu"
}

run_tier() {
  local SCALE="$1"
  local MAX_ATTEMPTS="${2:-6}"
  local attempt=0

  if tier_already_passed "${SCALE}"; then
    return 0
  fi

  if tier_job_running "${SCALE}"; then
    echo "Tier ${SCALE}: job already in queue — waiting..."
    JOB=$(squeue -u "${USER:-pratmish}" -h -o "%i %j" 2>/dev/null | awk -v s="chr-doe-${SCALE}gpu" '$2 ~ s {print $1; exit}')
    wait_job "${JOB}"
    if check_pass "${JOB}" "${SCALE}"; then
      echo "PASS tier ${SCALE} job ${JOB}"
      bash /home/pratmish/chrono-ray/scripts/persist_experiment_status.sh || true
      return 0
    fi
  fi

  while [[ "${attempt}" -lt "${MAX_ATTEMPTS}" ]]; do
    attempt=$((attempt + 1))
    echo ""
    echo "=== Tier ${SCALE} GPU — attempt ${attempt}/${MAX_ATTEMPTS} $(date) ==="

    SUBMIT_LOG="${EX4}/logs/submit_${SCALE}_attempt${attempt}.log"
    if ! bash "${EX4}/submit_scale.sh" "${SCALE}" > "${SUBMIT_LOG}" 2>&1; then
      echo "Submit failed:"
      cat "${SUBMIT_LOG}"
      echo "Retrying in 120s..."
      sleep 120
      continue
    fi
    cat "${SUBMIT_LOG}"
    JOB=$(grep -oP 'Submitted \d+-GPU tier: job \K\d+' "${SUBMIT_LOG}" || true)
    if [[ -z "${JOB}" ]]; then
      echo "No job id parsed; retrying in 120s..."
      sleep 120
      continue
    fi

    wait_job "${JOB}"
    if check_pass "${JOB}" "${SCALE}"; then
      echo "PASS tier ${SCALE} job ${JOB}"
      bash /home/pratmish/chrono-ray/scripts/persist_experiment_status.sh || true
      return 0
    fi

    echo "Tier ${SCALE} attempt ${attempt} failed — log tail:"
    tail -40 "${EX4}/logs/scale_chr-doe-${SCALE}gpu_${JOB}.out" 2>/dev/null || true
    echo "Retrying in 120s..."
    sleep 120
  done

  echo "GAVE UP tier ${SCALE} after ${MAX_ATTEMPTS} attempts"
  return 1
}

echo "Extended scale ladder started $(date)"
echo "Log: ${LOG}"
echo "Tiers: ${LADDER[*]} (8 h wall clock, rad-burst for 32+ GPU)"

FAILED=0
for SCALE in "${LADDER[@]}"; do
  if ! run_tier "${SCALE}" 6; then
    FAILED=$((FAILED + 1))
    echo "Continuing to next tier despite failure on ${SCALE}..."
  fi
done

echo "=== Ladder finished $(date) — ${FAILED} tier(s) failed ==="
bash /home/pratmish/chrono-ray/scripts/persist_experiment_status.sh || true
