#!/usr/bin/env bash
# Slurm driver for ex5 Radha GPU scaling (MI350X / MI300X).
# Submit: bash submit_scale.sh mi350x 8

#SBATCH --job-name=ex5-chr-doe
#SBATCH --cpus-per-task=16
#SBATCH --ntasks-per-node=1
#SBATCH --mem=128G
#SBATCH --requeue
#SBATCH --output=/shared/%u/amd_chronos_results/phase3/ex5_radha_scaling/logs/scale_%x_%j.out
#SBATCH --error=/shared/%u/amd_chronos_results/phase3/ex5_radha_scaling/logs/scale_%x_%j.err

set -euo pipefail

source "/shared/${USER}/src/chrono-ray-amd/ex5-radha-gpu-scaling/paths.env"
source "${EX5}/scale_profiles.sh"
source "${EX5}/ray_cluster_env.sh"

SCALE="${CHR_RAY_SCALE:-1}"
PLATFORM="${CHR_RAY_PLATFORM:-mi350x}"
apply_scale_profile "${SCALE}" || { echo "Invalid profile scale=${SCALE} platform=${PLATFORM}"; exit 1; }

mkdir -p "${EX5}/logs" "${RESULTS_ROOT}/${CHR_RAY_RESULTS_TAG}"

module load rocm/7.2.2 2>/dev/null || module load rocm 2>/dev/null || true

echo "=============================================="
echo "ex5 ChronoRay FSI-SPH DoE — ${CHR_RAY_TOTAL_GPUS} GPU (${PLATFORM})"
echo "  Job ID:     ${SLURM_JOB_ID}"
echo "  Scale:      ${SCALE}"
echo "  Nodes:      ${CHR_RAY_NODES} (allocated ${SLURM_NNODES:-?})"
echo "  GPUs/node:  ${CHR_RAY_GPUS_PER_NODE}"
echo "  Partition:  ${SLURM_JOB_PARTITION}"
echo "  Nodelist:   ${SLURM_JOB_NODELIST}"
echo "=============================================="

bash "${EX5}/setup_venv.sh"
# shellcheck source=/dev/null
source "${VENV}/bin/activate"
ray_cluster_env

export ROCR_VISIBLE_DEVICES="${ROCR_VISIBLE_DEVICES:-$(seq -s, 0 $((CHR_RAY_GPUS_PER_NODE - 1)))}"
export HIP_VISIBLE_DEVICES="${HIP_VISIBLE_DEVICES:-${ROCR_VISIBLE_DEVICES}}"

collect_system_info "${RESULTS_ROOT}/${CHR_RAY_RESULTS_TAG}/system_info/job_${SLURM_JOB_ID}.json"

python3 -c "import pychrono.fsi as f; import ray; print('deps ok ray', ray.__version__)"

PORT=6379
WORKER_PIDS=()

if [[ "${CHR_RAY_NODES}" -eq 1 ]]; then
    ray_stop_node
    HEAD_IP=$(cluster_ip)
    [[ -z "${HEAD_IP}" ]] && HEAD_IP=$(hostname -I | awk '{print $1}')
    ray start --head \
        --node-ip-address="${HEAD_IP}" \
        --port="${PORT}" \
        --num-cpus="${SLURM_CPUS_PER_TASK}" \
        --num-gpus="${CHR_RAY_GPUS_PER_NODE}" \
        --disable-usage-stats
    sleep 10
    export RAY_ADDRESS="${HEAD_IP}:${PORT}"
