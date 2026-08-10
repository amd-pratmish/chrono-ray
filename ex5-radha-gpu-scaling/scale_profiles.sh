#!/usr/bin/env bash
# ex5 scale profiles for Radha MI350X (mi350x-es) and MI300X (mi300x).
# Tiers: 1, 2, 4, 8, 16 on local Radha; MI300X extended tiers need more nodes (max 2 local = 16 GPU).

apply_scale_profile() {
    local SCALE="$1"
    local PLATFORM="${CHR_RAY_PLATFORM:-mi350x}"

    export CHR_RAY_SCALE="${SCALE}"
    unset CHR_RAY_PARTITION CHR_RAY_GRES CHR_RAY_CLUSTER CHR_RAY_HIP_ARCH CHR_RAY_RESULTS_TAG

    case "${PLATFORM}" in
        mi350x)
            export CHR_RAY_PARTITION=mi350x-es
            export CHR_RAY_GRES=gpu:amd_instinct_mi350_oam
            export CHR_RAY_HIP_ARCH=gfx950
            export CHR_RAY_RESULTS_TAG=mi350x
            export CHR_RAY_MAX_NODES=2
            ;;
        mi300x)
            export CHR_RAY_PARTITION=mi300x
            export CHR_RAY_GRES=gpu:mi300
            export CHR_RAY_HIP_ARCH=gfx942
            export CHR_RAY_RESULTS_TAG=mi300x
            export CHR_RAY_MAX_NODES=2
            ;;
        *)
            echo "Unknown platform: ${PLATFORM}" >&2
            return 1
            ;;
    esac

    case "${SCALE}" in
        1)
            export CHR_RAY_NODES=1
            export CHR_RAY_GPUS_PER_NODE=1
            export CHR_RAY_NUM_TRIALS=2
            export CHR_RAY_MAX_CONCURRENT=1
            export CHR_RAY_SIM_TEND=0.5
            export CHR_RAY_TIME=04:00:00
            [[ "${PLATFORM}" == "mi300x" ]] && export CHR_RAY_TIME=02:00:00
            export CHR_RAY_SMOKE=1
            ;;
        2)
            export CHR_RAY_NODES=1
            export CHR_RAY_GPUS_PER_NODE=2
            export CHR_RAY_NUM_TRIALS=4
            export CHR_RAY_MAX_CONCURRENT=2
            export CHR_RAY_SIM_TEND=0.5
            export CHR_RAY_TIME=04:00:00
            [[ "${PLATFORM}" == "mi300x" ]] && export CHR_RAY_TIME=02:00:00
            export CHR_RAY_SMOKE=1
            ;;
        4)
            export CHR_RAY_NODES=1
            export CHR_RAY_GPUS_PER_NODE=4
            export CHR_RAY_NUM_TRIALS=8
            export CHR_RAY_MAX_CONCURRENT=4
            export CHR_RAY_SIM_TEND=0.5
            export CHR_RAY_TIME=04:00:00
            [[ "${PLATFORM}" == "mi300x" ]] && export CHR_RAY_TIME=02:00:00
            export CHR_RAY_SMOKE=1
            ;;
        8)
            export CHR_RAY_NODES=1
            export CHR_RAY_GPUS_PER_NODE=8
            export CHR_RAY_NUM_TRIALS=16
            export CHR_RAY_MAX_CONCURRENT=8
            export CHR_RAY_SIM_TEND=1.0
            export CHR_RAY_TIME=06:00:00
            [[ "${PLATFORM}" == "mi300x" ]] && export CHR_RAY_TIME=02:00:00
            export CHR_RAY_SMOKE=0
            export CHR_RAY_OUTPUT_FPS=0
            export CHR_RAY_SAVE_PARTICLES=0
            ;;
        16)
            export CHR_RAY_NODES=2
            export CHR_RAY_GPUS_PER_NODE=8
            export CHR_RAY_NUM_TRIALS=32
            export CHR_RAY_MAX_CONCURRENT=16
            export CHR_RAY_SIM_TEND=1.0
            export CHR_RAY_TIME=06:00:00
            [[ "${PLATFORM}" == "mi300x" ]] && export CHR_RAY_TIME=02:00:00
            export CHR_RAY_SMOKE=0
            export CHR_RAY_OUTPUT_FPS=0
            export CHR_RAY_SAVE_PARTICLES=0
            ;;
        24|32|64)
            # Requires >2 nodes on Radha — will fail submit unless capacity exists.
            local nodes=$(( (SCALE + 7) / 8 ))
            export CHR_RAY_NODES="${nodes}"
            export CHR_RAY_GPUS_PER_NODE=8
            export CHR_RAY_NUM_TRIALS=$((SCALE * 2))
            export CHR_RAY_MAX_CONCURRENT="${SCALE}"
            export CHR_RAY_SIM_TEND=1.0
            export CHR_RAY_TIME=08:00:00
            export CHR_RAY_SMOKE=0
            export CHR_RAY_OUTPUT_FPS=0
            export CHR_RAY_SAVE_PARTICLES=0
            ;;
        *)
            echo "Unknown scale ${SCALE}. Use 1,2,4,8,16[,24,32,64]." >&2
            return 1
            ;;
    esac

    if [[ "${CHR_RAY_NODES}" -gt "${CHR_RAY_MAX_NODES}" ]]; then
        echo "Scale ${SCALE} needs ${CHR_RAY_NODES} nodes; Radha ${PLATFORM} has max ${CHR_RAY_MAX_NODES}." >&2
        return 2
    fi

    export CHR_RAY_TOTAL_GPUS=$((CHR_RAY_NODES * CHR_RAY_GPUS_PER_NODE))
    export CHR_RAY_GPU_WAIT_SEC=$((CHR_RAY_NODES * 45 + 180))
}
