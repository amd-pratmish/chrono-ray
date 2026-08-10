#!/usr/bin/env bash
# Submit MI350X ladder as chained jobs (1,2,4,8,16 GPU).
# Usage: bash submit_ladder_chain_mi350x.sh [after_job_id]
set -euo pipefail

EX5="/shared/${USER}/src/chrono-ray-amd/ex5-radha-gpu-scaling"
source "${EX5}/scale_profiles.sh"
PLATFORM=mi350x
export CHR_RAY_PLATFORM="${PLATFORM}"
TIERS=(1 2 4 8 16)
PREV="${1:-}"

submit_tier() {
    local SCALE="$1"
    apply_scale_profile "${SCALE}" || return 1
    local DEP=()
    [[ -n "${PREV}" ]] && DEP=(--dependency=afterok:"${PREV}")
    local OUT
    OUT=$(sbatch "${DEP[@]}" \
        --job-name="ex5-${PLATFORM}-${SCALE}g" \
        --partition=mi350x-es \
        --time="${CHR_RAY_TIME}" \
        --nodes="${CHR_RAY_NODES}" \
        --gres="${CHR_RAY_GRES}:${CHR_RAY_GPUS_PER_NODE}" \
        --output="/shared/${USER}/amd_chronos_results/phase3/ex5_radha_scaling/logs/scale_${PLATFORM}_${SCALE}g_%j.out" \
        --error="/shared/${USER}/amd_chronos_results/phase3/ex5_radha_scaling/logs/scale_${PLATFORM}_${SCALE}g_%j.err" \
        --export=ALL,CHR_RAY_PLATFORM="${PLATFORM}",CHR_RAY_SCALE="${SCALE}" \
        "${EX5}/launch_doe_scale.sbatch" 2>&1) || {
        echo "skip tier ${SCALE}: ${OUT}"
        return 1
    }
    PREV=$(echo "${OUT}" | grep -oP 'Submitted batch job \K[0-9]+' | tail -1)
    echo "tier ${SCALE} GPU -> job ${PREV}"
}

for SCALE in "${TIERS[@]}"; do
    submit_tier "${SCALE}" || true
done
echo "MI350X chain last job: ${PREV:-none}"
