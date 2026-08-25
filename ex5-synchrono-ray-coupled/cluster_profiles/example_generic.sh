#!/usr/bin/env bash
# Template cluster profile — copy to mycluster.sh and customize.
#
#   cp cluster_profiles/example_generic.sh cluster_profiles/nvidia_h100.sh
#   export CHR_CLUSTER=nvidia_h100
#   source cluster_profiles/load_cluster.sh

export CHR_CLUSTER_NAME="example_generic"

# --- Slurm ---
export CHR_SLURM_ACCOUNT="${CHR_SLURM_ACCOUNT:-your_account}"
export CHR_SLURM_GRES_GPU="${CHR_SLURM_GRES_GPU:-gpu:1}"   # e.g. gpu:h100:1 or gpu:1
export CHR_SLURM_MEM="${CHR_SLURM_MEM:-128G}"

# --- PyChrono GPU build (must exist on compute nodes) ---
export CHR_PYCHRONO_BIN="${CHR_PYCHRONO_BIN:-/path/to/build-mi355x/bin}"
export CHR_PYCHRONO_READY="${CHR_PYCHRONO_READY:-${CHR_PYCHRONO_BIN}/../.pychrono_ready}"

# --- MPI / node layout ---
# MPI ranks per Slurm node for coupled tier node count: nodes = ceil(ranks / RANKS_PER_NODE)
export CHR_MPI_RANKS_PER_NODE="${CHR_MPI_RANKS_PER_NODE:-8}"
export CHR_SRUN_MPI="${CHR_SRUN_MPI:-pmix}"              # try pmix, pmi2, or none
export CHR_SRUN_EXTRA="${CHR_SRUN_EXTRA:---overlap}"

# --- Partitions (tier ≤ SMALL_TIER_MAX uses PARTITION_SMALL) ---
export CHR_RAY_PARTITION_SMALL="${CHR_RAY_PARTITION_SMALL:-gpu}"
export CHR_RAY_PARTITION_LARGE="${CHR_RAY_PARTITION_LARGE:-gpu-large}"
export CHR_RAY_PARTITION_LARGE_FALLBACK="${CHR_RAY_PARTITION_LARGE_FALLBACK:-}"
export CHR_RAY_QOS_LARGE="${CHR_RAY_QOS_LARGE:-}"
export CHR_RAY_SMALL_TIER_MAX="${CHR_RAY_SMALL_TIER_MAX:-24}"
export CHR_RAY_TIME_SMALL="${CHR_RAY_TIME_SMALL:-02:00:00}"
export CHR_RAY_TIME_LARGE="${CHR_RAY_TIME_LARGE:-04:00:00}"

# Set 0 on comparison clusters (no ex4 FSI resume)
export CHR_RESUME_EX4_AFTER_LADDER="${CHR_RESUME_EX4_AFTER_LADDER:-0}"
