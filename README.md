# OKD on OpenStack — office1 lab IaC

Repeatable Ansible-based deploy of a 3-node compact [OKD 4.22](https://github.com/okd-project/okd) cluster on the office1 Kolla-Ansible OpenStack lab, with all artifacts cached through the *.cloudinative.com Nexus mirror.

## Scope

- Office1 lab OpenStack (Kolla-Ansible 2025.1) is the only target. No DC, no public cloud.
- OKD-SCOS (CentOS Stream CoreOS) variant — 4.22.0-okd-scos.0 at the time of writing.
- Topology: 3-node compact (3 control-plane nodes, 0 standalone workers; CP nodes carry workloads).
- Tenant: dedicated `okd` OpenStack project for clean residue boundaries.

## Lab prerequisites

These are already in place on this lab as a consequence of the D-1 substrate repair and the Ceph RBD Cinder migration. If you reproduce on a fresh lab, you need:

- Kolla `kolla_external_vip_interface=br-ex` (D-1 fix; ext0 is OVS-enslaved, IPs live on br-ex).
- Cinder type `ceph` (rbd-1#rbd-1) available and enabled across all controllers.
- `okd.large` flavor (4 vCPU / 16 GiB RAM / 100 GB disk).
- SCOS qcow2 in Glance as `scos-c10s-okd422` (or whatever is current; `roles/okd_glance` will upload if missing).
- `*.cloudinative.com` hosts entries in `/etc/hosts` on the deploy host.
- Lab controllers each with ≥8 GiB swap (S-2 mitigation; OKD install is memory-spiky).

## Repo layout

```
ansible/
  inventory/          # localhost runner that drives OpenStack API
  group_vars/         # cluster config (name, base domain, flavor, FIPs)
  playbooks/          # 00..06 ordered playbooks + 99 destroy
  roles/              # reusable bits
terraform/            # alternative Terraform path (deferred)
scripts/              # helpers (warm-nexus.sh, bootstrap-lab.sh)
docs/                 # architecture + nexus mirror notes
```

## Quickstart

```bash
# from a deploy host with /etc/hosts pointing *.cloudinative.com → 176.65.243.214
# and clouds.yaml at /etc/openstack/clouds.yaml (or env OS_CLIENT_CONFIG_FILE)

ansible-galaxy collection install -r requirements.yml
ansible-playbook -i ansible/inventory/lab.yml ansible/playbooks/00-preflight.yml
ansible-playbook -i ansible/inventory/lab.yml ansible/playbooks/01-glance-image.yml
ansible-playbook -i ansible/inventory/lab.yml ansible/playbooks/02-project-network.yml
ansible-playbook -i ansible/inventory/lab.yml ansible/playbooks/03-fips.yml
ansible-playbook -i ansible/inventory/lab.yml ansible/playbooks/04-install-config.yml
ansible-playbook -i ansible/inventory/lab.yml ansible/playbooks/05-create-cluster.yml
ansible-playbook -i ansible/inventory/lab.yml ansible/playbooks/06-post-install.yml
```

Teardown:

```bash
ansible-playbook -i ansible/inventory/lab.yml ansible/playbooks/99-destroy.yml
```

## Nexus mirror warming

`scripts/warm-nexus.sh` pulls the CaaS image set in `scripts/caas-images.txt` through `docker.cloudinative.com`, caching each image in the Nexus proxy on `artifact` (172.17.17.118). See `docs/NEXUS-MIRROR.md`.

## Why 3-node compact, not SNO

SNO needs ≥8 vCPU and ≥120 GB disk per the OKD docs. The current `okd.large` flavor (4 vCPU, 16 GiB, 100 GB) is below the SNO floor on CPU and disk. 3-node compact also exercises the HA-ish control-plane bits, which is a better PaaS substrate proof.

## License

MIT (see `LICENSE` once added).
