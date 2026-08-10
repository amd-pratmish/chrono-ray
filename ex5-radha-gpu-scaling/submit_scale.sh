#!/usr/bin/env bash
# Submit ex5 scale tier: bash submit_scale.sh {mi350x|mi300x} {1|2|4|8|16|24|32|64}
set -euo pipefail

PLATFORM="${1:?Usage: submit_scale.sh PLATFORM SCALE}"
SCALE="${2:?Usage: submit_scale.sh PLATFORM SCALE}"

source "$(dirname "${BASH_SOURCE[0]}")/paths.env"
source "${EX5}/scale_profiles.sh"

export CHR_RAY_PLATFORM="${PLATFORM}"
if ! apply_scale_profile "${SCALE}"; then
    echo "Profile unavailable: ${PLATFORM} @ ${SCALE} GPU"
    exit 1
fi

mkdir -p "${EX5}/logs" "${RESULTS_ROOT}/${CHR_RAY_RESULTS_TAG}/logs"

SBATCH_OUT=$(sbatch \
    --job-name="ex5-${PLATFORM}-${SCALE}g" \
    --partition="${CHR_RAY_PARTITION}" \
    --nodes="${CHR_RAY_NODES}" \
    --gres="${CHR_RAY_GRES}:${CHR_RAY_GPUS_PER_NODE}" \
    --time="${CHR_RAY_TIME}" \
    --export=ALL,CHR_RAY_PLATFORM="${PLATFORM}",CHR_RAY_SCALE="${SCALE}" \
    "${EX5}/launch_doe_scale.sbatch" 2>&1) || {
    echo "SUBMIT FAILED: ${SBATCH_OUT}"
    exit 1
}

JOB_ID=$(echo "${SBATCH_OUT}" | awk '/Submitted batch job/{print $NF}')
echo "Submitted ${PLATFORM} ${SCALE}-GPU: job ${JOB_ID}"
echo "  partition=${CHR_RAY_PARTITION} nodes=${CHR_RAY_NODES} gres=${CHR_RAY_GRES}:${CHR_RAY_GPUS_PER_NODE}"
echo "${JOB_ID}" > "${EX5}/logs/last_job_${PLATFORM}_${SCALE}gpu.txt"
echo "${JOB_ID}"
