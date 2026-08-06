#!/usr/bin/env bash
# Slurm driver — supports 1, 2, 8, 16, 64 GPU scale profiles.
# Submit via: bash submit_scale.sh 1

#SBATCH --job-name=chr-doe-amd
#SBATCH --account=vultr_rad
#SBATCH --cpus-per-task=16
#SBATCH --ntasks-per-node=1
#SBATCH --mem=256G
#SBATCH --requeue
#SBATCH --output=/home/pratmish/chrono-ray/ex4-amd-multinode-fsi-doe/logs/scale_%x_%j.out
#SBATCH --error=/home/pratmish/chrono-ray/ex4-amd-multinode-fsi-doe/logs/scale_%x_%j.err

set -euo pipefail

EX4="/home/pratmish/chrono-ray/ex4-amd-multinode-fsi-doe"
VENV="/home/pratmish/chrono-ray/.venv"
BUILD="/home/pratmish/amd-chronos/build-mi355x"
PY_BIN="${BUILD}/bin"
LOG_DIR="${EX4}/logs"
RESULTS_DIR="${EX4}/results"

source "${EX4}/scale_profiles.sh"

SCALE="${CHR_RAY_SCALE:-1}"
apply_scale_profile "${SCALE}"

mkdir -p "${LOG_DIR}" "${RESULTS_DIR}"

echo "=============================================="
echo "ChronoRay FSI-SPH DoE — ${CHR_RAY_TOTAL_GPUS} GPU scale run"
echo "  Job ID:         ${SLURM_JOB_ID}"
echo "  Scale tier:     ${SCALE}"
echo "  Nodes:          ${CHR_RAY_NODES} (${SLURM_NNODES:-?} allocated)"
echo "  GPUs/node:      ${CHR_RAY_GPUS_PER_NODE}"
echo "  Total GPUs:     ${CHR_RAY_TOTAL_GPUS}"
echo "  Trials:         ${CHR_RAY_NUM_TRIALS}"
echo "  Max concurrent: ${CHR_RAY_MAX_CONCURRENT}"
echo "  Sim t_end:      ${CHR_RAY_SIM_TEND}s"
echo "  Partition:      ${SLURM_JOB_PARTITION}"
echo "  Node list:      ${SLURM_JOB_NODELIST}"
echo "=============================================="

export HSA_XNACK=0
export HIP_LAUNCH_BLOCKING=0
export GPU_MAX_HW_QUEUES=4
export PATH="/home/pratmish/micromamba/envs/build-tools/bin:/opt/rocm/bin:${PATH}"

source "${VENV}/bin/activate"
export PYTHONPATH="/home/pratmish/chrono-ray:${EX4}:${PY_BIN}:${PYTHONPATH:-}"

if [[ ! -f "${BUILD}/.pychrono_ready" ]]; then
  bash "${EX4}/setup_pychrono_amd.sh"
fi
export PYTHONPATH="${PY_BIN}:${PYTHONPATH}"

python3 -c "import pychrono.fsi as f; import ray; print('deps ok — ray', ray.__version__)"

# --- Ray cluster ---
source "${EX4}/ray_cluster_env.sh"
PORT=6379

if [[ "${CHR_RAY_NODES}" -eq 1 ]]; then
  # Single-node: local Ray head only (1, 2, or 8 GPUs)
  ray_cluster_env
  ray_stop_node
  HEAD_IP=$(cluster_ip)
  [[ -z "${HEAD_IP}" ]] && HEAD_IP=$(hostname -I | awk '{print $1}')
  echo "Single-node Ray on ${HEAD_IP} with ${CHR_RAY_GPUS_PER_NODE} GPUs"

  ray start --head \
    --node-ip-address="${HEAD_IP}" \
    --port="${PORT}" \
    --num-cpus="${SLURM_CPUS_PER_TASK}" \
    --num-gpus="${CHR_RAY_GPUS_PER_NODE}" \
    --disable-usage-stats
  sleep 10
  export RAY_ADDRESS="${HEAD_IP}:${PORT}"
