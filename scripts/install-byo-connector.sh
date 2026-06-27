#!/usr/bin/env bash
# Install or update the Doit BYO connector on a machine that can reach Hermes.
#
# This script intentionally installs only the connector. It does not install,
# configure, expose, or modify Hermes itself.
set -euo pipefail

REPO_URL="${DOIT_REPO_URL:-https://github.com/newmaterialco/doit.git}"
INSTALL_DIR="${DOIT_INSTALL_DIR:-$HOME/doit}"
RUNNER_DIR="$INSTALL_DIR/runner"
SERVICE_NAME="${DOIT_SERVICE_NAME:-doit-connector.service}"
ENV_FILE="${DOIT_CONNECTOR_ENV_FILE:-/etc/doit/connector.env}"
HERMES_URL="${DOIT_HERMES_URL:-http://127.0.0.1:8643}"
HERMES_API_KEY="${DOIT_HERMES_API_KEY:-}"
RUN_AS_USER="${DOIT_CONNECTOR_USER:-$(id -un)}"

required_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "error: set $name before running this installer" >&2
    exit 1
  fi
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: missing required command: $1" >&2
    exit 1
  fi
}

required_env DOIT_SUPABASE_URL
required_env DOIT_SUPABASE_ANON_KEY
required_env DOIT_CONNECTOR_TOKEN

require_cmd git
require_cmd python3
require_cmd curl
require_cmd systemctl

if [[ "$(id -u)" -eq 0 ]]; then
  SUDO=""
else
  require_cmd sudo
  SUDO="sudo"
fi

echo "==> Installing Doit BYO connector"
echo "    repo: $REPO_URL"
echo "    install dir: $INSTALL_DIR"
echo "    Hermes URL: $HERMES_URL"
echo "    service user: $RUN_AS_USER"

if [[ -d "$INSTALL_DIR/.git" ]]; then
  echo "==> Updating existing Doit checkout"
  git -C "$INSTALL_DIR" pull --ff-only
elif [[ -e "$INSTALL_DIR" && -n "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]]; then
  echo "error: $INSTALL_DIR exists but is not a git checkout" >&2
  echo "Set DOIT_INSTALL_DIR to another path or move the existing directory." >&2
  exit 1
else
  echo "==> Cloning Doit"
  mkdir -p "$(dirname "$INSTALL_DIR")"
  git clone "$REPO_URL" "$INSTALL_DIR"
fi

if [[ ! -d "$RUNNER_DIR" ]]; then
  echo "error: expected runner directory at $RUNNER_DIR" >&2
  exit 1
fi

echo "==> Creating/updating Python environment"
cd "$RUNNER_DIR"
if ! python3 -m venv .venv; then
  echo "error: failed to create Python venv" >&2
  echo "On Ubuntu, install venv support with: sudo apt install python3-venv" >&2
  exit 1
fi
.venv/bin/python -m pip install --upgrade pip
.venv/bin/pip install -r requirements.txt

echo "==> Checking Hermes reachability"
HEALTH_HEADERS=()
if [[ -n "$HERMES_API_KEY" ]]; then
  HEALTH_HEADERS=(-H "Authorization: Bearer $HERMES_API_KEY")
fi
if curl -fsS --max-time 5 "${HEALTH_HEADERS[@]}" "$HERMES_URL/health" >/dev/null; then
  echo "    Hermes health check passed"
else
  echo "warning: could not reach Hermes at $HERMES_URL/health" >&2
  echo "         The connector will still install, but tasks will fail until Hermes is reachable." >&2
fi

echo "==> Writing connector environment"
$SUDO mkdir -p "$(dirname "$ENV_FILE")"
TMP_ENV="$(mktemp)"
cat >"$TMP_ENV" <<EOF
SUPABASE_URL=$DOIT_SUPABASE_URL
SUPABASE_ANON_KEY=$DOIT_SUPABASE_ANON_KEY
DOIT_CONNECTOR_TOKEN=$DOIT_CONNECTOR_TOKEN
DOIT_CONNECTOR_HERMES_URL=$HERMES_URL
HERMES_API_KEY=$HERMES_API_KEY
EOF
$SUDO install -m 600 "$TMP_ENV" "$ENV_FILE"
rm -f "$TMP_ENV"

SERVICE_PATH="/etc/systemd/system/$SERVICE_NAME"
if $SUDO test -f "$SERVICE_PATH"; then
  BACKUP_PATH="$SERVICE_PATH.backup.$(date +%Y%m%d%H%M%S)"
  echo "==> Backing up existing service to $BACKUP_PATH"
  $SUDO cp "$SERVICE_PATH" "$BACKUP_PATH"
fi

echo "==> Writing systemd service"
TMP_SERVICE="$(mktemp)"
cat >"$TMP_SERVICE" <<EOF
[Unit]
Description=Doit BYO Connector - Supabase to Hermes bridge
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$RUN_AS_USER
WorkingDirectory=$RUNNER_DIR
EnvironmentFile=$ENV_FILE
ExecStart=$RUNNER_DIR/.venv/bin/python -m runner.connector \\
  --supabase-url \${SUPABASE_URL} \\
  --supabase-anon-key \${SUPABASE_ANON_KEY} \\
  --connector-token \${DOIT_CONNECTOR_TOKEN} \\
  --hermes-url \${DOIT_CONNECTOR_HERMES_URL}
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
$SUDO install -m 644 "$TMP_SERVICE" "$SERVICE_PATH"
rm -f "$TMP_SERVICE"

echo "==> Starting connector service"
$SUDO systemctl daemon-reload
$SUDO systemctl enable --now "$SERVICE_NAME"
$SUDO systemctl restart "$SERVICE_NAME"
sleep 2
if ! $SUDO systemctl is-active --quiet "$SERVICE_NAME"; then
  $SUDO systemctl --no-pager status "$SERVICE_NAME" || true
  echo "error: $SERVICE_NAME did not stay active" >&2
  echo "Inspect logs with: sudo journalctl -u $SERVICE_NAME --no-pager -n 100" >&2
  exit 1
fi
$SUDO systemctl --no-pager status "$SERVICE_NAME"

echo
echo "Doit BYO connector install complete."
echo "Watch logs with:"
echo "  sudo journalctl -u $SERVICE_NAME -f"
