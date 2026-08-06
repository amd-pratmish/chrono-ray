#!/usr/bin/env bash
# Run scale ladder starting from tier 2 (tier 1 validated separately).
set -euo pipefail

EX4="/home/pratmish/chrono-ray/ex4-amd-multinode-fsi-doe"
LADDER_LOG="${EX4}/logs/scale_ladder_$(date +%Y%m%d_%H%M%S).log"
TIERS=(2 8 16 64)

exec > >(tee -a "${LADDER_LOG}") 2>&1

echo "============================================"
echo "GPU Scale Ladder — $(date)"
echo "Tiers: ${TIERS[*]} (tier 1 already validated)"
echo "============================================"

wait_for_job() {
  local JOB="$1"
  local SCALE="$2"
  echo "Waiting for job ${JOB} (scale ${SCALE})..."
  while squeue -j "${JOB}" -h 2>/dev/null | grep -q "${JOB}"; do
    sleep 30
  done
  local STATE
  STATE=$(sacct -j "${JOB}" --format=State -n -P 2>/dev/null | head -1 | cut -d'|' -f1)
  echo "Job ${JOB} finished: ${STATE}"

  local SUMMARY="${EX4}/results/scale${SCALE}gpu_${JOB}/scale_summary.txt"
  if [[ -f "${SUMMARY}" ]]; then
    cat "${SUMMARY}"
    local COMPLETED EXIT_CODE REQUESTED
    COMPLETED=$(grep trials_completed_dirs "${SUMMARY}" | cut -d= -f2)
    EXIT_CODE=$(grep exit_code "${SUMMARY}" | cut -d= -f2)
    REQUESTED=$(grep trials_requested "${SUMMARY}" | cut -d= -f2)
    if [[ "${EXIT_CODE}" != "0" ]] || [[ "${COMPLETED}" -lt "${REQUESTED}" ]]; then
      echo "FAIL: scale ${SCALE} — completed ${COMPLETED}/${REQUESTED}, exit ${EXIT_CODE}"
      return 1
    fi
    echo "PASS: scale ${SCALE} — ${COMPLETED}/${REQUESTED} trials"
    return 0
  fi

  # Accept success if doe_run.log shows completion even without summary
  local DOE_LOG="${EX4}/results/scale${SCALE}gpu_${JOB}/doe_run.log"
  if grep -q "DoE completed" "${DOE_LOG}" 2>/dev/null; then
    echo "PASS (log): scale ${SCALE} — DoE completed"
    return 0
  fi
  echo "FAIL: no scale_summary.txt for job ${JOB}"
  return 1
}

for SCALE in "${TIERS[@]}"; do
  echo ""
  echo "--- Tier ${SCALE} GPU ---"
  JOB=$(bash "${EX4}/submit_scale.sh" "${SCALE}" | awk '/Submitted/{print $NF}')
  echo "Submitted tier ${SCALE}, job ${JOB}"
  if ! wait_for_job "${JOB}" "${SCALE}"; then
    echo "Ladder stopped at ${SCALE} GPU tier."
    exit 1
  fi
done

echo ""
echo "============================================"
echo "Ladder complete: 2 → 8 → 16 → 64 GPUs"
echo "============================================"
