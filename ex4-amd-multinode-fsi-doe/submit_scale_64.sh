#!/usr/bin/env bash
# Submit 64-GPU scale run: 8 nodes × 8 MI355X OAM GPUs (lux partition).
set -euo pipefail

EX4="/home/pratmish/chrono-ray/ex4-amd-multinode-fsi-doe"
mkdir -p "${EX4}/logs"

JOB_ID=$(sbatch \
  --job-name=chr-doe-64gpu \
  --partition=lux \
  --nodes=8 \
  --gres=gpu:amd_instinct_mi355_oam:8 \
  --time=04:00:00 \
  --export=ALL,CHR_RAY_SCALE=64,CHR_RAY_GPUS_PER_NODE=8 \
  "${EX4}/launch_doe_scale.sbatch" | awk '{print $NF}')

echo "Submitted 64-GPU DoE: job ${JOB_ID}"
echo "  8 nodes × 8 GPUs = 64 GPUs"
echo "  192 trials, max 64 concurrent"
echo "  Monitor: squeue -j ${JOB_ID}"
echo "  Logs:    ${EX4}/logs/scale_chr-doe-64gpu_${JOB_ID}.out"
