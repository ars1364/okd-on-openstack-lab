# Pitfalls hit on the office1 lab — keep this growing

This file tracks lab-specific gotchas and how to avoid them. Every pitfall lives here, not just the happy path, so the next operator can skip the same mistakes.

## P1. `group_vars/all.yml` placed outside the inventory's load path

**Symptom:** `'okd_binaries_dir' is undefined` on the very first task of `00-preflight.yml` despite a complete `all.yml`.

**Cause:** Ansible looks for `group_vars/` adjacent to the inventory file or the playbook directory, not at an arbitrary path like `ansible/group_vars/all.yml`.

**Fix:** Move `group_vars/` under the inventory directory, so the layout is `ansible/inventory/group_vars/all.yml` paired with `ansible/inventory/lab.yml`.

---

## P2. SCOS image digest check used the wrong hash

**Symptom:** `00-preflight.yml` failed the sha256 prefix check against the decompressed `.qcow2` file.

**Cause:** `openshift-install coreos print-stream-json` publishes the hash for the upstream **`.qcow2.gz`** download, not the decompressed image. Checking the `.qcow2` against that hash will never match.

**Fix:** Track the upstream `.qcow2.gz` separately as `okd_image_gz_path` and check the prefix against `okd_image_gz_sha256_prefix`. The decompressed `.qcow2` only needs an existence check.

---

## P3. `openstack.cloud.floating_ip` (collection 2.x) won't allocate detached FIPs

**Symptom:** `missing required arguments: server` when trying to allocate a FIP via the Ansible module.

**Cause:** The 2.x module is attach/detach only; it cannot allocate an unattached FIP.

**Fix:** Shell out to the openstack CLI for allocation. `03-fips.yml` uses an idempotent `openstack floating ip create --project okd ext-net` call, recording the addresses in `cluster-config/.fips.yml` for reuse on subsequent runs.

---

## P4. `pullSecret` YAML rendering via slurp + b64decode produces single-quoted Python-repr garbage

**Symptom:** `openshift-install create cluster` fails immediately with `error converting YAML to JSON: yaml: line 43: did not find expected key`, and the rendered `install-config.yaml` shows `pullSecret: '{'auths': {'fake': ...}}'` — all single quotes, no JSON.

**Cause:** Using `slurp` → `b64decode` → wrapping in single-quoted YAML scalar in a template caused Ansible/Jinja to round-trip the JSON content through Python's `repr()`, replacing every `"` with `'`.

**Fix:** Read the file with `lookup('file', ...)` directly in the template and apply `to_json` to make it an unambiguous JSON-quoted string:

```jinja
pullSecret: {{ lookup('file', okd_pull_secret_path) | trim | to_json }}
sshKey: |
  {{ lookup('file', okd_ssh_pubkey_path) | trim }}
