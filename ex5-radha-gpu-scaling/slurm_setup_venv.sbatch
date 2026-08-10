#!/usr/bin/env bash
#SBATCH --job-name=ex5-setup
#SBATCH --output=/shared/%u/amd_chronos_results/phase3/ex5_radha_scaling/logs/setup_%j.out
#SBATCH --error=/shared/%u/amd_chronos_results/phase3/ex5_radha_scaling/logs/setup_%j.err
#SBATCH --partition=mi350x-es
#SBATCH --gres=gpu:amd_instinct_mi350_oam:1
#SBATCH --time=01:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=1

set -euo pipefail
EX5="/shared/${USER}/src/chrono-ray-amd/ex5-radha-gpu-scaling"
bash "${EX5}/setup_venv.sh"
bash "${EX5}/collect_system_info.sh" || true
