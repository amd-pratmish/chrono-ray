#!/usr/bin/env bash
# Run MI300X ladder on Radha: 1,2,4,8,16 then attempt 24,32,64 if nodes exist.
set -euo pipefail

EX5="/shared/${USER}/src/chrono-ray-amd/ex5-radha-gpu-scaling"
PLATFORM=mi300x
TIERS=(1 2 4 8 16 24 32 64)
LOG="${EX5}/logs/ladder_${PLATFORM}_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "${LOG}") 2>&1

wait_for_job() {
    local JOB="$1" SCALE="$2"
    echo "Waiting job ${JOB} (${SCALE} GPU)..."
    while squeue -j "${JOB}" -h 2>/dev/null | grep -q "${JOB}"; do sleep 30; done
    local STATE
    STATE=$(sacct -j "${JOB}" --format=State -n -P 2>/dev/null | head -1 | cut -d'|' -f1)
    echo "Job ${JOB} finished: ${STATE}"
    local SUMMARY="/shared/${USER}/amd_chronos_results/phase3/ex5_radha_scaling/${PLATFORM}/scale${SCALE}gpu_${JOB}/scale_summary.txt"
    [[ -f "${SUMMARY}" ]] && cat "${SUMMARY}"
    [[ "${STATE}" == "COMPLETED" ]] && return 0
    return 1
}

for SCALE in "${TIERS[@]}"; do
    echo "--- ${PLATFORM} tier ${SCALE} GPU ---"
    if ! JOB=$(bash "${EX5}/submit_scale.sh" "${PLATFORM}" "${SCALE}" 2>&1); then
        echo "Skip tier ${SCALE}: submit failed"
        continue
    fi
    JOB=$(echo "${JOB}" | tail -1)
    wait_for_job "${JOB}" "${SCALE}" || echo "WARN: tier ${SCALE} did not complete cleanly"
done
echo "MI300X ladder finished (see log for skipped tiers)."
