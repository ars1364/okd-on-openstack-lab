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

## P7. (placeholder) — bootstrap-complete stall

Will be filled with what actually happened when the install hit `wait-for bootstrap-complete`, if it stalls. The expected failure-order checks (bottom-up) are:

1. OpenStack: `openstack server list --project okd` (bootstrap + 3 masters created?)
2. Neutron: `openstack port list --project okd` + FIP associations
3. Security groups: `openstack security group list --project okd`
4. Bootstrap kubelet / cri-o journal (SSH into bootstrap)
5. etcd / kube-apiserver static pod logs from bootstrap node
6. Control-plane logs (after masters join)
7. Cluster operators (only after CP up)

## P8. (placeholder) — install-complete stall

Reserved for the second long-wait. The OKD installer's `wait-for install-complete` watches cluster operators. If any operator is `Available=False` or `Progressing=True` for too long, install fails.
