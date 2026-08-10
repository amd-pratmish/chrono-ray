#!/usr/bin/env bash
#SBATCH --job-name=ex5-chain-mi350x
#SBATCH --partition=mi350x-es
#SBATCH --gres=gpu:amd_instinct_mi350_oam:1
#SBATCH --time=00:10:00
#SBATCH --output=/shared/%u/amd_chronos_results/phase3/ex5_radha_scaling/logs/chain_submit_mi350x_%j.out
#SBATCH --error=/shared/%u/amd_chronos_results/phase3/ex5_radha_scaling/logs/chain_submit_mi350x_%j.err

bash /shared/${USER}/src/chrono-ray-amd/ex5-radha-gpu-scaling/submit_ladder_chain_mi350x.sh
