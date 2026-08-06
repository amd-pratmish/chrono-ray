#!/usr/bin/env bash
# Refresh performance report and push experiment status to GitHub.
set -euo pipefail

REPO="${HOME}/chrono-ray"
EX4="${REPO}/ex4-amd-multinode-fsi-doe"
export PATH="${HOME}/bin:${PATH}"

cd "${REPO}"

# Refresh metrics
python3 "${EX4}/measure_scale_performance.py"

# Touch status doc timestamp
sed -i "s/^\*\*Last updated:\*\*.*/\*\*Last updated:\*\* $(date -u '+%Y-%m-%d %H:%M UTC')/" \
  "${EX4}/EXPERIMENTS_STATUS.md" 2>/dev/null || true

git add \
  "${EX4}/results/performance/scale_performance.csv" \
  "${EX4}/results/performance/scale_performance.md" \
  "${EX4}/EXPERIMENTS_STATUS.md" \
  "${EX4}/results/"scale*gpu_*/scale_summary.txt \
  2>/dev/null || true

git add scripts/setup_github_auth.sh scripts/persist_experiment_status.sh 2>/dev/null || true

if git diff --staged --quiet; then
  echo "No experiment status changes to commit."
  exit 0
fi

git commit -m "$(cat <<EOF
Update FSI-SPH scale experiment status and performance metrics.

Refresh scale_performance report and EXPERIMENTS_STATUS snapshot.
EOF
)"

git push origin main
echo "Pushed experiment status to origin/main"
