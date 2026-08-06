#!/usr/bin/env bash
# Start a multi-node Ray cluster on Slurm with AMD Instinct GPUs (ROCm).
#
# Usage:
#   sbatch start_ray_cluster_amd.sbatch
#   # After cluster is up, on the head node:
#   export RAY_ADDRESS="auto"
#   python doe_amd_fsi.py
#
# Adjust --nodes, --gres, and partition for your site.

#SBATCH --job-name=chr-ray-amd
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=1
#SBATCH --cpus-per-task=16
#SBATCH --gres=gpu:mi355:4
#SBATCH --mem=256G
#SBATCH --time=04:00:00
#SBATCH --output=ray_cluster_%j.out
#SBATCH --error=ray_cluster_%j.err

set -euo pipefail

# --- Site-specific: activate env with PyChrono (HIP/FSI) + Ray ---
# source /opt/rocm/setup.sh
# conda activate chrono-ray-amd

HEAD_NODE=$(scontrol show hostnames "$SLURM_JOB_NODELIST" | head -n1)
PORT=6379
DASHBOARD_PORT=8265

export HSA_XNACK=0
export HIP_LAUNCH_BLOCKING=0
export GPU_MAX_HW_QUEUES=2

echo "Ray head: ${HEAD_NODE}:${PORT}"
echo "Slurm nodes: $(scontrol show hostnames "$SLURM_JOB_NODELIST" | tr '\n' ' ')"

if [[ "$(hostname)" == "${HEAD_NODE}" ]]; then
    ray start --head \
        --port="${PORT}" \
        --dashboard-port="${DASHBOARD_PORT}" \
        --num-cpus="${SLURM_CPUS_PER_TASK}" \
        --num-gpus="${SLURM_GPUS_ON_NODE:-4}" \
        --block &
    HEAD_PID=$!

    sleep 15

    WORKERS=$(scontrol show hostnames "$SLURM_JOB_NODELIST" | tail -n +2)
    for node in ${WORKERS}; do
        srun --nodes=1 --ntasks=1 -w "${node}" \
            ray start --address="${HEAD_NODE}:${PORT}" \
            --num-cpus="${SLURM_CPUS_PER_TASK}" \
            --num-gpus="${SLURM_GPUS_ON_NODE:-4}" &
    done

    export RAY_ADDRESS="${HEAD_NODE}:${PORT}"
    export CHR_RAY_HEAD_HOST="${HEAD_NODE}"
    export CHR_RAY_HEAD_PORT="${PORT}"

    echo "Ray cluster ready at ${RAY_ADDRESS}"
    echo "Dashboard: http://${HEAD_NODE}:${DASHBOARD_PORT}"

    # Run the DoE driver on the head node (override CMD below)
    CMD="${CHR_RAY_DRIVER_CMD:-python doe_amd_fsi.py}"
    cd "${SLURM_SUBMIT_DIR:-$(pwd)}"
    eval "${CMD}"

    ray stop
    wait "${HEAD_PID}" 2>/dev/null || true
else
    sleep infinity
fi