else
  # Multi-node: head on batch node (Slurm runs script on first allocated node),
  # workers via srun --block in background so Ray processes stay in the job cgroup.
  mapfile -t NODES_ARR < <(scontrol show hostnames "${SLURM_JOB_NODELIST}")
  HEAD_NODE="${NODES_ARR[0]}"
  CURRENT_NODE="$(hostname -s)"

  echo "Stopping stale Ray processes on all nodes..."
  for node in "${NODES_ARR[@]}"; do
    srun --nodes=1 --ntasks=1 -w "${node}" bash -lc "
      source '${EX4}/ray_cluster_env.sh'
      ray_cluster_env
      ray_stop_node
    " || true
  done

  ray_cluster_env
  ray_stop_node
  HEAD_IP=$(cluster_ip)
  [[ -z "${HEAD_IP}" ]] && HEAD_IP=$(hostname -I | awk '{print $1}')
  RAY_ADDR="${HEAD_IP}:${PORT}"
  echo "Multi-node Ray head: ${HEAD_NODE} (${CURRENT_NODE}) at ${RAY_ADDR}"

  if [[ "${CURRENT_NODE}" != "${HEAD_NODE}" ]]; then
    echo "ERROR: batch script on ${CURRENT_NODE}, expected head ${HEAD_NODE}"
    exit 1
  fi

  ray start --head \
    --node-ip-address="${HEAD_IP}" \
    --port="${PORT}" \
    --num-cpus="${SLURM_CPUS_PER_TASK}" \
    --num-gpus="${CHR_RAY_GPUS_PER_NODE}" \
    --disable-usage-stats
  sleep 15

  WORKER_PIDS=()
  for node in "${NODES_ARR[@]:1}"; do
    echo "Starting Ray worker on ${node} (background srun --block)..."
    for attempt in 1 2 3; do
      srun --nodes=1 --ntasks=1 -w "${node}" bash -lc "
        source '${EX4}/ray_cluster_env.sh'
        ray_cluster_env
        ray_stop_node
        WORKER_IP=\$(cluster_ip)
        [[ -z \"\${WORKER_IP}\" ]] && WORKER_IP=\$(hostname -I | awk '{print \$1}')
        ray start --address='${RAY_ADDR}' \
          --node-ip-address=\"\${WORKER_IP}\" \
          --num-cpus='${SLURM_CPUS_PER_TASK}' \
          --num-gpus='${CHR_RAY_GPUS_PER_NODE}' \
          --disable-usage-stats --block
      " &
      WORKER_PIDS+=($!)
      sleep 10
      break
    done
  done

  export RAY_ADDRESS="${RAY_ADDR}"
  echo "Waiting for ${CHR_RAY_TOTAL_GPUS} GPUs to register (timeout ${CHR_RAY_GPU_WAIT_SEC}s)..."
  CLUSTER_GPUS=$(ray_wait_for_gpus "${RAY_ADDR}" "${CHR_RAY_TOTAL_GPUS}" "${CHR_RAY_GPU_WAIT_SEC}" "${LOG_DIR}/ray_status_${SLURM_JOB_ID}.txt" || true)
  if [[ -z "${CLUSTER_GPUS}" || "${CLUSTER_GPUS}" -lt "${CHR_RAY_TOTAL_GPUS}" ]]; then
    echo "WARN: only ${CLUSTER_GPUS:-0}/${CHR_RAY_TOTAL_GPUS} GPUs registered; continuing with available GPUs"
    RAY_ADDRESS="${RAY_ADDR}" ray status | tee "${LOG_DIR}/ray_status_${SLURM_JOB_ID}.txt" || true
    CLUSTER_GPUS=$(grep -oP '^\s+\d+\.\d+/\K[\d.]+(?=\s+GPU)' "${LOG_DIR}/ray_status_${SLURM_JOB_ID}.txt" | tail -1 || echo "0")
  else
    RAY_ADDRESS="${RAY_ADDR}" ray status | tee "${LOG_DIR}/ray_status_${SLURM_JOB_ID}.txt"
  fi
fi

if [[ "${CHR_RAY_NODES}" -eq 1 ]]; then
  ray status | tee "${LOG_DIR}/ray_status_${SLURM_JOB_ID}.txt"
fi

CLUSTER_GPUS=$(grep -oP '^\s+\d+\.\d+/\K[\d.]+(?=\s+GPU)' "${LOG_DIR}/ray_status_${SLURM_JOB_ID}.txt" | tail -1 || echo "0")
echo "Ray cluster GPUs: ${CLUSTER_GPUS} (target: ${CHR_RAY_TOTAL_GPUS})"

if [[ -n "${CLUSTER_GPUS}" ]] && [[ "${CLUSTER_GPUS}" != "0" ]]; then
  CHR_RAY_MAX_CONCURRENT=$("${VENV}/bin/python3" -c "print(min(${CHR_RAY_MAX_CONCURRENT}, int(float('${CLUSTER_GPUS}'))))")
  echo "Adjusted max_concurrent to ${CHR_RAY_MAX_CONCURRENT}"
fi

# --- DoE ---
RUN_DIR="${RESULTS_DIR}/scale${SCALE}gpu_${SLURM_JOB_ID}"
mkdir -p "${RUN_DIR}"
cd "${RUN_DIR}"

export CHR_RAY_OUTPUT_DIR="${RUN_DIR}"
export CHR_RAY_SCALE="${SCALE}"
export CHR_RAY_NUM_TRIALS="${CHR_RAY_NUM_TRIALS}"
export CHR_RAY_MAX_CONCURRENT="${CHR_RAY_MAX_CONCURRENT}"
export CHR_RAY_SIM_TEND="${CHR_RAY_SIM_TEND}"
export CHR_RAY_OUTPUT_FPS="${CHR_RAY_OUTPUT_FPS:-100}"
export CHR_RAY_SAVE_PARTICLES="${CHR_RAY_SAVE_PARTICLES:-1}"
START_TS=$(date +%s)
echo "Starting DoE at $(date) in ${RUN_DIR}"

set +e
"${VENV}/bin/python3" -u "${EX4}/doe_amd_fsi.py" 2>&1 | tee doe_run.log
EXIT_CODE=${PIPESTATUS[0]}
set -e

END_TS=$(date +%s)
ELAPSED=$((END_TS - START_TS))
COMPLETED=$(find "${RUN_DIR}/particles" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
# Fallback: workers may have used home dir before CHR_RAY_OUTPUT_DIR fix
if [[ "${COMPLETED}" -eq 0 ]]; then
  COMPLETED=$(find "${HOME}/particles" -mindepth 1 -maxdepth 1 -type d -newer "${RUN_DIR}/doe_run.log" 2>/dev/null | wc -l)
fi

DOE_ELAPSED=$(grep -oP 'DoE completed in \K[0-9.]+' "${RUN_DIR}/doe_run.log" 2>/dev/null | head -1 || true)
AVG_SEC_PER_TRIAL=$(grep -oP 'Avg per trial: \K[0-9.]+' "${RUN_DIR}/doe_run.log" 2>/dev/null | head -1 || true)
THROUGHPUT=$(grep -oP 'Throughput:\s+\K[0-9.]+' "${RUN_DIR}/doe_run.log" 2>/dev/null | head -1 || true)
[[ -z "${DOE_ELAPSED}" && "${ELAPSED}" -gt 0 ]] && DOE_ELAPSED="${ELAPSED}"
if [[ -z "${AVG_SEC_PER_TRIAL}" && -n "${DOE_ELAPSED}" && "${COMPLETED}" -gt 0 ]]; then
  AVG_SEC_PER_TRIAL=$("${VENV}/bin/python3" -c "print(round(${DOE_ELAPSED}/${COMPLETED},2))")
fi
if [[ -z "${THROUGHPUT}" && -n "${DOE_ELAPSED}" && "${COMPLETED}" -gt 0 ]]; then
  THROUGHPUT=$("${VENV}/bin/python3" -c "print(round(${COMPLETED}/${DOE_ELAPSED}*3600,1))")
fi
GPU_HOURS=""
TRIALS_PER_GPU_HR=""
if [[ -n "${DOE_ELAPSED}" && -n "${CLUSTER_GPUS}" ]]; then
  GPU_HOURS=$("${VENV}/bin/python3" -c "print(round(float('${CLUSTER_GPUS}')*float('${DOE_ELAPSED}')/3600,3))")
  if [[ "${COMPLETED}" -gt 0 ]]; then
    TRIALS_PER_GPU_HR=$("${VENV}/bin/python3" -c "print(round(${COMPLETED}/float('${GPU_HOURS}'),2))")
  fi
fi

cat > scale_summary.txt <<EOF
scale_tier=${SCALE}
scale_gpus=${CHR_RAY_TOTAL_GPUS}
cluster_gpus=${CLUSTER_GPUS}
nodes=${CHR_RAY_NODES}
trials_requested=${CHR_RAY_NUM_TRIALS}
trials_completed_dirs=${COMPLETED}
max_concurrent=${CHR_RAY_MAX_CONCURRENT}
sim_tend=${CHR_RAY_SIM_TEND}
elapsed_seconds=${ELAPSED}
doe_elapsed_seconds=${DOE_ELAPSED:-}
avg_sec_per_trial=${AVG_SEC_PER_TRIAL:-}
throughput_trials_per_hr=${THROUGHPUT:-}
gpu_hours=${GPU_HOURS:-}
trials_per_gpu_hour=${TRIALS_PER_GPU_HR:-}
exit_code=${EXIT_CODE}
job_id=${SLURM_JOB_ID}
partition=${SLURM_JOB_PARTITION}
nodelist=${SLURM_JOB_NODELIST}
ray_address=${RAY_ADDRESS}
EOF

# Refresh aggregate performance report for all runs
"${VENV}/bin/python3" "${EX4}/measure_scale_performance.py" >> "${LOG_DIR}/performance_reports.log" 2>&1 || true

echo "Finished: ${COMPLETED}/${CHR_RAY_NUM_TRIALS} trial dirs in ${ELAPSED}s (exit ${EXIT_CODE})"
if [[ "${CHR_RAY_NODES}" -gt 1 ]]; then
  for pid in "${WORKER_PIDS[@]:-}"; do kill "${pid}" 2>/dev/null || true; done
  for node in $(scontrol show hostnames "${SLURM_JOB_NODELIST}"); do
    srun --nodes=1 --ntasks=1 -w "${node}" bash -lc "
      source '${EX4}/ray_cluster_env.sh'
      ray_cluster_env
      ray_stop_node
    " 2>/dev/null || true
  done
else
  ray_stop_node
fi

exit "${EXIT_CODE}"
