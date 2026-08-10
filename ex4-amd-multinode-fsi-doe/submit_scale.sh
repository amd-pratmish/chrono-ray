#!/usr/bin/env bash
# Submit a scale tier: bash submit_scale.sh {1|2|8|16|24|32|64|72|96|128}
set -euo pipefail

SCALE="${1:?Usage: submit_scale.sh SCALE}"
EX4="/home/pratmish/chrono-ray/ex4-amd-multinode-fsi-doe"

source "${EX4}/scale_profiles.sh"
apply_scale_profile "${SCALE}"

mkdir -p "${EX4}/logs"

partition_qos_for() {
  local PART="$1"
  case "${PART}" in
    rad-burst) echo "low" ;;
    *) echo "" ;;
  esac
}

submit_to_partition() {
  local PART="$1"
  local QOS="${2:-}"

  local SBATCH_ARGS=(
    --job-name="chr-doe-${SCALE}gpu"
    --account=vultr_rad
    --partition="${PART}"
    --nodes="${CHR_RAY_NODES}"
    --gres="gpu:amd_instinct_mi355_oam:${CHR_RAY_GPUS_PER_NODE}"
    --time="${CHR_RAY_TIME}"
    --export=ALL,CHR_RAY_SCALE="${SCALE}"
  )
  [[ -n "${QOS}" ]] && SBATCH_ARGS+=(--qos="${QOS}")

  sbatch "${SBATCH_ARGS[@]}" "${EX4}/launch_doe_scale.sbatch" 2>&1
}

# Build candidate partition list (dedupe, preserve order).
PARTITIONS=()
if [[ -n "${CHR_RAY_PARTITION_CANDIDATES:-}" ]]; then
  read -r -a PARTITIONS <<< "${CHR_RAY_PARTITION_CANDIDATES}"
elif [[ -n "${CHR_RAY_PARTITION:-}" ]]; then
  PARTITIONS=("${CHR_RAY_PARTITION}")
fi

if [[ ${#PARTITIONS[@]} -eq 0 ]]; then
  echo "SUBMIT FAILED for ${SCALE} GPU: no partition configured"
  exit 1
fi

SUBMIT_OUT=""
USED_PARTITION=""
for PART in "${PARTITIONS[@]}"; do
  QOS="$(partition_qos_for "${PART}")"
  [[ -z "${QOS}" && -n "${CHR_RAY_QOS:-}" ]] && QOS="${CHR_RAY_QOS}"

  echo "Trying partition=${PART} qos=${QOS:-default} nodes=${CHR_RAY_NODES}..."
  if SUBMIT_OUT="$(submit_to_partition "${PART}" "${QOS}")"; then
    if echo "${SUBMIT_OUT}" | grep -q "Submitted batch job"; then
      USED_PARTITION="${PART}"
      break
    fi
  fi
  echo "  rejected: ${SUBMIT_OUT}"
  SUBMIT_OUT=""
done

if [[ -z "${USED_PARTITION}" ]]; then
  echo "SUBMIT FAILED for ${SCALE} GPU after trying: ${PARTITIONS[*]}"
  exit 1
fi

JOB_ID=$(echo "${SUBMIT_OUT}" | awk '/Submitted batch job/{print $NF}')
if [[ -z "${JOB_ID}" ]]; then
  echo "SUBMIT FAILED (no job id): ${SUBMIT_OUT}"
  exit 1
fi

echo "Submitted ${SCALE}-GPU tier: job ${JOB_ID}"
echo "  partition=${USED_PARTITION} nodes=${CHR_RAY_NODES} time=${CHR_RAY_TIME}"
echo "  ${CHR_RAY_TOTAL_GPUS} GPUs, ${CHR_RAY_NUM_TRIALS} trials, max ${CHR_RAY_MAX_CONCURRENT} concurrent"
echo "  Monitor: squeue -j ${JOB_ID}"
echo "  Log:     ${EX4}/logs/scale_chr-doe-${SCALE}gpu_${JOB_ID}.out"
echo "${JOB_ID}" > "${EX4}/logs/last_job_${SCALE}gpu.txt"
