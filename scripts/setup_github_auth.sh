#!/usr/bin/env bash
# One-time GitHub auth for pushing chrono-ray from this cluster.
set -euo pipefail

export PATH="${HOME}/bin:${PATH}"

echo "=== GitHub auth for amd-pratmish/chrono-ray ==="
echo ""
echo "Option A — gh device login (recommended, configures git + SSH):"
echo "  gh auth login --hostname github.com --git-protocol ssh --web"
echo "  Then: cd ~/chrono-ray && git push origin main"
echo ""
echo "Option B — add SSH key manually:"
echo "  Public key:"
cat "${HOME}/.ssh/github_chrono_ray.pub"
echo ""
echo "  Add at: https://github.com/settings/ssh/new"
echo "  Then: cd ~/chrono-ray && git push origin main"
echo ""
echo "Remote (SSH): git@github.com:amd-pratmish/chrono-ray.git"
echo "Pending commit: $(cd ~/chrono-ray && git log -1 --oneline 2>/dev/null || echo 'none')"
