#!/bin/bash
# Pull each image in scripts/caas-images.txt through docker.cloudinative.com.
# Caches in the Nexus proxy on artifact (172.17.17.118), warming the mirror.
#
# Pre-reqs:
#   /etc/hosts maps docker.cloudinative.com → 176.65.243.214 (K1Kloud edge SNI)
#   docker on the runner has docker.cloudinative.com configured as a registry-mirror
#   in /etc/docker/daemon.json:
#     {"registry-mirrors": ["https://docker.cloudinative.com/"]}

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIST="${HERE}/caas-images.txt"
LOG="${HERE}/warm-nexus.log"
RESULT="${HERE}/warm-nexus.result.txt"

if [[ ! -r "$LIST" ]]; then
  echo "missing $LIST" >&2
  exit 1
fi

: > "$LOG"
: > "$RESULT"

total=$(grep -v '^#' "$LIST" | grep -v '^$' | wc -l)
i=0
ok=0
fail=0

for img in $(grep -v '^#' "$LIST" | grep -v '^$'); do
  i=$((i+1))
  echo "[$i/$total] pulling $img..." | tee -a "$LOG"
  if sudo timeout 1200 docker pull "$img" >> "$LOG" 2>&1; then
    ok=$((ok+1))
    echo "  OK $img" | tee -a "$RESULT"
  else
    fail=$((fail+1))
    echo "  FAIL $img" | tee -a "$RESULT"
  fi
done

{
  echo ""
  echo "Summary: total=$total ok=$ok fail=$fail"
  echo "WARM_NEXUS_DONE"
} >> "$RESULT"

cat "$RESULT"
exit $fail
