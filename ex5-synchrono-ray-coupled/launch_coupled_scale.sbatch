#!/usr/bin/env bash
# Slurm driver for ex5 coupled scaling ladder tier.
# Submit via: bash submit_coupled_scale.sh {1|2|4|8|16|24|32|64|72|96|128}

#SBATCH --job-name=chr-coupled-scale
#SBATCH --cpus-per-task=2
#SBATCH --requeue
# account / mem / gres / output paths set by submit_coupled_scale.sh

set -euo pipefail

# Slurm runs a copy from spool; prefer submit-time paths from --export.
EX5="${CHR_EX5_DIR:-${SLURM_SUBMIT_DIR:-}}"
if [[ -z "${EX5}" || ! -d "${EX5}/cluster_profiles" ]]; then
  EX5="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
export CHR_EX5_DIR="${EX5}"
# shellcheck source=cluster_profiles/load_cluster.sh
source "${EX5}/cluster_profiles/load_cluster.sh"
VENV="${CHR_VENV}"
SCALE="${CHR_COUPLED_SCALE:-8}"
TAG="${CHR_COUPLED_JOB_TAG:-}"
if [[ "${CHR_RAY_MULTI_GPU_CONCURRENT:-0}" == "1" ]]; then
  TAG="mg"
fi

source "${EX5}/scale_profiles_coupled.sh"
apply_coupled_scale_profile "${SCALE}"

mkdir -p "${EX5}/logs" "${EX5}/results"
RUN_DIR="${EX5}/results/coupled${TAG}${SCALE}rank_${SLURM_JOB_ID}"
mkdir -p "${RUN_DIR}"

export CHR_RAY_OUTPUT_DIR="${RUN_DIR}"
export CHR_COUPLED_SCALE="${SCALE}"
export CHR_MPI_RANKS="${CHR_MPI_RANKS}"
export CHR_RAY_NUM_TRIALS="${CHR_RAY_NUM_TRIALS}"
export CHR_RAY_MAX_CONCURRENT="${CHR_RAY_MAX_CONCURRENT}"
export CHR_MPI_USE_SRUN=1
export CHR_SRUN_EXTRA="${CHR_SRUN_EXTRA:---overlap}"
export CHR_SRUN_MPI="${CHR_SRUN_MPI:-pmix}"
export CHR_SRUN_DISTRIBUTION="${CHR_SRUN_DISTRIBUTION:-}"
export CHR_SRUN_NTASKS_PER_NODE="${CHR_SRUN_NTASKS_PER_NODE:-${CHR_SLURM_NTASKS_PER_NODE:-}}"
export CHR_SRUN_GPU_BIND="${CHR_SRUN_GPU_BIND:-1}"
export CHR_RAY_MODE="${CHR_RAY_MODE:-gpu_fsi_mpi}"
export CHR_GPU_MPI_RANK="${CHR_GPU_MPI_RANK:-0}"
export CHR_RAY_MULTI_GPU_CONCURRENT="${CHR_RAY_MULTI_GPU_CONCURRENT:-0}"

# Stable multi-node MPI on Slurm/OpenMPI (avoid UCX thread issues seen at tier 16+).
export OMPI_MCA_pml="${OMPI_MCA_pml:-ob1}"
export OMPI_MCA_btl="${OMPI_MCA_btl:-self,tcp}"
export OMPI_MCA_mpi_leave_pinned="${OMPI_MCA_mpi_leave_pinned:-0}"
export UCX_TLS="${UCX_TLS:-sm,self,tcp}"
export OMP_NUM_THREADS="${OMP_NUM_THREADS:-1}"

export CHR_MPI_PYTHON="${VENV}/bin/python3"
export PYCHRONO_BIN="${CHR_PYCHRONO_BIN}"
export PYTHONPATH="${PYCHRONO_BIN}:${CHR_RAY_REPO_ROOT}:${EX5}:${PYTHONPATH:-}"
export HSA_XNACK=0
export HIP_LAUNCH_BLOCKING=0
export PYTHONUNBUFFERED=1

source "${VENV}/bin/activate"

EX4_RAY_ENV="${CHR_EX4_DIR}/ray_cluster_env.sh"
if [[ -f "${EX4_RAY_ENV}" ]]; then
  # shellcheck source=/dev/null
  source "${EX4_RAY_ENV}"
  ray_cluster_env
fi

echo "=============================================="
echo "ex5 coupled scale tier ${SCALE}  job ${SLURM_JOB_ID}"
echo "  cluster=${CHR_CLUSTER_NAME} partition=${SLURM_JOB_PARTITION} nodes=${SLURM_NNODES}"
echo "  MPI ranks/trial=${CHR_MPI_RANKS} trials=${CHR_RAY_NUM_TRIALS}"
echo "  max_concurrent=${CHR_RAY_MAX_CONCURRENT} mode=${CHR_RAY_MODE} multi_gpu=${CHR_RAY_MULTI_GPU_CONCURRENT}"
echo "  slurm_ntasks=${SLURM_NTASKS:-?} cpus-per-task=${SLURM_CPUS_PER_TASK:-?}"
echo "  output=${RUN_DIR}"
echo "=============================================="

ray stop --force 2>/dev/null || true
RAY_CPUS="${SLURM_CPUS_ON_NODE:-${SLURM_CPUS_PER_TASK:-16}}"
[[ "${RAY_CPUS}" -gt 8 ]] && RAY_CPUS=8
[[ "${RAY_CPUS}" -lt 2 ]] && RAY_CPUS=2
# Cap object store — default Ray sizing can grab ~200GB and kill raylet on multi-node jobs.
RAY_OBJECT_STORE="${CHR_RAY_OBJECT_STORE_BYTES:-2000000000}"
ray start --head \
  --num-cpus="${RAY_CPUS}" \
  --num-gpus=0 \
  --object-store-memory="${RAY_OBJECT_STORE}" \
  --disable-usage-stats
export RAY_ADDRESS="auto"
export RAY_gcs_rpc_server_reconnect_timeout_s="${RAY_gcs_rpc_server_reconnect_timeout_s:-120}"
# Slurm gres owns the GPU; nested srun/MPI uses it (Ray must not reserve gpu=1).
export CHR_MPI_TRIAL_TIMEOUT="${CHR_MPI_TRIAL_TIMEOUT:-$(( 1800 + CHR_MPI_RANKS * 600 ))}"
[[ "${CHR_MPI_TRIAL_TIMEOUT}" -lt 3600 ]] && export CHR_MPI_TRIAL_TIMEOUT=3600

cd "${RUN_DIR}"
set +e
python3 -u "${EX5}/doe_coupled_scale.py" 2>&1 | tee doe_run.log
EXIT_CODE=${PIPESTATUS[0]}
set -e

ray stop --force || true

if [[ -f scale_summary.txt ]]; then
  sed -i "s/^exit_code=.*/exit_code=${EXIT_CODE}/" scale_summary.txt 2>/dev/null || true
fi

echo "Finished tier ${SCALE} exit=${EXIT_CODE}"
exit "${EXIT_CODE}"