```

---

## P5. `/etc/kolla/clouds.yaml` password drifted from the lab's actual admin password

**Symptom:** HTTP 401 from openstacksdk auth against `kolla-admin` despite a freshly-installed lab.

**Cause:** `/etc/kolla/clouds.yaml` was rendered at lab build time, then the admin password was rotated by a later reconfigure. `admin-openrc.sh` was updated but `clouds.yaml` wasn't.

**Fix:** Always source the canonical password from `/etc/kolla/admin-openrc.sh`. The IaC writes its own `~/.config/openstack/clouds.yaml` from that source. Never trust `/etc/kolla/clouds.yaml` directly.

---

## P6. openstacksdk does NOT auto-read `/etc/kolla/clouds.yaml`

**Symptom:** `Cloud kolla-admin was not found` from the `openstack.cloud.identity_user_info` Ansible module.

**Cause:** openstacksdk only looks at:
- `./clouds.yaml`
- `~/.config/openstack/clouds.yaml`
- `/etc/openstack/clouds.yaml`

`/etc/kolla/clouds.yaml` is not on that list.

**Fix:** Install the clouds.yaml at `~/.config/openstack/clouds.yaml` on the deploy host, **or** set `OS_CLIENT_CONFIG_FILE` in the environment for every task that uses openstack.cloud modules.

---


## P7. First-attempt install: master-0 OpenStackServer never created; 15-min `provision control-plane` timeout fires

**Symptom:** `openshift-install create cluster` exits after 15 minutes with `failed to provision control-plane machines within 15m0s`. In OpenStack, the bootstrap + 2 of 3 masters are ACTIVE; master-0 has a created Cinder root volume (status `available`) and a created Neutron port (status `DOWN`) but no Nova server.

**Logs of interest:**
```
level=debug msg="E0522 15:12:53.896332 ... \"failed to patch OpenStackMachine ... okd-8k99z-master-0 ... admission webhook \\\"validation.openstackmachine.infrastructure.cluster.x-k8s.io\\\" denied the request: ... spec: Forbidden: cannot be modified\""
level=debug msg="Waiting for OpenStackServer to be ready" ... openStackMachine=\"okd-8k99z-master-0\""
level=error msg="failed to fetch Cluster: failed to generate asset \"Cluster\": failed to create cluster: failed to provision control-plane machines within 15m0s"
```

**Cause:** OKD 4.22 uses CAPI/CAPO internally during install. There's a known race where one of the OpenStackMachine reconciliations gets denied by the immutability webhook on the first attempt, and the dependent OpenStackServer resource never gets created for that one machine. The installer's hard-coded 15-minute "provision" timeout then fires.

**Recovery:**
1. `openshift-install destroy cluster --dir cluster-config` cleans up Nova + Cinder + Neutron + SG residue (FIPs pre-allocated outside the installer are kept).
2. Re-render `install-config.yaml` (the installer consumed and deleted the original).
3. Re-run `create cluster`. The race usually resolves on the second attempt.

The IaC's `03-fips.yml` is designed to re-use already-allocated FIPs (it records them in `.fips.yml`), so the destroy → retry path keeps the same `api`/`ingress` FIPs.

**Best-effort mitigation:** add `api.<cluster>.<basedomain>` and `*.apps.<cluster>.<basedomain>` to the deploy host's `/etc/hosts` pointing at the api/ingress FIPs respectively, so the installer's "is API reachable?" probe doesn't sit on DNS timeouts during the wait.


## P8. `neutron_ovn_metadata_agent` (and `neutron_server`) missing from one Kolla controller — silent VM metadata failure on that chassis

**Symptom:** OKD bootstrap (and any masters) that happen to be Nova-scheduled on the affected chassis sit at the SCOS ignition stage with:

```
ignition[825]: GET http://169.254.169.254/openstack/latest/user_data: attempt #1
...
ignition[825]: GET error: ... dial tcp 169.254.169.254:80: i/o timeout
ignition[825]: failed to fetch config from metadata service: unable to fetch resource in time
```

VMs on the other (healthy) chassis ignite fine, so the failure looks like a flake until you correlate landing-host with metadata outcome. We saw the same symptom on a KaaS worker (S-1 in `kaas_rerun_2026_05_22.md`), then on the OKD bootstrap on a fresh install — same root cause.

**Cause:** On the affected Kolla controller, the `neutron_ovn_metadata_agent` container does not exist at all. `docker ps --all` lists only OVN core (`ovn_northd`, `ovn_sb_db`, `ovn_nb_db`, `ovn_controller`) plus `nova_novncproxy`. The healthy controllers also run `neutron_server` and `neutron_ovn_metadata_agent`. With no agent on the chassis, there's no `ovnmeta-<networkid>` netns and no haproxy listening on 169.254.169.254 for VMs landing there.

Most likely root cause is configuration drift from a partial `kolla-ansible reconfigure` run that touched some hosts but not this one (we have at least one D-1 reconfigure in this lab's history that limited host scope).

**Detection:**

```bash
# Run on each Kolla controller
sudo docker ps --all --format '{{.Names}} {{.Status}}' | grep -i neutron
```

Expected: `neutron_server` and `neutron_ovn_metadata_agent` Up. If either is missing, the chassis is broken.

**Fix:**

```bash
sudo bash -c "source /opt/kolla-venv/bin/activate && \
  kolla-ansible reconfigure -i /etc/kolla/multinode -t neutron --limit <affected-host>"
```

Verify after:

```bash
sudo ssh <affected-host> "sudo docker ps --format '{{.Names}} {{.Status}}' | grep neutron"
sudo ssh <affected-host> "sudo ip netns list | grep ovnmeta"
```

The metadata netns appears within seconds of the agent starting.

**Why this hit OKD harder than KaaS:** OKD creates 4 control-plane VMs (bootstrap + 3 masters) in close succession, all on the same fresh tenant network. Nova's filter scheduler with anti-affinity spreads them across all 3 chassis. So 1-2 of them inevitably land on the broken chassis and silently fail ignition, with no fast retry — the installer's 20-min `wait-for-api` timeout is the only failure signal.

