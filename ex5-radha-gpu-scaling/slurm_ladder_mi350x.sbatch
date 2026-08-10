#!/usr/bin/env bash
#SBATCH --job-name=ex5-ladder-mi350x
#SBATCH --output=/shared/%u/amd_chronos_results/phase3/ex5_radha_scaling/logs/ladder_mi350x_%j.out
#SBATCH --error=/shared/%u/amd_chronos_results/phase3/ex5_radha_scaling/logs/ladder_mi350x_%j.err
#SBATCH --partition=mi350x-es
#SBATCH --gres=gpu:amd_instinct_mi350_oam:1
#SBATCH --time=24:00:00
#SBATCH --nodes=1

set -euo pipefail
bash /shared/${USER}/src/chrono-ray-amd/ex5-radha-gpu-scaling/run_ladder_mi350x.sh
