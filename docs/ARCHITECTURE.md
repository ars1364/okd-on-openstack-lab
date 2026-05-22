# Architecture — OKD 3-node compact on office1 Kolla lab

## Why this exists

Repeatable substrate proof that a Kolla-Ansible OpenStack lab can host an OKD cluster end-to-end. The PaaS/IaaS boundary is the only thing being validated — the rest of the lab work (D-1 substrate fix, Ceph RBD Cinder migration, KaaS lifecycle) is pre-requisite.

## Topology

```
                              ext-net (provider 192.168.206.0/24)
                                     │
                          ┌──────────┴──────────┐
                          │                     │
                  api-FIP (192.168.206.x)   ingress-FIP (192.168.206.y)
                          │                     │
                          ▼                     ▼
            ┌──────────────────────────────────────────────┐
            │       OVN Neutron router (api+ingress)        │
            │                                              │
            │  ┌──────────┐  ┌──────────┐  ┌──────────┐    │
            │  │   master │  │   master │  │   master │    │   compact 3-node:
            │  │     0    │  │     1    │  │     2    │    │   masters are also
            │  │ schedul. │  │ schedul. │  │ schedul. │    │   schedulable
            │  └────┬─────┘  └────┬─────┘  └────┬─────┘    │
            │       │             │             │          │
            │  rbd-1 root vol   rbd-1 root vol   rbd-1 root vol
            │                                              │
            └──────────────────────────────────────────────┘
                          machine-net 10.0.0.0/16
                          (created by installer)
```

- Bootstrap node is created by the installer, used to bring up etcd + the initial kube-apiserver, then auto-destroyed.
- Each master has a Cinder boot volume of size `okd_root_volume_gb` (default 30 GiB) on the `ceph` (rbd-1#rbd-1) volume type.
- OVNKubernetes is the CNI. Cluster network 10.128.0.0/14, service network 172.30.0.0/16.

## Why 3-node compact

OKD's SNO mode requires 8 vCPU and 120 GB disk per node; the `okd.large` flavor (4/16/100) falls below both. 3-node compact is the smallest production-pattern topology that fits the lab.

## OpenStack tenancy

Cluster lives in a dedicated `okd` Keystone project. Quotas (`group_vars/all.yml`):

| Resource | Limit |
|---|---|
| cores | 32 |
| ram (MB) | 81920 |
| volumes | 30 |
| gigabytes | 800 |
| floating_ips | 10 |
| networks/subnets/routers | 10/10/5 |

Project-scope means residue audit at teardown is just "list everything in okd project; everything should be gone".

## Substrate dependencies (must be in place)

| Item | Source |
|---|---|
| `kolla_external_vip_interface=br-ex` | D-1 substrate fix |
| Cinder `ceph` type (rbd-1#rbd-1) | Ceph RBD migration |
| `okd.large` flavor | created by `02-project-network.yml` |
| SCOS qcow2 in Glance | uploaded by `01-glance-image.yml` |
| Lab-ctrl swap 8G each | S-2 mitigation |
| Public Keystone reachable from deploy host | D-1 substrate fix (br-ex) |

## Memory budget

Steady state: 3 × 16 GiB = 48 GiB. Peak (during bootstrap): 4 × 16 GiB = 64 GiB. Lab Nova reports ≈ 69 GiB free RAM after `capi-mgmt` is stopped; this fits with no oversubscription.

Inside the lab-ctrl VMs, the 8 GiB swap on each (S-2) is the safety net if the host-level Nova accounting and the guest-level OOM diverge under bursty allocation.

## Network ownership

- The installer creates the OKD tenant network + subnet + router + security groups inside the `okd` project.
- Two FIPs (`api`, `ingress`) are pre-allocated by `03-fips.yml` so the installer can wire them. Pinning a FIP value via `okd_api_floating_ip` / `okd_ingress_floating_ip` is supported (re-uses an existing FIP rather than allocating a new one).
- DNS for `api.okd.lab.cloudinative.com` and `*.apps.okd.lab.cloudinative.com` is the operator's responsibility — point a wildcard at the ingress FIP. For lab purposes, `/etc/hosts` pinning works.

## Image storage decision

Glance default backend stays `file` per the operator gate. SCOS image is uploaded once into Glance file store. Boot volumes are created on the rbd-1 Cinder backend, so first-boot involves a one-time qcow2 → RBD copy per node — about 3 minutes for a 1.67 GiB image times 4 nodes. Subsequent rolls reuse the cached image. Faster paths (RBD-backed Glance store, dedicated COW clone) are deliberately not in scope here.

## Teardown contract

`99-destroy.yml` invokes `openshift-install destroy cluster --dir cluster-config`. The installer reads `metadata.json` and deletes every tagged resource. The destroy playbook then audits the `okd` project for residue across servers, volumes, ports, FIPs, networks, routers, security groups. Anything that survives is a bug to investigate.
