#!/usr/bin/env bash
# Monitor ex5 jobs and refresh reports (run from login node).
set -euo pipefail

ROOT="/shared/${USER}/src/chrono-ray-amd/ex5-radha-gpu-scaling"
RESULTS="/shared/${USER}/amd_chronos_results/phase3/ex5_radha_scaling"
INTERVAL="${1:-120}"

echo "=== ex5 monitor $(date -Is) ==="
squeue -u "${USER}" -o '%.10i %.12P %.14j %.8T %.10M %.6D %R' 2>/dev/null | rg 'ex5|JOBID' || squeue -u "${USER}" | head -10

for plat in mi350x mi300x; do
    if [[ -x /shared/${USER}/chrono_ray_venv/bin/python3 ]]; then
        /shared/${USER}/chrono_ray_venv/bin/python3 "${ROOT}/measure_scale_performance.py" --platform "${plat}" 2>/dev/null || true
    fi
done

/shared/${USER}/chrono_ray_venv/bin/python3 "${ROOT}/compare_vultr.py" 2>/dev/null || python3 "${ROOT}/compare_vultr.py" 2>/dev/null || true

echo "Results: ${RESULTS}"
