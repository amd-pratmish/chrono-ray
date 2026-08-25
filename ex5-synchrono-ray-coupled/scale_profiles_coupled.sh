#!/usr/bin/env bash
# Coupled (SynChrono/MPI) scale profiles — mirrors ex4 GPU ladder tiers.
# Scale tier N → N MPI ranks per trial (min 2), 2×N trials, max_concurrent=1.

apply_coupled_scale_profile() {
  local SCALE="$1"
  export CHR_COUPLED_SCALE="${SCALE}"
  unset CHR_RAY_PARTITION CHR_RAY_QOS CHR_RAY_PARTITION_CANDIDATES

  local ppn="${CHR_MPI_RANKS_PER_NODE:-8}"
  local multi_gpu="${CHR_RAY_MULTI_GPU_CONCURRENT:-0}"

  # Multi-GPU throughput mode: 1 node, N GPUs, many short 2-rank trials in parallel.
  if [[ "${multi_gpu}" == "1" && "${SCALE}" -le "${ppn}" ]]; then
    export CHR_RAY_NODES=1
    export CHR_RAY_GPUS_PER_NODE="${SCALE}"
    export CHR_MPI_RANKS=2
    export CHR_RAY_MAX_CONCURRENT="${SCALE}"
    export CHR_RAY_NUM_TRIALS=$((2 * SCALE))
    export CHR_SLURM_NTASKS=$((SCALE * CHR_MPI_RANKS))
    export CHR_SLURM_NTASKS_PER_NODE="${CHR_SLURM_NTASKS}"
    export CHR_SLURM_GRES_GPU="gpu:amd_instinct_mi355_oam:${SCALE}"
    export CHR_SRUN_DISTRIBUTION=""
    export CHR_SRUN_NTASKS_PER_NODE=""
    export CHR_SRUN_GRES_GPU=1
  else
    # Width mode: N MPI ranks per trial spanning N/ppn nodes (multi-node coupled sim).
    export CHR_MPI_RANKS=$((SCALE >= 2 ? SCALE : 2))
    export CHR_RAY_NUM_TRIALS=$((2 * SCALE))
    [[ "${SCALE}" -lt 2 ]] && export CHR_RAY_NUM_TRIALS=2

    local ranks="${CHR_MPI_RANKS}"
    export CHR_RAY_NODES=$(( (ranks + ppn - 1) / ppn ))
    [[ "${CHR_RAY_NODES}" -lt 1 ]] && export CHR_RAY_NODES=1

    local max_nodes="${CHR_RAY_MAX_NODES:-128}"
    if [[ "${CHR_RAY_NODES}" -gt "${max_nodes}" ]]; then
      echo "ERROR: tier ${SCALE} needs ${CHR_RAY_NODES} nodes; cluster max is ${max_nodes}" >&2
      return 1
    fi

    export CHR_RAY_GPUS_PER_NODE=1
    export CHR_RAY_MAX_CONCURRENT=1
    export CHR_SRUN_GRES_GPU=0
    export CHR_SLURM_NTASKS="${CHR_MPI_RANKS}"
    export CHR_SLURM_NTASKS_PER_NODE=$(( (CHR_MPI_RANKS + CHR_RAY_NODES - 1) / CHR_RAY_NODES ))
    [[ "${CHR_SLURM_NTASKS_PER_NODE}" -gt "${ppn}" ]] && export CHR_SLURM_NTASKS_PER_NODE="${ppn}"
    [[ "${CHR_SLURM_NTASKS_PER_NODE}" -lt 1 ]] && export CHR_SLURM_NTASKS_PER_NODE=1
    export CHR_SRUN_DISTRIBUTION="block"
    export CHR_SRUN_NTASKS_PER_NODE="${CHR_SLURM_NTASKS_PER_NODE}"
    export CHR_SLURM_GRES_GPU="${CHR_SLURM_GRES_GPU:-gpu:amd_instinct_mi355_oam:1}"
  fi

  export CHR_MPI_CPUS_PER_RANK="${CHR_MPI_CPUS_PER_RANK:-2}"

  export CHR_RAY_SIM_STEPS="${CHR_RAY_SIM_STEPS:-400}"
  export CHR_RAY_SIM_HEARTBEAT="${CHR_RAY_SIM_HEARTBEAT:-10}"
  export CHR_RAY_PAYLOAD_KB="${CHR_RAY_PAYLOAD_KB:-128}"

  export CHR_RAY_CPUS_PER_TASK=16

  # Walltime: ~15–20 min/trial observed with metrics instrumentation; scale with trial count.
  local small_max="${CHR_RAY_SMALL_TIER_MAX:-24}"
  local trial_min=18
  local wall_min=$((trial_min * CHR_RAY_NUM_TRIALS + 45))
  [[ "${wall_min}" -lt 120 ]] && wall_min=120
  if [[ "${SCALE}" -le "${small_max}" ]]; then
    export CHR_RAY_PARTITION="${CHR_RAY_PARTITION_SMALL:-rad}"
    export CHR_RAY_TIME="${CHR_RAY_TIME_SMALL:-02:00:00}"
    unset CHR_RAY_QOS
  else
    export CHR_RAY_PARTITION="${CHR_RAY_PARTITION_LARGE:-rad-burst}"
    export CHR_RAY_QOS="${CHR_RAY_QOS_LARGE:-low}"
    [[ "${wall_min}" -gt 480 ]] && wall_min=480
    export CHR_RAY_TIME="${CHR_RAY_TIME_LARGE:-08:00:00}"
    [[ -n "${CHR_RAY_PARTITION_LARGE_FALLBACK:-}" ]] && \
      export CHR_RAY_PARTITION_CANDIDATES="${CHR_RAY_PARTITION_LARGE} ${CHR_RAY_PARTITION_LARGE_FALLBACK}"
  fi
  # If computed need exceeds profile cap, use profile (Slurm partition limit).
  export CHR_RAY_WALL_MIN_EST="${wall_min}"

  # Memory per node (PyChrono GPU rank + MPI workers on multi-node tiers).
  if [[ "${multi_gpu}" == "1" ]]; then
    export CHR_SLURM_MEM_PER_NODE="${CHR_SLURM_MEM:-512G}"
  elif [[ "${SCALE}" -le 8 ]]; then
    export CHR_SLURM_MEM_PER_NODE="${CHR_SLURM_MEM:-256G}"
  elif [[ "${SCALE}" -le 24 ]]; then
    export CHR_SLURM_MEM_PER_NODE="${CHR_SLURM_MEM_MED:-384G}"
  else
    export CHR_SLURM_MEM_PER_NODE="${CHR_SLURM_MEM_LARGE:-512G}"
  fi
  export CHR_SLURM_USE_MEM_PER_NODE=1

  export CHR_RAY_TOTAL_RANKS="${CHR_MPI_RANKS}"
}

# Full ladder; cluster profile may cap via CHR_COUPLED_MAX_TIER (e.g. 96 on rad_mi355x)
COUPLED_LADDER=(1 2 4 8 16 24 32 64 72 96 128)

coupled_ladder_for_cluster() {
  local max_tier="${CHR_COUPLED_MAX_TIER:-128}"
  local tier
  COUPLED_LADDER_ACTIVE=()
  for tier in "${COUPLED_LADDER[@]}"; do
    if [[ "${tier}" -le "${max_tier}" ]]; then
      COUPLED_LADDER_ACTIVE+=("${tier}")
    fi
  done
}
