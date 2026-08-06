#!/usr/bin/env bash
# Sequential scale ladder: 8 → 16 → 64 (tiers 1 and 2 already validated).
set -euo pipefail

EX4="/home/pratmish/chrono-ray/ex4-amd-multinode-fsi-doe"
LOG="${EX4}/logs/ladder_8_16_64_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "${LOG}") 2>&1

wait_job() {
  local JOB="$1" SCALE="$2"
  echo "Waiting for job ${JOB} (tier ${SCALE})..."
  while squeue -j "${JOB}" -h 2>/dev/null | grep -q "${JOB}"; do sleep 45; done
  sleep 5
  local SUMMARY="${EX4}/results/scale${SCALE}gpu_${JOB}/scale_summary.txt"
  if [[ -f "${SUMMARY}" ]]; then
    cat "${SUMMARY}"
    local COMPLETED EXIT_CODE REQUESTED
    COMPLETED=$(grep trials_completed_dirs "${SUMMARY}" | cut -d= -f2)
    EXIT_CODE=$(grep exit_code "${SUMMARY}" | cut -d= -f2)
    REQUESTED=$(grep trials_requested "${SUMMARY}" | cut -d= -f2)
    [[ "${EXIT_CODE}" == "0" && "${COMPLETED}" -ge "${REQUESTED}" ]] && return 0
  fi
  echo "FAIL tier ${SCALE}"; return 1
}

for SCALE in 8 16 64; do
  echo ""; echo "=== Tier ${SCALE} GPU $(date) ==="
  JOB=$(bash "${EX4}/submit_scale.sh" "${SCALE}" | awk '/Submitted/{print $NF}')
  wait_job "${JOB}" "${SCALE}" || exit 1
  echo "PASS tier ${SCALE}"
done

echo ""; echo "Ladder 8 → 16 → 64 complete."
