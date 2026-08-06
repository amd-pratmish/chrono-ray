#!/usr/bin/env bash
# Submit 16-GPU scale run: 2 nodes × 8 MI355X OAM GPUs (rad partition).
set -euo pipefail

EX4="/home/pratmish/chrono-ray/ex4-amd-multinode-fsi-doe"
mkdir -p "${EX4}/logs"

JOB_ID=$(sbatch \
  --job-name=chr-doe-16gpu \
  --partition=rad \
  --nodes=2 \
  --gres=gpu:amd_instinct_mi355_oam:8 \
  --time=02:00:00 \
  --export=ALL,CHR_RAY_SCALE=16,CHR_RAY_GPUS_PER_NODE=8 \
  "${EX4}/launch_doe_scale.sbatch" | awk '{print $NF}')

echo "Submitted 16-GPU DoE: job ${JOB_ID}"
echo "  2 nodes × 8 GPUs = 16 GPUs"
echo "  48 trials, max 16 concurrent"
echo "  Monitor: squeue -j ${JOB_ID}"
echo "  Logs:    ${EX4}/logs/scale_chr-doe-16gpu_${JOB_ID}.out"
