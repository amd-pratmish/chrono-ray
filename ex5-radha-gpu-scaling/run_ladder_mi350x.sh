#!/usr/bin/env bash
# Run full MI350X ladder: 1, 2, 4, 8, 16 GPUs on Radha mi350x-es.
set -euo pipefail

EX5="/shared/${USER}/src/chrono-ray-amd/ex5-radha-gpu-scaling"
PLATFORM=mi350x
TIERS=(1 2 4 8 16)
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
    if [[ -f "${SUMMARY}" ]]; then
        cat "${SUMMARY}"
        grep -q 'exit_code=0' "${SUMMARY}" && return 0
    fi
    return 1
}

for SCALE in "${TIERS[@]}"; do
    echo "--- ${PLATFORM} tier ${SCALE} GPU ---"
    JOB=$(bash "${EX5}/submit_scale.sh" "${PLATFORM}" "${SCALE}")
    wait_for_job "${JOB}" "${SCALE}" || { echo "Ladder stopped at ${SCALE}"; exit 1; }
done
echo "MI350X ladder complete."
