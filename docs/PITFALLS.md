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


## P9. OKD-installer-created subnet has empty `dns_nameservers` → bootstrap can't resolve quay.io

**Symptom:** After the metadata fix (P8), SCOS ignition succeeds and SSH on the bootstrap works, but `node-image-pull.service` runs in a loop:

```
node-image-pull.sh: Failed to query release image; retrying...
podman: lookup quay.io on [::1]:53: read udp [::1]:41096->[::1]:53: read: connection refused
```

The installer's `wait-for-api` then times out at 20 min because the temporary control plane never starts.

**Cause:** When OKD's CAPO creates the tenant subnet during install, `dns_nameservers` on the subnet is empty. Neutron's DHCP agent pushes no DNS, so VMs end up with `/etc/resolv.conf` pointing only at `127.0.0.1` (NetworkManager-resolved style), which is not listening for these SCOS images. `podman`/`skopeo` use the libc resolver path which fails to reach external DNS.

`getent` works because nsswitch falls back to other paths; `podman pull` does not.

**Fix:** Pre-create the tenant network + subnet **with DNS set** before invoking the installer, and pass the subnet UUID to `install-config.yaml` via `platform.openstack.machinesSubnet`. The IaC does this in `02b-machines-net.yml`:

```yaml
- openstack.cloud.subnet:
    name: "{{ okd_cluster_name }}-machines-subnet"
    cidr: "{{ okd_machine_cidr }}"
    dns_nameservers:
      - 8.8.8.8
      - 1.1.1.1
```

…and the rendered `install-config.yaml` includes:

```yaml
platform:
  openstack:
    machinesSubnet: <subnet-UUID>
```

The installer then re-uses the pre-created subnet instead of making its own.


## P10. OKD installer rejects apiVIP/ingressVIP when they fall in the machinesSubnet DHCP pool

**Symptom:**

```
level=error msg=failed to fetch Metadata: failed to load asset "Install Config": failed to create install config: [platform.openstack.apiVIPs: Invalid value: "10.0.0.5": apiVIP can not fall in a MachineNetwork allocation pool, platform.openstack.ingressVIPs: Invalid value: "10.0.0.7": ingressVIP can not fall in a MachineNetwork allocation pool]
```

**Cause:** After pre-creating the machinesSubnet (P9 fix), the installer derives apiVIP=`.5` and ingressVIP=`.7` from the subnet's CIDR. Both must be **outside** the DHCP allocation pool, otherwise they could be handed out to a VM and conflict. Neutron's default `allocation_pools` covers the whole CIDR minus the gateway, so the validation fails.

**Fix:** Restrict the subnet's allocation pool to leave `10.0.0.0/24` free for the VIPs:

```yaml
- openstack.cloud.subnet:
    cidr: "10.0.0.0/16"
    allocation_pool_start: "10.0.1.0"
    allocation_pool_end:   "10.0.255.254"
```

DHCP leases now hand out from `10.0.1.x` onward, and the installer's default VIPs `10.0.0.5`/`10.0.0.7` are reserved.


## P11. OKD with `machinesSubnet` set switches to the terraform install path; quota for SecurityGroupRules is way higher than CAPI path needs

**Symptom:**

```
level=fatal msg="failed to fetch Cluster: failed to fetch dependency of "Cluster": failed to generate asset "Platform Quota Check": error(MissingQuota): SecurityGroupRule is not available because the required number of resources (56) is more than remaining quota of 48"
```

**Cause:** When `platform.openstack.machinesSubnet` is set (P9 fix), the OKD 4.22 installer takes a different code path than the default CAPI-only flow — it falls back to a terraform-generator path (`terraform.tfvars.json` shows up in `cluster-config/`). That path creates substantially more Neutron security group rules (around 56) than the CAPI path. The default 100-rule quota might still be tight if the default SG already has its baseline rules.

**Fix:** Bump `secgroup_rules` to 300 (and `secgroups` to 50 for headroom) in the OpenStack project quota. The `group_vars/all.yml` has these defaults; `02-project-network.yml` applies them.

**Note:** This is the same "the install path branches based on flags" behavior that complicates IaC. If you ever stop setting `machinesSubnet` (i.e. accept the default CAPI flow), the SG rule budget can drop back to ~30.

## P12. Stale `cluster-api/cluster-api` binary in cluster-config makes the next install attempt fail with `text file busy`

**Symptom:**

```
level=error msg="failed to fetch Cluster: failed to generate asset "Cluster": failed to create cluster: failed to run cluster api system: failed to run local control plane: failed to unpack cluster-api binary: failed to extract \"/home/ubuntu/projects/okd-on-openstack-lab/cluster-config/cluster-api/cluster-api\": open ... text file busy"
```

**Cause:** A previous `openshift-install create cluster` attempt extracted its CAPI controller binary into `cluster-config/cluster-api/` and left it running when the parent process was killed mid-run. The next attempt tries to overwrite that file, but the kernel returns ETXTBSY because the binary is still mapped in memory by the still-alive process.

**Fix:** Between attempts, kill any leftover processes and clear the directory:

