#!/bin/bash
# One-shot driver: run the OKD lifecycle playbooks in order. Bails on first failure.
#
# Env overrides:
#   OS_CLIENT_CONFIG_FILE   path to clouds.yaml (default /etc/kolla/clouds.yaml)
#   OKD_SKIP_DESTROY=1      do not include the destroy step in this run

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"

if ! command -v ansible-playbook >/dev/null; then
  echo "ansible-playbook not found" >&2
  exit 1
fi

if [[ ! -d collections ]]; then
  ansible-galaxy collection install -r requirements.yml -p ./collections
fi

run() {
  local pb="$1"
  echo "==== $pb ===="
  ansible-playbook -i ansible/inventory/lab.yml "ansible/playbooks/$pb"
}

run 00-preflight.yml
run 01-glance-image.yml
run 02-project-network.yml
run 03-fips.yml
run 04-install-config.yml
run 05-create-cluster.yml
run 06-post-install.yml

echo ""
echo "OKD cluster deploy complete."
echo "See cluster-config/DEPLOY-SUMMARY.txt for endpoints + kubeconfig."
