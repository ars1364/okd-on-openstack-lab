# Nexus mirror — *.cloudinative.com

All container artifacts the OKD lab and any CaaS workloads consume should flow through the **Nexus** proxy on `artifact` (WG-mesh IP `172.17.17.118`), fronted by the K1Kloud edge reverse-proxy at `176.65.243.214`. This document captures what the mirror proxies and how to warm it.

## DNS / routing

The `cloudinative.com` zone has **no public A records**. Every consumer host pins the subdomain set in `/etc/hosts`:

```
176.65.243.214 archive.cloudinative.com security.cloudinative.com
176.65.243.214 docker.cloudinative.com ghcr.cloudinative.com quay.cloudinative.com gcr.cloudinative.com apt.cloudinative.com pypi.cloudinative.com npm.cloudinative.com nodejs.cloudinative.com
176.65.243.214 k8s.cloudinative.com artifact.cloudinative.com
```

K1Kloud edge nginx SNI-routes each subdomain to the right Nexus repository inside the WG mesh.

## Nexus repositories (proxy)

| Subdomain | Upstream | Use |
|---|---|---|
| `docker.cloudinative.com` | Docker Hub registry-1 | Public Docker images (CaaS / OKD pulled by users) |
| `quay.cloudinative.com` | quay.io | Quay-hosted images (OKD release images live here, e.g. quay.io/okd/scos-release) |
| `ghcr.cloudinative.com` | ghcr.io | GitHub Container Registry |
| `gcr.cloudinative.com` | gcr.io | Google Container Registry |
| `k8s.cloudinative.com` | registry.k8s.io | Kubernetes core images |
| `apt.cloudinative.com` | Ubuntu archive | apt packages |
| `pypi.cloudinative.com` | pypi.org | Python packages |
| `npm.cloudinative.com` | registry.npmjs.org | Node packages |
| `nodejs.cloudinative.com` | nodejs.org | Node binaries |
| `archive.cloudinative.com` | archive.ubuntu.com | Ubuntu archive |
| `security.cloudinative.com` | security.ubuntu.com | Ubuntu security |
| `artifact.cloudinative.com` | (Nexus self) | Direct Nexus UI/API |

Storage backend: Nexus on artifact, `/data/nexus` on `/dev/vdb` (2.0 TB, ~1.8 TB free).

## Warming

`scripts/warm-nexus.sh` reads `scripts/caas-images.txt` and `docker pull`s each entry. With the host docker daemon configured to use `https://docker.cloudinative.com/` as a registry-mirror, every pull hydrates the Nexus cache.

```bash
# /etc/docker/daemon.json on the warming host
{ "registry-mirrors": ["https://docker.cloudinative.com/"] }
```

Confirmed warm 2026-05-22: 42 popular CaaS images cached in one pass (3 retries fixed transient or tag-mismatch failures).

## Extending the list

Edit `scripts/caas-images.txt` and re-run `warm-nexus.sh`. Idempotent: already-cached images return instantly from Nexus.

## Things NOT mirrored today (and what would be needed)

- **OKD installer tar.gz** (openshift-install + oc) — currently pulled directly from `github.com/okd-project/okd/releases/...`. To mirror, create a "Raw HTTP" proxy repo in Nexus pointing at `github.com`, or upload to a `raw-hosted` repo manually.
- **SCOS qcow2 image** — currently pulled from `rhcos.mirror.openshift.com`. Same options as above for full disconnected installs.
- **OKD release images themselves** — quay.io/okd/scos-release@sha256:... If we want OKD itself to install from local mirror, use `oc adm release mirror` to push the entire release into a local registry; then point `install-config.yaml` at it via `imageContentSources`. This is the "disconnected install" path.

For lab purposes, the runtime images (which users actually pull frequently) are the high-value cache target; the install binaries are one-shot and can stay direct.
