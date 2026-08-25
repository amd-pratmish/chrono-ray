#!/usr/bin/env bash
# Submit one coupled scale tier.
set -euo pipefail

SCALE="${1:?Usage: submit_coupled_scale.sh SCALE}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cluster_profiles/load_cluster.sh
source "${SCRIPT_DIR}/cluster_profiles/load_cluster.sh"
EX5="${CHR_EX5_DIR}"

source "${EX5}/scale_profiles_coupled.sh"
apply_coupled_scale_profile "${SCALE}"

TAG="${CHR_COUPLED_JOB_TAG:-}"
if [[ "${CHR_RAY_MULTI_GPU_CONCURRENT:-0}" == "1" ]]; then
  TAG="mg"
fi
JOB_NAME="chr-coupled-${TAG}${SCALE}r"

mkdir -p "${EX5}/logs"

partition_qos_for() {
  local PART="$1"
  if [[ -n "${CHR_RAY_QOS_LARGE:-}" && "${PART}" == "${CHR_RAY_PARTITION_LARGE:-}" ]]; then
    echo "${CHR_RAY_QOS_LARGE}"
  fi
  return 0
}

submit_to_partition() {
  local PART="$1" QOS="${2:-}"
  local MEM_ARG=(--mem="${CHR_SLURM_MEM_PER_NODE:-256G}")
  if [[ "${CHR_SLURM_USE_MEM_PER_NODE:-1}" != "1" ]]; then
    MEM_ARG=(--mem="${CHR_SLURM_MEM:-256G}")
  fi
  local ARGS=(
    --job-name="${JOB_NAME}"
    --account="${CHR_SLURM_ACCOUNT}"
    --partition="${PART}"
    --nodes="${CHR_RAY_NODES}"
    --ntasks="${CHR_SLURM_NTASKS}"
    --ntasks-per-node="${CHR_SLURM_NTASKS_PER_NODE}"
    --cpus-per-task="${CHR_MPI_CPUS_PER_RANK}"
    "${MEM_ARG[@]}"
    --gres="${CHR_SLURM_GRES_GPU}"
    --time="${CHR_RAY_TIME}"
    --output="${EX5}/logs/coupled_scale_%x_%j.out"
    --error="${EX5}/logs/coupled_scale_%x_%j.err"
    --export=ALL,CHR_COUPLED_SCALE="${SCALE}",CHR_COUPLED_JOB_TAG="${TAG}",CHR_CLUSTER="${CHR_CLUSTER}",CHR_EX5_DIR="${EX5}",CHR_GPU_MPI_RANK="${CHR_GPU_MPI_RANK:-0}",CHR_RAY_MODE="${CHR_RAY_MODE:-gpu_fsi_mpi}",CHR_MPI_CPUS_PER_RANK="${CHR_MPI_CPUS_PER_RANK}",CHR_RAY_MULTI_GPU_CONCURRENT="${CHR_RAY_MULTI_GPU_CONCURRENT:-0}",CHR_SRUN_DISTRIBUTION="${CHR_SRUN_DISTRIBUTION:-}",CHR_SRUN_NTASKS_PER_NODE="${CHR_SRUN_NTASKS_PER_NODE:-}",OMPI_MCA_pml="${OMPI_MCA_pml:-ob1}",OMPI_MCA_btl="${OMPI_MCA_btl:-self,tcp}",UCX_TLS="${UCX_TLS:-sm,self,tcp}"
  )
  [[ -n "${QOS}" ]] && ARGS+=(--qos="${QOS}")
  sbatch "${ARGS[@]}" "${EX5}/launch_coupled_scale.sbatch" 2>&1
}

PARTITIONS=()
if [[ -n "${CHR_RAY_PARTITION_CANDIDATES:-}" ]]; then
  # shellcheck disable=SC2206
  PARTITIONS=(${CHR_RAY_PARTITION_CANDIDATES})
elif [[ "${CHR_RAY_PARTITION}" == "${CHR_RAY_PARTITION_LARGE:-}" ]]; then
  PARTITIONS=("${CHR_RAY_PARTITION_LARGE}")
  [[ -n "${CHR_RAY_PARTITION_LARGE_FALLBACK:-}" ]] && PARTITIONS+=("${CHR_RAY_PARTITION_LARGE_FALLBACK}")
else
  PARTITIONS=("${CHR_RAY_PARTITION_SMALL:-${CHR_RAY_PARTITION}}")
fi

OUT="" USED=""
for PART in "${PARTITIONS[@]}"; do
  QOS="$(partition_qos_for "${PART}")"
  echo "Trying partition=${PART} cluster=${CHR_CLUSTER_NAME} nodes=${CHR_RAY_NODES} ranks=${CHR_MPI_RANKS}..."
  if OUT="$(submit_to_partition "${PART}" "${QOS}")"; then
    if echo "${OUT}" | grep -q "Submitted batch job"; then
      USED="${PART}"
      break
    fi
  fi
  echo "  rejected: ${OUT}"
  OUT=""
done

[[ -n "${USED}" ]] || { echo "SUBMIT FAILED tier ${SCALE}"; exit 1; }

JOB_ID=$(echo "${OUT}" | awk '/Submitted batch job/{print $NF}')
  echo "Submitted coupled tier ${SCALE} (MPI ranks=${CHR_MPI_RANKS}): job ${JOB_ID}"
  echo "  cluster=${CHR_CLUSTER_NAME} partition=${USED} nodes=${CHR_RAY_NODES} gpus/node=${CHR_RAY_GPUS_PER_NODE} max_concurrent=${CHR_RAY_MAX_CONCURRENT} time=${CHR_RAY_TIME} trials=${CHR_RAY_NUM_TRIALS}"
echo "${JOB_ID}" > "${EX5}/logs/last_coupled_${SCALE}.txt"
