#!/usr/bin/env bash
# Install the hermes@.service systemd template unit on the VM and migrate any
# existing hand-written hermes-<profile>.service units to template instances.
#
# Run ON THE VM (as root or with sudo), from a checkout/deploy of this repo:
#
#   sudo ./scripts/install-hermes-template-unit.sh
#
# Or from your laptop:
#
#   scp hermes/systemd/hermes@.service scripts/install-hermes-template-unit.sh root@<vm>:/tmp/
#   ssh root@<vm> 'HERMES_UNIT_SRC=/tmp/hermes@.service bash /tmp/install-hermes-template-unit.sh'
#
# Environment overrides:
#   HERMES_BIN       path to the hermes binary       (default: $(command -v hermes))
#   HERMES_USER      user the gateways run as        (default: detected from an
#                                                     existing hermes-*.service, else root)
#   DOIT_ENV_FILE    shared secrets file injected into every gateway
#                    (default: /opt/doit/runner/.env; matches the legacy
#                    10-doit-env.conf drop-in)
#   RUNNER_USER      if set and not root, also install the scoped sudoers entry
#                    from hermes/systemd/doit-hermes.sudoers for this user
#   HERMES_UNIT_SRC  path to the template unit file  (default: hermes/systemd/hermes@.service
#                                                     relative to this script's repo root)
#
# Idempotent: re-running with no legacy units left is a no-op apart from
# rewriting the (identical) template file.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UNIT_SRC="${HERMES_UNIT_SRC:-$REPO_ROOT/hermes/systemd/hermes@.service}"
SUDOERS_SRC="${HERMES_SUDOERS_SRC:-$REPO_ROOT/hermes/systemd/doit-hermes.sudoers}"
UNIT_DEST="/etc/systemd/system/hermes@.service"

if [ ! -f "$UNIT_SRC" ]; then
  echo "error: template unit not found at $UNIT_SRC" >&2
  exit 1
fi

HERMES_BIN="${HERMES_BIN:-$(command -v hermes || true)}"
if [ -z "$HERMES_BIN" ]; then
  echo "error: hermes binary not found; set HERMES_BIN=/path/to/hermes" >&2
  exit 1
fi

# Detect the gateway user from an existing legacy unit unless overridden.
if [ -z "${HERMES_USER:-}" ]; then
  HERMES_USER=root
  for unit in /etc/systemd/system/hermes-*.service; do
    [ -e "$unit" ] || continue
    detected="$(sed -n 's/^User=//p' "$unit" | head -n1)"
    if [ -n "$detected" ]; then
      HERMES_USER="$detected"
    fi
    break
  done
fi

DOIT_ENV_FILE="${DOIT_ENV_FILE:-/opt/doit/runner/.env}"

echo ">> installing $UNIT_DEST (User=$HERMES_USER, ExecStart=$HERMES_BIN, EnvFile=$DOIT_ENV_FILE)"
sed -e "s|__HERMES_USER__|$HERMES_USER|" \
    -e "s|__HERMES_BIN__|$HERMES_BIN|" \
    -e "s|__DOIT_ENV_FILE__|$DOIT_ENV_FILE|" \
  "$UNIT_SRC" > "$UNIT_DEST"
systemctl daemon-reload

# Migrate legacy hermes-<profile>.service units to hermes@<profile>.
# Drop-in dirs (e.g. 10-doit-env.conf) are removed too: the template bakes
# in the doit EnvironmentFile, so per-unit drop-ins are no longer needed.
migrated=0
for unit in /etc/systemd/system/hermes-*.service; do
  [ -e "$unit" ] || continue
  name="$(basename "$unit" .service)"   # hermes-alice
  profile="${name#hermes-}"             # alice
  if [ -z "$profile" ] || [ "$profile" = "$name" ]; then
    continue
  fi
  echo ">> migrating $name -> hermes@$profile"
  systemctl disable --now "$name" || true
  rm -f "$unit"
  rm -rf "/etc/systemd/system/$name.service.d"
  systemctl daemon-reload
  systemctl enable --now "hermes@$profile"
  migrated=$((migrated + 1))
done
echo ">> migrated $migrated legacy unit(s)"

# Optional scoped sudoers for a non-root runner user.
if [ -n "${RUNNER_USER:-}" ] && [ "$RUNNER_USER" != "root" ]; then
  if [ ! -f "$SUDOERS_SRC" ]; then
    echo "error: sudoers template not found at $SUDOERS_SRC" >&2
    exit 1
  fi
  echo ">> installing /etc/sudoers.d/doit-hermes for $RUNNER_USER"
  sed "s/__RUNNER_USER__/$RUNNER_USER/" "$SUDOERS_SRC" > /etc/sudoers.d/doit-hermes
  chmod 440 /etc/sudoers.d/doit-hermes
  visudo -c >/dev/null
fi

# Report instance health.
echo ">> active hermes@ instances:"
systemctl list-units 'hermes@*' --no-legend --no-pager || true

cat <<'EOF'
>> done. Make sure the runner .env uses the template instance names:
     HERMES_RESTART_COMMAND_TEMPLATE=sudo systemctl restart hermes@{profile}
     HERMES_START_COMMAND_TEMPLATE=sudo systemctl enable --now hermes@{profile}
   (drop the leading "sudo " if the runner runs as root)
   then: systemctl restart doit-runner
EOF