else
    mapfile -t NODES_ARR < <(scontrol show hostnames "${SLURM_JOB_NODELIST}")
    HEAD_NODE="${NODES_ARR[0]}"
    CURRENT_NODE="$(hostname -s)"

    for node in "${NODES_ARR[@]}"; do
        srun --nodes=1 --ntasks=1 -w "${node}" bash -lc "
            source '${EX5}/ray_cluster_env.sh'
            ray_cluster_env
            ray_stop_node
        " || true
    done

    ray_cluster_env
    ray_stop_node
    HEAD_IP=$(cluster_ip)
    [[ -z "${HEAD_IP}" ]] && HEAD_IP=$(hostname -I | awk '{print $1}')
    RAY_ADDR="${HEAD_IP}:${PORT}"

    if [[ "${CURRENT_NODE}" != "${HEAD_NODE}" ]]; then
        echo "ERROR: batch on ${CURRENT_NODE}, expected head ${HEAD_NODE}"
        exit 1
    fi

    ray start --head \
        --node-ip-address="${HEAD_IP}" \
        --port="${PORT}" \
        --num-cpus="${SLURM_CPUS_PER_TASK}" \
        --num-gpus="${CHR_RAY_GPUS_PER_NODE}" \
        --disable-usage-stats
    sleep 15

    for node in "${NODES_ARR[@]:1}"; do
        srun --nodes=1 --ntasks=1 -w "${node}" bash -lc "
            source '${EX5}/ray_cluster_env.sh'
            ray_cluster_env
            export ROCR_VISIBLE_DEVICES=0,1,2,3,4,5,6,7
            export HIP_VISIBLE_DEVICES=\${ROCR_VISIBLE_DEVICES}
            ray_stop_node
            WIP=\$(cluster_ip)
            [[ -z \"\${WIP}\" ]] && WIP=\$(hostname -I | awk '{print \$1}')
            ray start --address='${RAY_ADDR}' \
                --node-ip-address=\"\${WIP}\" \
                --num-cpus='${SLURM_CPUS_PER_TASK}' \
                --num-gpus='${CHR_RAY_GPUS_PER_NODE}' \
                --disable-usage-stats --block
        " &
        WORKER_PIDS+=($!)
        sleep 10
    done
    export RAY_ADDRESS="${RAY_ADDR}"
    ray_wait_for_gpus "${RAY_ADDR}" "${CHR_RAY_TOTAL_GPUS}" "${CHR_RAY_GPU_WAIT_SEC}" \
        "${EX5}/logs/ray_status_${SLURM_JOB_ID}.txt" || true
fi

ray status | tee "${EX5}/logs/ray_status_${SLURM_JOB_ID}.txt"
CLUSTER_GPUS=$(grep -oP '^\s+\d+\.\d+/\K[\d.]+(?=\s+GPU)' "${EX5}/logs/ray_status_${SLURM_JOB_ID}.txt" | tail -1 || echo "0")
echo "Ray cluster GPUs: ${CLUSTER_GPUS} (target ${CHR_RAY_TOTAL_GPUS})"

if [[ -n "${CLUSTER_GPUS}" && "${CLUSTER_GPUS}" != "0" ]]; then
    CHR_RAY_MAX_CONCURRENT=$(python3 -c "print(min(${CHR_RAY_MAX_CONCURRENT}, int(float('${CLUSTER_GPUS}'))))")
fi

RUN_DIR="${RESULTS_ROOT}/${CHR_RAY_RESULTS_TAG}/scale${SCALE}gpu_${SLURM_JOB_ID}"
mkdir -p "${RUN_DIR}"
cd "${RUN_DIR}"

export CHR_RAY_OUTPUT_DIR="${RUN_DIR}"
export CHR_RAY_NUM_TRIALS="${CHR_RAY_NUM_TRIALS}"
export CHR_RAY_MAX_CONCURRENT="${CHR_RAY_MAX_CONCURRENT}"
export CHR_RAY_SIM_TEND="${CHR_RAY_SIM_TEND}"
export CHR_RAY_OUTPUT_FPS="${CHR_RAY_OUTPUT_FPS:-100}"
export CHR_RAY_SAVE_PARTICLES="${CHR_RAY_SAVE_PARTICLES:-1}"

INTERCONNECT_JSON="${RUN_DIR}/interconnect_metrics.json"
python3 "${EX5}/collect_interconnect_metrics.py" "${INTERCONNECT_JSON}" \
    > "${EX5}/logs/interconnect_${SLURM_JOB_ID}.txt" 2>&1 || true

START_TS=$(date +%s)
set +e
python3 -u "${EX5}/doe_amd_fsi.py" 2>&1 | tee doe_run.log
EXIT_CODE=${PIPESTATUS[0]}
set -e
END_TS=$(date +%s)
ELAPSED=$((END_TS - START_TS))

COMPLETED=$(find "${RUN_DIR}/particles" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
DOE_ELAPSED=$(grep -oP 'DoE completed in \K[0-9.]+' "${RUN_DIR}/doe_run.log" 2>/dev/null | head -1 || true)
THROUGHPUT=$(grep -oP 'Throughput:\s+\K[0-9.]+' "${RUN_DIR}/doe_run.log" 2>/dev/null | head -1 || true)
[[ -z "${DOE_ELAPSED}" && "${ELAPSED}" -gt 0 ]] && DOE_ELAPSED="${ELAPSED}"

GPU_HOURS=""
if [[ -n "${DOE_ELAPSED}" && -n "${CLUSTER_GPUS}" ]]; then
    GPU_HOURS=$(python3 -c "print(round(float('${CLUSTER_GPUS}')*float('${DOE_ELAPSED}')/3600,3))")
fi

python3 "${EX5}/aggregate_trial_metrics.py" "${RUN_DIR}" > "${RUN_DIR}/doe_metrics_kv.txt" 2>&1 || true

cat > scale_summary.txt <<EOF
platform=${PLATFORM}
scale_tier=${SCALE}
scale_gpus=${CHR_RAY_TOTAL_GPUS}
max_concurrent=${CHR_RAY_MAX_CONCURRENT}
slurm_job_id=${SLURM_JOB_ID}
partition=${SLURM_JOB_PARTITION}
nodelist=${SLURM_JOB_NODELIST}
trials_requested=${CHR_RAY_NUM_TRIALS}
trials_completed_dirs=${COMPLETED}
ray_gpus_registered=${CLUSTER_GPUS}
wall_elapsed_s=${ELAPSED}
doe_elapsed_s=${DOE_ELAPSED}
throughput_trials_per_hr=${THROUGHPUT}
gpu_hours=${GPU_HOURS}
exit_code=${EXIT_CODE}
EOF

# Merge interconnect + trial aggregate metrics (coupled-workload compatible keys)
python3 - <<PY
import json
from pathlib import Path

run = Path("${RUN_DIR}")
summary = run / "scale_summary.txt"
lines = summary.read_text().splitlines() if summary.is_file() else []

def merge_kv(path):
    if not path.is_file():
        return
    if path.suffix == ".json":
        data = json.loads(path.read_text())
        for k, v in data.items():
            if isinstance(v, (dict, list)):
                continue
            lines.append(f"{k}={v}")
    else:
        for ln in path.read_text().splitlines():
            if "=" in ln and not ln.startswith("#"):
                lines.append(ln.strip())

merge_kv(run / "interconnect_metrics.json")
merge_kv(run / "doe_metrics.json")
summary.write_text("\\n".join(lines) + "\\n")
PY

cp scale_summary.txt "${RESULTS_ROOT}/${CHR_RAY_RESULTS_TAG}/"
python3 "${EX5}/measure_scale_performance.py" --platform "${PLATFORM}" 2>&1 | tee -a "${EX5}/logs/perf_${PLATFORM}_${SLURM_JOB_ID}.log" || true

if [[ "${CHR_RAY_NODES}" -gt 1 ]]; then
    for pid in "${WORKER_PIDS[@]:-}"; do kill "${pid}" 2>/dev/null || true; done
    for node in $(scontrol show hostnames "${SLURM_JOB_NODELIST}"); do
        srun --nodes=1 --ntasks=1 -w "${node}" bash -lc "
            source '${EX5}/ray_cluster_env.sh'; ray_cluster_env; ray_stop_node
        " 2>/dev/null || true
    done
else
    ray_stop_node
fi

exit "${EXIT_CODE}"
