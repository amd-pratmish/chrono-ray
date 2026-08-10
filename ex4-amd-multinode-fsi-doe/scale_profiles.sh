#!/usr/bin/env bash
# Scale profiles: 1 → 2 → 8 → 16 → 24 → 32 → 64 → 72 → 96 → 128 GPUs
# Large tiers try lux then rad-burst (vultr_rad cannot use lux; rad-burst is fallback).

apply_scale_profile() {
  local SCALE="$1"
  export CHR_RAY_SCALE="${SCALE}"
  unset CHR_RAY_QOS CHR_RAY_PARTITION_CANDIDATES

  case "${SCALE}" in
    1)
      export CHR_RAY_NODES=1
      export CHR_RAY_GPUS_PER_NODE=1
      export CHR_RAY_NUM_TRIALS=2
      export CHR_RAY_MAX_CONCURRENT=1
      export CHR_RAY_SIM_TEND=0.5
      export CHR_RAY_PARTITION=rad
      export CHR_RAY_TIME=08:00:00
      export CHR_RAY_SMOKE=1
      ;;
    2)
      export CHR_RAY_NODES=1
      export CHR_RAY_GPUS_PER_NODE=2
      export CHR_RAY_NUM_TRIALS=4
      export CHR_RAY_MAX_CONCURRENT=2
      export CHR_RAY_SIM_TEND=0.5
      export CHR_RAY_PARTITION=rad
      export CHR_RAY_TIME=08:00:00
      export CHR_RAY_SMOKE=1
      ;;
    8)
      export CHR_RAY_NODES=1
      export CHR_RAY_GPUS_PER_NODE=8
      export CHR_RAY_NUM_TRIALS=16
      export CHR_RAY_MAX_CONCURRENT=8
      export CHR_RAY_SIM_TEND=1.0
      export CHR_RAY_PARTITION=rad
      export CHR_RAY_TIME=08:00:00
      export CHR_RAY_SMOKE=0
      ;;
    16)
      export CHR_RAY_NODES=2
      export CHR_RAY_GPUS_PER_NODE=8
      export CHR_RAY_NUM_TRIALS=32
      export CHR_RAY_MAX_CONCURRENT=16
      export CHR_RAY_SIM_TEND=1.0
      export CHR_RAY_PARTITION=rad
      export CHR_RAY_TIME=08:00:00
      export CHR_RAY_SMOKE=0
      ;;
    24)
      export CHR_RAY_NODES=3
      export CHR_RAY_GPUS_PER_NODE=8
      export CHR_RAY_NUM_TRIALS=48
      export CHR_RAY_MAX_CONCURRENT=24
      export CHR_RAY_SIM_TEND=1.0
      export CHR_RAY_OUTPUT_FPS=0
      export CHR_RAY_SAVE_PARTICLES=0
      export CHR_RAY_PARTITION=rad
      export CHR_RAY_TIME=02:00:00
      export CHR_RAY_SMOKE=0
      ;;
    32)
      export CHR_RAY_NODES=4
      export CHR_RAY_GPUS_PER_NODE=8
      export CHR_RAY_NUM_TRIALS=64
      export CHR_RAY_MAX_CONCURRENT=32
      export CHR_RAY_SIM_TEND=1.0
      export CHR_RAY_OUTPUT_FPS=0
      export CHR_RAY_SAVE_PARTICLES=0
      export CHR_RAY_PARTITION_CANDIDATES="lux rad-burst"
      export CHR_RAY_PARTITION=rad-burst
      export CHR_RAY_QOS=low
      export CHR_RAY_TIME=08:00:00
      export CHR_RAY_SMOKE=0
      ;;
    64)
      export CHR_RAY_NODES=8
      export CHR_RAY_GPUS_PER_NODE=8
      export CHR_RAY_NUM_TRIALS=128
      export CHR_RAY_MAX_CONCURRENT=64
      export CHR_RAY_SIM_TEND=1.0
      export CHR_RAY_OUTPUT_FPS=0
      export CHR_RAY_SAVE_PARTICLES=0
      export CHR_RAY_PARTITION_CANDIDATES="lux rad-burst"
      export CHR_RAY_PARTITION=rad-burst
      export CHR_RAY_QOS=low
      export CHR_RAY_TIME=08:00:00
      export CHR_RAY_SMOKE=0
      ;;
    72)
      export CHR_RAY_NODES=9
      export CHR_RAY_GPUS_PER_NODE=8
      export CHR_RAY_NUM_TRIALS=144
      export CHR_RAY_MAX_CONCURRENT=72
      export CHR_RAY_SIM_TEND=1.0
      export CHR_RAY_OUTPUT_FPS=0
      export CHR_RAY_SAVE_PARTICLES=0
      export CHR_RAY_PARTITION_CANDIDATES="lux rad-burst"
      export CHR_RAY_PARTITION=rad-burst
      export CHR_RAY_QOS=low
      export CHR_RAY_TIME=08:00:00
      export CHR_RAY_SMOKE=0
      ;;
    96)
      export CHR_RAY_NODES=12
      export CHR_RAY_GPUS_PER_NODE=8
      export CHR_RAY_NUM_TRIALS=192
      export CHR_RAY_MAX_CONCURRENT=96
      export CHR_RAY_SIM_TEND=1.0
      export CHR_RAY_OUTPUT_FPS=0
      export CHR_RAY_SAVE_PARTICLES=0
      export CHR_RAY_PARTITION_CANDIDATES="lux rad-burst"
      export CHR_RAY_PARTITION=rad-burst
      export CHR_RAY_QOS=low
      export CHR_RAY_TIME=08:00:00
      export CHR_RAY_SMOKE=0
      ;;
    128)
      # Cluster max is 12 nodes × 8 GPU = 96; profile kept for policy testing / future capacity.
      export CHR_RAY_NODES=16
      export CHR_RAY_GPUS_PER_NODE=8
      export CHR_RAY_NUM_TRIALS=256
      export CHR_RAY_MAX_CONCURRENT=128
      export CHR_RAY_SIM_TEND=1.0
      export CHR_RAY_OUTPUT_FPS=0
      export CHR_RAY_SAVE_PARTICLES=0
      export CHR_RAY_PARTITION_CANDIDATES="lux rad-burst"
      export CHR_RAY_PARTITION=rad-burst
      export CHR_RAY_QOS=low
      export CHR_RAY_TIME=08:00:00
      export CHR_RAY_SMOKE=0
      ;;
    *)
      echo "Unknown scale: ${SCALE}. Use 1, 2, 8, 16, 24, 32, 64, 72, 96, or 128."
      return 1
      ;;
  esac

  export CHR_RAY_TOTAL_GPUS=$((CHR_RAY_NODES * CHR_RAY_GPUS_PER_NODE))
  export CHR_RAY_GPU_WAIT_SEC=$((CHR_RAY_NODES * 45 + 180))
}