```bash
pkill -9 -f "cluster-api-provider" || true
pkill -9 -f "openshift-install"   || true
pkill -9 -f "envtest"             || true
rm -rf cluster-config/cluster-api cluster-config/.clusterapi_output \
       cluster-config/manifests cluster-config/openshift cluster-config/auth \
       cluster-config/bootstrap.ign cluster-config/master.ign cluster-config/worker.ign \
       cluster-config/tls
rm -f cluster-config/install-config.yaml cluster-config/.openshift_install_state.json \
      cluster-config/metadata.json cluster-config/.openshift_install.log \
      cluster-config/05-create.log cluster-config/terraform.*.tfvars.json
```

(The destroy playbook will also do this implicitly via `openshift-install destroy cluster`.)

## P13. OKD-SCOS 4.22 bootstrap doesn't auto-trigger `release-image.service` → install hangs forever before bootkube starts

**Symptom (after P8/P9/P10 are all fixed):** Bootstrap VM boots SCOS, ignition succeeds, SSH works, DNS works, `podman pull` of the release image succeeds manually. But:

```
sudo systemctl is-active release-image.service   → inactive
sudo systemctl is-active node-image-pull.service → activating (looping)
sudo systemctl is-active bootkube.service        → inactive
sudo systemctl is-active kubelet.service         → inactive
```

The `node-image-pull.sh` loop calls `image_for stream-coreos` which runs `podman inspect quay.io/okd/scos-release@...`. The image isn't in podman's local storage yet because `release-image.service` (which pulls it) never started. Static unit with no auto-start trigger. Reverse-deps show only `crio-configure.service` and `kubelet.service` Want it — and those don't start either.

The installer's 20-min `wait-for kube-api` hard-fails because the bootkube control plane never starts.

**Workaround (manual unblock that we verified works):**

```bash
ssh core@<bootstrap-fip>
sudo podman pull quay.io/okd/scos-release@sha256:<digest>
sudo systemctl start release-image.service
```

After this, `node-image-pull.service` succeeds within seconds, then `bootkube` and `kubelet` start automatically and the cluster forms. But by then the installer's 20-min timer has already fired.

**Open question:** What is supposed to trigger `release-image.service` on a fresh boot? Currently unknown — looks like a regression in OKD-SCOS 4.22 service ordering, or a side effect of setting `platform.openstack.machinesSubnet` which alters the bootstrap's ignition payload. Reproduces on both auto-created and pre-created machinesSubnet paths.

**Next steps to investigate (future session):**
- Compare ignition payloads with and without `machinesSubnet` set
- Check upstream OKD 4.22 ignition templates for the missing trigger
- Try OKD 4.21 to see if it's a 4.22-specific regression
- Open an upstream issue at github.com/okd-project/okd


## P14. `openshift-install` extracts CAPI binaries with relative paths — must invoke with absolute `--dir`

**Symptom:**

```
level=error msg="failed to fetch Cluster: ... unable to start control plane itself: failed to start the controlplane. retried 5 times: fork/exec cluster-config/cluster-api/etcd: no such file or directory"
```

**Cause:** When the installer is invoked with a relative `--dir cluster-config`, the logged "extracting" path looks correct, but the subsequent `fork/exec` uses the relative path against a process CWD that has changed.

**Fix:** Always invoke with an absolute path: `openshift-install create cluster --dir /abs/path/to/cluster-config`. The Ansible 05-create-cluster.yml playbook already passes the absolute resolved path.

---

## P15. `openshift-install create cluster` panics (nil-pointer SIGSEGV) when bootstrap.ign was pre-generated and modified

**Symptom:**

```
level=info msg="Creating infra manifests..."
panic: runtime error: invalid memory address or nil pointer dereference
[signal SIGSEGV: segmentation violation code=0x1 addr=0xf0 pc=0x7315f5d]

goroutine 1 [running]:
github.com/openshift/installer/pkg/infrastructure/clusterapi.(*InfraProvider).Provision(...)
    /go/src/github.com/openshift/installer/pkg/infrastructure/clusterapi/clusterapi.go:184 +0xd1d
```

**Context:** This appeared while trying to bake in the P13 drop-in by:
1. `openshift-install create install-config`
2. `openshift-install create manifests`
3. `openshift-install create ignition-configs`
4. **Patch `bootstrap.ign`** to add the drop-in file
5. `openshift-install create cluster`

The installer crashes in `InfraProvider.Provision`. Looks like the asset store's state machine assumes "cluster" is always the next step after install-config and doesn't tolerate ignition-configs being pre-generated.

**Workaround (not yet tested):** rebake the SCOS Glance image to include the drop-in file at `/etc/systemd/system/node-image-pull.service.d/10-require-release-image.conf`. Reference the patched image via `clusterOSImage` in install-config. This avoids touching the installer's asset machinery.

```bash
sudo virt-customize -a scos-c10s-okd422-patched.qcow2 \
  --mkdir /etc/systemd/system/node-image-pull.service.d \
  --upload /tmp/dropin:/etc/systemd/system/node-image-pull.service.d/10-require-release-image.conf
```

Then `openstack image create scos-c10s-okd422-patched` and use it.

This is also the correct path long-term: bake substrate-specific patches into the image, not into the install pipeline.

