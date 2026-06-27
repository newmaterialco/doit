#!/usr/bin/env bash
# Push the runner Python module and Hermes helper files to the VM, then bounce
# the systemd service.
#
# The runner deployment is intentionally low-tech: a single rsync of the
# `runner/runner/` package plus the small Hermes helper scripts/skills the
# runner calls, then `systemctl restart` of the `doit-runner` service.
# No CI, no container registry, no Docker image to build — fits a small
# VM/VPS deployment.
#
# VM coords are read from env so a hosted deployment never bakes production
# infrastructure into the public repo.
#
# Excludes:
#   .venv         — platform-specific (linux on VM, macOS on dev laptop)
#   .env          — real secrets live only on the VM; never overwrite
#   __pycache__ / *.pyc — build artifacts
#
# Usage:
#   DOIT_VM_HOST=root@1.2.3.4 ./scripts/deploy-runner.sh
#   DOIT_VM_PATH=/srv/doit/runner ./scripts/deploy-runner.sh
set -euo pipefail

if [[ -z "${DOIT_VM_HOST:-}" ]]; then
  echo "error: set DOIT_VM_HOST (example: root@1.2.3.4)" >&2
  exit 1
fi

VM_HOST="$DOIT_VM_HOST"
VM_PATH="${DOIT_VM_PATH:-/opt/doit/runner}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER_SRC="$REPO_ROOT/runner/runner/"
RUNNER_DEST="$VM_HOST:$VM_PATH/runner/"
HERMES_SCRIPTS_SRC="$REPO_ROOT/hermes/scripts/"
HERMES_SCRIPTS_DEST="$VM_HOST:$(dirname "$VM_PATH")/hermes/scripts/"
HERMES_SKILLS_SRC="$REPO_ROOT/hermes/skills/"
HERMES_SKILLS_DEST="$VM_HOST:$(dirname "$VM_PATH")/hermes/skills/"
HERMES_TEMPLATE_SRC="$REPO_ROOT/hermes/profiles/_template/"
HERMES_TEMPLATE_DEST="$VM_HOST:$(dirname "$VM_PATH")/hermes/profiles/_template/"
HERMES_SYSTEMD_SRC="$REPO_ROOT/hermes/systemd/"
HERMES_SYSTEMD_DEST="$VM_HOST:$(dirname "$VM_PATH")/hermes/systemd/"
SCRIPTS_SRC="$REPO_ROOT/scripts/"
SCRIPTS_DEST="$VM_HOST:$(dirname "$VM_PATH")/scripts/"

echo ">> ensure Hermes helper directories on $VM_HOST"
ssh "$VM_HOST" "
  mkdir -p '$(dirname "$VM_PATH")/hermes/scripts' '$(dirname "$VM_PATH")/hermes/skills' \
           '$(dirname "$VM_PATH")/hermes/profiles/_template' \
           '$(dirname "$VM_PATH")/hermes/systemd' '$(dirname "$VM_PATH")/scripts'
"

echo ">> rsync $RUNNER_SRC -> $RUNNER_DEST"
rsync -avc --delete \
  --exclude '__pycache__' \
  --exclude '*.pyc' \
  "$RUNNER_SRC" "$RUNNER_DEST"

echo ">> rsync $HERMES_SCRIPTS_SRC -> $HERMES_SCRIPTS_DEST"
rsync -avc --delete \
  --exclude '__pycache__' \
  --exclude '*.pyc' \
  "$HERMES_SCRIPTS_SRC" "$HERMES_SCRIPTS_DEST"

echo ">> rsync $HERMES_SKILLS_SRC -> $HERMES_SKILLS_DEST"
rsync -avc --delete \
  --exclude '__pycache__' \
  --exclude '*.pyc' \
  "$HERMES_SKILLS_SRC" "$HERMES_SKILLS_DEST"

echo ">> rsync $HERMES_TEMPLATE_SRC -> $HERMES_TEMPLATE_DEST"
rsync -avc --delete "$HERMES_TEMPLATE_SRC" "$HERMES_TEMPLATE_DEST"

echo ">> rsync $HERMES_SYSTEMD_SRC -> $HERMES_SYSTEMD_DEST"
rsync -avc --delete "$HERMES_SYSTEMD_SRC" "$HERMES_SYSTEMD_DEST"

echo ">> rsync $SCRIPTS_SRC -> $SCRIPTS_DEST"
rsync -avc "$SCRIPTS_SRC" "$SCRIPTS_DEST"

echo ">> install bundled Hermes skills on $VM_HOST"
ssh "$VM_HOST" "
  mkdir -p ~/.hermes/skills &&
  rsync -avc '$(dirname "$VM_PATH")/hermes/skills/' ~/.hermes/skills/
"

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
