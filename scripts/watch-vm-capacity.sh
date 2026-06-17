#!/usr/bin/env bash
# Quick capacity snapshot for the single-droplet beta setup.
# Run on the VM: /opt/doit/scripts/watch-vm-capacity.sh
set -euo pipefail

RUNNER_ENV="${DOIT_RUNNER_ENV:-/opt/doit/runner/.env}"
WARN_RAM_PCT="${WARN_RAM_PCT:-75}"
WARN_GATEWAY_AVG_MB="${WARN_GATEWAY_AVG_MB:-250}"

echo "=== doit VM capacity $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
echo

echo "--- memory ---"
free -h
echo

if swapon --show 2>/dev/null | grep -q .; then
  echo "--- swap ---"
  swapon --show
  echo
fi

echo "--- disk ---"
df -h /
echo

if [[ -f "$RUNNER_ENV" ]]; then
  echo "--- runner limits (from $RUNNER_ENV) ---"
  grep -E '^(MAX_CONCURRENT_RUNS|MAX_RUNS_PER_USER|MAX_PROVISIONED_USERS)=' "$RUNNER_ENV" || true
  echo
fi

gateway_pids=()
while IFS= read -r pid; do
  gateway_pids+=("$pid")
done < <(pgrep -f 'hermes -p .* gateway' 2>/dev/null || true)

gateway_count=${#gateway_pids[@]}
echo "--- Hermes gateways: $gateway_count active ---"

if (( gateway_count == 0 )); then
  echo "  (no gateway processes found)"
  echo
else
  total_kb=0
  while IFS= read -r line; do
    printf '  %s\n' "$line"
    rss_kb=$(echo "$line" | awk '{print $2}')
    total_kb=$((total_kb + rss_kb))
  done < <(
    ps -o pid=,rss=,args= -p "$(printf '%s,' "${gateway_pids[@]}" | sed 's/,$//')" \
      | awk '{printf "%s %s %s\n", $1, $2, substr($0, index($0,$3))}'
  )

  total_mb=$((total_kb / 1024))
  avg_mb=$((total_mb / gateway_count))
  echo
  echo "  total gateway RSS: ${total_mb} MB"
  echo "  average per gateway: ${avg_mb} MB"

  mem_total_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  mem_avail_kb=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
  mem_total_mb=$((mem_total_kb / 1024))
  mem_avail_mb=$((mem_avail_kb / 1024))
  mem_used_pct=$(((mem_total_kb - mem_avail_kb) * 100 / mem_total_kb))

  max_users=100
  if [[ -f "$RUNNER_ENV" ]]; then
    max_users=$(grep -E '^MAX_PROVISIONED_USERS=' "$RUNNER_ENV" | cut -d= -f2 || echo 100)
  fi

  projected_mb=$((avg_mb * max_users))
  overhead_mb=512
  projected_total_mb=$((projected_mb + overhead_mb))

  echo
  echo "  projected at MAX_PROVISIONED_USERS=${max_users}: ~${projected_total_mb} MB"
  echo "    (${max_users} gateways × ${avg_mb} MB + ~${overhead_mb} MB OS/runner overhead)"
  echo "  current RAM pressure: ${mem_used_pct}% used (${mem_avail_mb} MB available of ${mem_total_mb} MB)"

  echo
  echo "--- guidance ---"
  if (( projected_total_mb > mem_total_mb )); then
    echo "  ⚠  Full provisioning likely exceeds RAM. Resize before sending all invite codes."
    echo "     Target: Memory-Optimized 4 vCPU / 32 GB, or measure again after more users land."
  elif (( mem_used_pct >= WARN_RAM_PCT )); then
    echo "  ⚠  RAM usage is high (>= ${WARN_RAM_PCT}%). Consider resizing before the next invite wave."
  else
    echo "  ✓  Headroom looks OK for now. Re-run after every ~10–20 new users."
  fi

  if (( avg_mb >= WARN_GATEWAY_AVG_MB )); then
    echo "  ⚠  Per-gateway RSS (${avg_mb} MB) is above ${WARN_GATEWAY_AVG_MB} MB — projections may be low."
  fi
  echo
fi

echo "--- services ---"
systemctl is-active doit-runner 2>/dev/null && echo "  doit-runner: active" || echo "  doit-runner: inactive"
failed_gateways=$(systemctl list-units 'hermes@*' --state=failed --no-legend 2>/dev/null | wc -l | tr -d ' ')
echo "  hermes@* failed units: ${failed_gateways}"
