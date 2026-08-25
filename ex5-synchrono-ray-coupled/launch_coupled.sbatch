#!/usr/bin/env bash
# Slurm driver: Ray orchestrates MPI-coupled trials (ex5 smoke or SynChrono).
# Usage:
#   CHR_RAY_MODE=smoke  bash submit_coupled.sh
#   CHR_RAY_MODE=synchrono bash submit_coupled.sh

#SBATCH --job-name=chr-coupled
#SBATCH --account=vultr_rad
#SBATCH --partition=rad
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=32
#SBATCH --time=02:00:00
#SBATCH --output=/home/pratmish/chrono-ray/ex5-synchrono-ray-coupled/logs/coupled_%x_%j.out
#SBATCH --error=/home/pratmish/chrono-ray/ex5-synchrono-ray-coupled/logs/coupled_%x_%j.err

set -euo pipefail

EX5="/home/pratmish/chrono-ray/ex5-synchrono-ray-coupled"
VENV="/home/pratmish/chrono-ray/.venv"
MODE="${CHR_RAY_MODE:-smoke}"

export CHR_MPI_RANKS="${CHR_MPI_RANKS:-4}"
export CHR_MPI_CPUS_PER_RANK="${CHR_MPI_CPUS_PER_RANK:-4}"
export CHR_RAY_NUM_TRIALS="${CHR_RAY_NUM_TRIALS:-8}"
export CHR_RAY_MAX_CONCURRENT="${CHR_RAY_MAX_CONCURRENT:-2}"
export CHR_MPI_USE_SRUN=1

RUN_DIR="${EX5}/results/${MODE}_${SLURM_JOB_ID}"
mkdir -p "${RUN_DIR}" "${EX5}/logs"
export CHR_RAY_OUTPUT_DIR="${RUN_DIR}"

source "${VENV}/bin/activate"
export PYTHONPATH="/home/pratmish/chrono-ray:${EX5}:${PYTHONPATH:-}"

echo "=============================================="
echo "ex5 coupled Ray+MPI job ${SLURM_JOB_ID} mode=${MODE}"
echo "  nodes=${SLURM_NNODES} cpus=${SLURM_CPUS_PER_TASK}"
echo "  MPI ranks/trial=${CHR_MPI_RANKS}"
echo "  trials=${CHR_RAY_NUM_TRIALS} max_concurrent=${CHR_RAY_MAX_CONCURRENT}"
echo "  output=${RUN_DIR}"
echo "=============================================="

# Local Ray on batch node (MPI trials launched via srun inside workers)
ray stop --force 2>/dev/null || true
ray start --head --num-cpus="${SLURM_CPUS_PER_TASK}" --disable-usage-stats
export RAY_ADDRESS="auto"

case "${MODE}" in
  smoke)
    DRIVER="${EX5}/doe_mpi_smoke.py"
    ;;
  synchrono)
    export CHRONO_BUILD_BIN="${CHRONO_BUILD_BIN:-/home/pratmish/amd-chronos/build-mi355x-synchrono/bin}"
    DRIVER="${EX5}/doe_synchrono_scm.py"
    ;;
  *)
    echo "Unknown CHR_RAY_MODE=${MODE} (use smoke or synchrono)"
    exit 1
    ;;
esac

cd "${RUN_DIR}"
python3 -u "${DRIVER}" 2>&1 | tee doe_run.log

ray stop --force || true
echo "Finished job ${SLURM_JOB_ID}"
