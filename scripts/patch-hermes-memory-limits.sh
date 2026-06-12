#!/usr/bin/env bash
# Patch user_char_limit / memory_char_limit in every live Hermes profile and
# restart gateways so Hermes loads the new caps on the next session.
#
# Usage:
#   ./scripts/patch-hermes-memory-limits.sh
#   DOIT_VM_HOST=root@1.2.3.4 USER_LIMIT=4000 MEMORY_LIMIT=8000 ./scripts/patch-hermes-memory-limits.sh
set -euo pipefail

VM_HOST="${DOIT_VM_HOST:-root@162.243.30.100}"
USER_LIMIT="${HERMES_USER_CHAR_LIMIT:-4000}"
MEMORY_LIMIT="${HERMES_MEMORY_CHAR_LIMIT:-8000}"

echo ">> patch Hermes profile config.yaml limits on $VM_HOST"
ssh "$VM_HOST" "
  set -euo pipefail
  shopt -s nullglob
  for cfg in /root/.hermes/profiles/*/config.yaml /home/*/.hermes/profiles/*/config.yaml; do
    [ -f \"\$cfg\" ] || continue
    if grep -q '^memory:' \"\$cfg\"; then
      sed -i \
        -e 's/^  user_char_limit:.*/  user_char_limit: ${USER_LIMIT}/' \
        -e 's/^  memory_char_limit:.*/  memory_char_limit: ${MEMORY_LIMIT}/' \
        \"\$cfg\"
      echo patched \"\$cfg\"
    fi
  done
  systemctl restart 'hermes@*' || true
  echo done
"

echo ">> patch complete (user=${USER_LIMIT}, memory=${MEMORY_LIMIT})"
