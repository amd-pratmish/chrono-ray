#!/usr/bin/env bash
# Submit ex5 coupled simulation job.
#   bash submit_coupled.sh [smoke|synchrono]
set -euo pipefail

EX5="/home/pratmish/chrono-ray/ex5-synchrono-ray-coupled"
MODE="${1:-smoke}"
mkdir -p "${EX5}/logs"

export CHR_RAY_MODE="${MODE}"

JOB_ID=$(sbatch \
  --export=ALL,CHR_RAY_MODE="${MODE}" \
  "${EX5}/launch_coupled.sbatch" | awk '{print $NF}')

echo "Submitted ex5 coupled (${MODE}): job ${JOB_ID}"
echo "  Log: ${EX5}/logs/coupled_chr-coupled_${JOB_ID}.out"
