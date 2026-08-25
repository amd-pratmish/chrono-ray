#!/usr/bin/env bash
# AMD MI355X cluster (rad / rad-burst) — current production profile.

export CHR_CLUSTER_NAME="rad_mi355x"
export CHR_SLURM_ACCOUNT="${CHR_SLURM_ACCOUNT:-vultr_rad}"
export CHR_SLURM_GRES_GPU="${CHR_SLURM_GRES_GPU:-gpu:amd_instinct_mi355_oam:1}"

export CHR_SLURM_MEM="${CHR_SLURM_MEM:-256G}"

export CHR_PYCHRONO_BIN="${CHR_PYCHRONO_BIN:-/home/pratmish/amd-chronos/build-mi355x/bin}"
export CHR_PYCHRONO_READY="${CHR_PYCHRONO_READY:-/home/pratmish/amd-chronos/build-mi355x/.pychrono_ready}"

export CHR_MPI_RANKS_PER_NODE="${CHR_MPI_RANKS_PER_NODE:-8}"
export CHR_SRUN_MPI="${CHR_SRUN_MPI:-pmix}"
export CHR_SRUN_EXTRA="${CHR_SRUN_EXTRA:---overlap}"

# Partition policy: tiers ≤24 on rad (3 nodes max); 32+ on rad-burst
export CHR_RAY_PARTITION_SMALL="${CHR_RAY_PARTITION_SMALL:-rad}"
export CHR_RAY_PARTITION_LARGE="${CHR_RAY_PARTITION_LARGE:-rad-burst}"
export CHR_RAY_PARTITION_LARGE_FALLBACK="${CHR_RAY_PARTITION_LARGE_FALLBACK:-lux}"
export CHR_RAY_QOS_LARGE="${CHR_RAY_QOS_LARGE:-low}"
export CHR_RAY_SMALL_TIER_MAX="${CHR_RAY_SMALL_TIER_MAX:-24}"
export CHR_RAY_TIME_SMALL="${CHR_RAY_TIME_SMALL:-02:00:00}"
export CHR_RAY_TIME_MED="${CHR_RAY_TIME_MED:-04:00:00}"
export CHR_RAY_TIME_LARGE="${CHR_RAY_TIME_LARGE:-08:00:00}"

# Cluster capacity: 12 nodes × 8 MPI ranks/node → tier 96 max on this cluster
export CHR_RAY_MAX_NODES="${CHR_RAY_MAX_NODES:-12}"
export CHR_COUPLED_MAX_TIER="${CHR_COUPLED_MAX_TIER:-96}"
export CHR_SLURM_MEM_MED="${CHR_SLURM_MEM_MED:-512G}"
export CHR_SLURM_MEM_LARGE="${CHR_SLURM_MEM_LARGE:-512G}"

# Resume ex4 96-GPU ladder after coupled ladder (same cluster only)
export CHR_RESUME_EX4_AFTER_LADDER="${CHR_RESUME_EX4_AFTER_LADDER:-1}"
