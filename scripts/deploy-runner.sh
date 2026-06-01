#!/usr/bin/env bash
# Push the runner Python module to the VM and bounce the systemd service.
#
# The runner deployment is intentionally low-tech: a single rsync of the
# `runner/runner/` package onto the VM, then `systemctl restart` of the
# `doit-runner` service. No CI, no container registry, no Docker image to
# build — fits the single-droplet hobby setup.
#
# VM coords are read from env so a future move to a different host doesn't
# require editing this script. Defaults match the current droplet so a
# bare `./scripts/deploy-runner.sh` Just Works from a fresh clone.
#
# Excludes:
#   .venv         — platform-specific (linux on VM, macOS on dev laptop)
#   .env          — real secrets live only on the VM; never overwrite
#   __pycache__ / *.pyc — build artifacts
#
# Usage:
#   ./scripts/deploy-runner.sh
#   DOIT_VM_HOST=root@1.2.3.4 ./scripts/deploy-runner.sh
#   DOIT_VM_PATH=/srv/doit/runner ./scripts/deploy-runner.sh
set -euo pipefail

VM_HOST="${DOIT_VM_HOST:-root@162.243.30.100}"
VM_PATH="${DOIT_VM_PATH:-/opt/doit/runner}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO_ROOT/runner/runner/"
DEST="$VM_HOST:$VM_PATH/runner/"

echo ">> rsync $SRC -> $DEST"
rsync -avc --delete \
  --exclude '__pycache__' \
  --exclude '*.pyc' \
  "$SRC" "$DEST"

echo ">> install runner deps on $VM_HOST"
ssh "$VM_HOST" "
  cd '$VM_PATH' &&
  if [ -d .venv ]; then
    .venv/bin/pip install -q croniter==2.0.5
  else
    pip3 install -q croniter==2.0.5
  fi
"

echo ">> restart doit-runner on $VM_HOST"
ssh "$VM_HOST" '
  systemctl restart doit-runner &&
  sleep 2 &&
  systemctl is-active doit-runner &&
  echo "--- last 15 log lines ---" &&
  journalctl -u doit-runner --since "10 seconds ago" --no-pager -n 15
'

echo ">> deploy complete"
