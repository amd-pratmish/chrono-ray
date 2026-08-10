#!/usr/bin/env bash
#SBATCH --job-name=ex5-chain-mi300x
#SBATCH --partition=mi300x
#SBATCH --gres=gpu:mi300:1
#SBATCH --time=00:10:00
#SBATCH --output=/shared/%u/amd_chronos_results/phase3/ex5_radha_scaling/logs/chain_submit_mi300x_%j.out
#SBATCH --error=/shared/%u/amd_chronos_results/phase3/ex5_radha_scaling/logs/chain_submit_mi300x_%j.err

bash /shared/${USER}/src/chrono-ray-amd/ex5-radha-gpu-scaling/submit_ladder_chain_mi300x.sh "${SETUP_JOB_ID:-}"
