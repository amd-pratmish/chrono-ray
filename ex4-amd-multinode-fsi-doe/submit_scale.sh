#!/usr/bin/env bash
# Submit a scale tier: bash submit_scale.sh {1|2|8|16|24|32|64|72|96|128}
set -euo pipefail

SCALE="${1:?Usage: submit_scale.sh SCALE}"
EX4="/home/pratmish/chrono-ray/ex4-amd-multinode-fsi-doe"

source "${EX4}/scale_profiles.sh"
apply_scale_profile "${SCALE}"

mkdir -p "${EX4}/logs"

SBATCH_ARGS=(
  --job-name="chr-doe-${SCALE}gpu"
  --account=vultr_rad
  --partition="${CHR_RAY_PARTITION}"
  --nodes="${CHR_RAY_NODES}"
  --gres="gpu:amd_instinct_mi355_oam:${CHR_RAY_GPUS_PER_NODE}"
  --time="${CHR_RAY_TIME}"
  --export=ALL,CHR_RAY_SCALE="${SCALE}"
)
[[ -n "${CHR_RAY_QOS:-}" ]] && SBATCH_ARGS+=(--qos="${CHR_RAY_QOS}")

SUBMIT_OUT=$(sbatch "${SBATCH_ARGS[@]}" "${EX4}/launch_doe_scale.sbatch" 2>&1) || {
  echo "SUBMIT FAILED for ${SCALE} GPU: ${SUBMIT_OUT}"
  exit 1
}

JOB_ID=$(echo "${SUBMIT_OUT}" | awk '/Submitted batch job/{print $NF}')
if [[ -z "${JOB_ID}" ]]; then
  echo "SUBMIT FAILED (no job id): ${SUBMIT_OUT}"
  exit 1
fi

echo "Submitted ${SCALE}-GPU tier: job ${JOB_ID}"
echo "  partition=${CHR_RAY_PARTITION} nodes=${CHR_RAY_NODES} time=${CHR_RAY_TIME}"
echo "  ${CHR_RAY_TOTAL_GPUS} GPUs, ${CHR_RAY_NUM_TRIALS} trials, max ${CHR_RAY_MAX_CONCURRENT} concurrent"
echo "  Monitor: squeue -j ${JOB_ID}"
echo "  Log:     ${EX4}/logs/scale_chr-doe-${SCALE}gpu_${JOB_ID}.out"
echo "${JOB_ID}" > "${EX4}/logs/last_job_${SCALE}gpu.txt"
