#!/usr/bin/env bash
# One-time venv + ChronoRay editable install on a GPU compute node.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/paths.env"

if [[ -x "${VENV}/bin/python3" ]] && "${VENV}/bin/python3" -c "import ray; import ChronoRay" 2>/dev/null; then
    echo "venv ok: ${VENV}"
    exit 0
fi

module load rocm/7.2.2 2>/dev/null || module load rocm 2>/dev/null || true
module load python/3.12 2>/dev/null || true

python3 -m venv "${VENV}"
# shellcheck source=/dev/null
source "${VENV}/bin/activate"
pip install -U pip wheel setuptools
pip install 'ray[tune]>=2.51' numpy 'bayesian-optimization==1.4.3' fsspec
pip install -e "${CHRONO_RAY_ROOT}"

export PYTHONPATH="${CHRONO_PYTHON_DIR}:${PYTHONPATH:-}"
export LD_LIBRARY_PATH="${CHRONO_HIP_PREFIX}/lib:${LD_LIBRARY_PATH:-}"
python3 -c "
import sys
sys.path.insert(0, '${CHRONO_RAY_ROOT}')
import ray
import ChronoRay
import pychrono.fsi as f
print('setup ok', ray.__version__)
"
