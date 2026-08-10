#!/usr/bin/env bash
# Scale ladder: 24 → 32 → 64 → 72 → 96 → 128 (skip tiers already PASS).
set -uo pipefail

EX4="/home/pratmish/chrono-ray/ex4-amd-multinode-fsi-doe"
LADDER=(24 32 64 72 96 128)
MAX_ATTEMPTS=5
LOG="${EX4}/logs/ladder_24_plus_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "${LOG}") 2>&1

source "${EX4}/slurm_wait.sh"

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
  [[ -f "${SUMMARY}" ]] || return 1
  cat "${SUMMARY}"
  local COMPLETED EXIT_CODE REQUESTED
  COMPLETED=$(grep trials_completed_dirs "${SUMMARY}" | cut -d= -f2)
  EXIT_CODE=$(grep exit_code "${SUMMARY}" | cut -d= -f2)
  REQUESTED=$(grep trials_requested "${SUMMARY}" | cut -d= -f2)
  [[ "${EXIT_CODE}" == "0" && "${COMPLETED}" -ge "${REQUESTED}" ]]
}

run_tier() {
  local SCALE="$1"
  local attempt=0

  tier_already_passed "${SCALE}" && return 0

  while [[ "${attempt}" -lt "${MAX_ATTEMPTS}" ]]; do
    attempt=$((attempt + 1))
    echo ""
    echo "=== Tier ${SCALE} GPU — attempt ${attempt}/${MAX_ATTEMPTS} $(date) ==="

    local JOB=""
    if squeue -u "${USER}" -h -o "%j" 2>/dev/null | grep -q "chr-doe-${SCALE}gpu"; then
      JOB=$(squeue -u "${USER}" -h -o "%i %j" | awk -v s="chr-doe-${SCALE}gpu" '$2 ~ s {print $1; exit}')
      echo "Waiting on existing job ${JOB}..."
    else
      local SUBMIT_LOG="${EX4}/logs/submit_${SCALE}_attempt${attempt}.log"
      if ! bash "${EX4}/submit_scale.sh" "${SCALE}" | tee "${SUBMIT_LOG}"; then
        echo "Submit failed; retry in 120s..."
        sleep 120
        continue
      fi
      JOB=$(grep -oP 'Submitted \d+-GPU tier: job \K\d+' "${SUBMIT_LOG}" || true)
      [[ -n "${JOB}" ]] || { sleep 120; continue; }
    fi

    wait_for_slurm_job "${JOB}" 600 30

    if check_pass "${JOB}" "${SCALE}"; then
      echo "PASS tier ${SCALE} job ${JOB}"
      bash /home/pratmish/chrono-ray/scripts/persist_experiment_status.sh || true
      return 0
    fi

    echo "Tier ${SCALE} attempt ${attempt} failed:"
    tail -40 "${EX4}/logs/scale_chr-doe-${SCALE}gpu_${JOB}.out" 2>/dev/null || true
    sleep 120
  done

  echo "GAVE UP tier ${SCALE}"
  return 1
}

echo "=== Ladder 24 → 32 → 64+ started $(date) ==="
echo "Log: ${LOG}"
pkill -f run_tier32_until_pass.sh 2>/dev/null || true
pkill -f run_scale_extended_background.sh 2>/dev/null || true
sleep 2

FAILED=0
for SCALE in "${LADDER[@]}"; do
  if ! run_tier "${SCALE}"; then
    FAILED=$((FAILED + 1))
    echo "Continuing despite failure on tier ${SCALE}..."
  fi
done

echo "=== Ladder finished — ${FAILED} tier(s) failed $(date) ==="
bash /home/pratmish/chrono-ray/scripts/persist_experiment_status.sh || true
