#!/usr/bin/env bash
# Run tier 32 until PASS (64/64 trials). No other tiers.
set -euo pipefail

EX4="/home/pratmish/chrono-ray/ex4-amd-multinode-fsi-doe"
SCALE=32
MAX_ATTEMPTS=5
LOG="${EX4}/logs/tier32_until_pass_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "${LOG}") 2>&1

source "${EX4}/slurm_wait.sh"

check_pass() {
  local JOB="$1"
  local SUMMARY="${EX4}/results/scale${SCALE}gpu_${JOB}/scale_summary.txt"
  [[ -f "${SUMMARY}" ]] || return 1
  cat "${SUMMARY}"
  local COMPLETED EXIT_CODE REQUESTED
  COMPLETED=$(grep trials_completed_dirs "${SUMMARY}" | cut -d= -f2)
  EXIT_CODE=$(grep exit_code "${SUMMARY}" | cut -d= -f2)
  REQUESTED=$(grep trials_requested "${SUMMARY}" | cut -d= -f2)
  [[ "${EXIT_CODE}" == "0" && "${COMPLETED}" -ge "${REQUESTED}" ]]
}

echo "=== Tier 32 until PASS $(date) ==="
echo "Log: ${LOG}"

# Stop ladder jobs that compete for rad-burst nodes
pkill -f run_scale_extended_background.sh 2>/dev/null || true
scancel -u "${USER}" --name=chr-doe-64gpu 2>/dev/null || true
sleep 3

for attempt in $(seq 1 "${MAX_ATTEMPTS}"); do
  echo ""
  echo "--- Attempt ${attempt}/${MAX_ATTEMPTS} $(date) ---"
  if squeue -u "${USER}" -h -o "%j" 2>/dev/null | grep -q "chr-doe-32gpu"; then
    echo "Another 32-GPU job already queued — waiting on it..."
    JOB=$(squeue -u "${USER}" -h -o "%i %j" | awk '/chr-doe-32gpu/{print $1; exit}')
  else
    SUBMIT_LOG="${EX4}/logs/submit_32_attempt${attempt}.log"
    bash "${EX4}/submit_scale.sh" "${SCALE}" | tee "${SUBMIT_LOG}"
    JOB=$(grep -oP 'Submitted \d+-GPU tier: job \K\d+' "${SUBMIT_LOG}")
  fi

  echo "Monitoring job ${JOB}..."
  wait_for_slurm_job "${JOB}" 600 30

  if check_pass "${JOB}"; then
    echo "PASS tier 32 job ${JOB}"
    bash /home/pratmish/chrono-ray/scripts/persist_experiment_status.sh || true
    exit 0
  fi

  echo "Attempt ${attempt} failed — tail:"
  tail -50 "${EX4}/logs/scale_chr-doe-32gpu_${JOB}.out" 2>/dev/null || true
  tail -20 "${EX4}/results/scale32gpu_${JOB}/doe_run.log" 2>/dev/null || true
  sleep 120
done

echo "GAVE UP tier 32 after ${MAX_ATTEMPTS} attempts"
exit 1
