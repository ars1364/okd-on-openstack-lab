#!/bin/bash
# Pre-warm the Nexus quay proxy (https://quay.cloudinative.com/) with every
# image in the OKD release payload. After this script completes, the OKD
# bootstrap can pull from the mirror at LAN speed (~60 MB/s) instead of
# fighting the upstream-quay.io path (~340 KB/s on this lab).
#
# Why this matters: openshift-install has a 20-min API timer between
# "control-plane machines provisioned" and "API reachable". On a slow
# upstream link the bootstrap can't pull the SCOS release (382 MB) +
# scos-content (~3 GB across layers) + cluster-operator images in time,
# even with the systemd drop-in from 05a-bootstrap-dropin-watcher.yml
# triggering release-image.service properly.
#
# Pre-reqs:
#   - openshift-install + oc + kubectl at $OKD_BIN_DIR (default
#     /home/ubuntu/okd-build/bin)
#   - /etc/hosts maps quay.cloudinative.com → 176.65.243.214
#   - Docker daemon on the runner reachable (we use docker pull to drive
#     the cache; the binary doesn't matter as long as it can DNS+TLS
#     against quay.cloudinative.com)
#
# Usage:
#   ./scripts/warm-okd-payload.sh
#
# The script is idempotent — re-running after a successful warm is fast
# because every layer is already in Nexus.

set -uo pipefail

OKD_BIN_DIR="${OKD_BIN_DIR:-/home/ubuntu/okd-build/bin}"
RELEASE_IMAGE="${RELEASE_IMAGE:-quay.io/okd/scos-release@sha256:371309d97da5c7f595662cb7d2a9bf11c05fe96f2bf54898e6da60f13c12ffda}"
MIRROR_HOST="${MIRROR_HOST:-quay.cloudinative.com}"
WORKDIR=$(mktemp -d)
LOG=$WORKDIR/warm-okd.log
RESULT=$WORKDIR/warm-okd.result.txt

trap "echo '  workdir kept at $WORKDIR for review'" EXIT

if [[ ! -x "$OKD_BIN_DIR/oc" ]]; then
  echo "missing $OKD_BIN_DIR/oc — adjust OKD_BIN_DIR" >&2
  exit 1
fi

echo "[1/3] Extracting pullspecs from $RELEASE_IMAGE..."
"$OKD_BIN_DIR/oc" adm release info "$RELEASE_IMAGE" --pullspecs 2>&1 \
  | awk '/^[[:space:]]+[a-z].*quay\.io\// {print $NF}' \
  | sort -u > "$WORKDIR/pullspecs.txt"

# Also include the release image itself
echo "$RELEASE_IMAGE" >> "$WORKDIR/pullspecs.txt"

total=$(wc -l < "$WORKDIR/pullspecs.txt")
echo "  $total component pullspecs to mirror"

echo
echo "[2/3] Rewriting upstream → mirror host..."
sed "s|quay.io|$MIRROR_HOST|" "$WORKDIR/pullspecs.txt" > "$WORKDIR/mirror-pulls.txt"

echo
echo "[3/3] Pulling each through the mirror (caches in Nexus)..."
: > "$LOG"
: > "$RESULT"
i=0
ok=0
fail=0
start_ts=$(date +%s)

while read img; do
  i=$((i+1))
  echo "[$i/$total] $img" | tee -a "$LOG"
  if sudo timeout 600 docker pull "$img" >> "$LOG" 2>&1; then
    ok=$((ok+1))
    echo "OK $i $img" >> "$RESULT"
  else
    fail=$((fail+1))
    echo "FAIL $i $img" >> "$RESULT"
  fi
  if (( i % 10 == 0 )); then
    elapsed=$(($(date +%s) - start_ts))
    eta=$(awk -v i=$i -v t=$total -v e=$elapsed 'BEGIN{if(i>0 && e>0) printf "%d", (t-i)*e/i; else print "?"}')
    echo "  === progress: $i/$total ok=$ok fail=$fail elapsed=${elapsed}s eta=${eta}s ==="
  fi
done < "$WORKDIR/mirror-pulls.txt"

elapsed=$(($(date +%s) - start_ts))
{
  echo ""
  echo "Summary: total=$total ok=$ok fail=$fail elapsed=${elapsed}s"
  echo "WARM_OKD_DONE"
} >> "$RESULT"

cat "$RESULT" | tail -20
echo
echo "Done. Subsequent OKD installs that have imageContentSources pointing"
echo "$MIRROR_HOST/okd → quay.io/okd will pull from the warm cache at LAN speed."
exit $fail
