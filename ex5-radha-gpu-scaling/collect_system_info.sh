#!/usr/bin/env bash
# Collect system info JSON (login or compute).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/paths.env"
source "$(dirname "${BASH_SOURCE[0]}")/ray_cluster_env.sh"
export CHR_RAY_PLATFORM="${1:-radha-login}"
export CHR_RAY_RESULTS_TAG="${2:-system}"
OUT="${RESULTS_ROOT}/${CHR_RAY_RESULTS_TAG}/system_info/$(hostname -s)_$(date +%Y%m%d_%H%M%S).json"
mkdir -p "$(dirname "${OUT}")"
if [[ -x "${VENV}/bin/python3" ]]; then
    collect_system_info "${OUT}"
else
    python3 - <<PY "${OUT}"
import json, platform, subprocess, sys
from datetime import datetime, timezone
out = sys.argv[1]
def run(c):
    try:
        return subprocess.check_output(c, shell=True, text=True, stderr=subprocess.STDOUT, timeout=30)
    except Exception as e:
        return str(e)
info = {"timestamp_utc": datetime.now(timezone.utc).isoformat(), "hostname": platform.node(),
        "cpu": run("lscpu"), "memory": run("free -h"), "network": run("ip -4 addr")}
open(out,"w").write(json.dumps(info, indent=2))
print(out)
PY
fi
