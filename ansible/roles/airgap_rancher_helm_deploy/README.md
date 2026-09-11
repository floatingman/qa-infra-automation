# airgap_rancher_helm_deploy Role

Deploys Rancher onto an (airgap) RKE2/K3s cluster using Helm, via a bastion host with
`kubectl` configured. Installs Helm and cert-manager if needed, installs/upgrades the
Rancher chart, and waits for the deployment to become ready.

## Requirements

- Bastion host with `kubectl` configured (`kubeconfig_path`)
- `python3-pip`, `python3-kubernetes`, `python3-yaml` on the bastion
- The `kubernetes.core` Ansible collection
- RKE2/K3s cluster already installed and reachable from the bastion

## Role Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `install_helm` | `true` | Install Helm 3 on the bastion if not present |
| `helm_version` | `v3.12.3` | Helm version to install |
| `kubeconfig_path` | `/home/{{ ansible_user }}/.kube/config` | Kubeconfig used for all Helm/kubectl calls |
| `rancher_namespace` | `cattle-system` | Namespace Rancher is deployed into |
| `rancher_helm_chart_repo_url` | `https://releases.rancher.com/server-charts/latest` | Rancher Helm chart repository URL |
| `rancher_helm_chart_repo_name` | `rancher-latest` | Name to register the chart repository under |
| `rancher_chart_version` | `""` | Pin a specific chart version (empty = latest) |
| `rancher_bootstrap_password` | `admin` | Bootstrap password set during Helm install |
| `rancher_image_tag` | _(unset)_ | Rancher image tag/version to deploy (e.g. `v2.12.2`) |
| `rancher_private_hostname` / `rancher_hostname` | _(unset)_ | Hostname used in the Rancher ingress/UI |
| `rancher_use_bundled_system_charts` | `true` | Use bundled system charts (`useBundledSystemChart`) |
| `rancher_tls_source` | `rancher` | TLS source: `rancher`, `letsEncrypt`, or `secret` |
| `cert_manager_version` | `""` | cert-manager chart version (SemVer, no `v`); empty = latest. When pinned (non-empty) in airgap, the cert-manager image preflight runs |
| `rancher_system_default_registry` | `""` | **Airgap:** private registry passed to the chart as the top-level `systemDefaultRegistry` value (may include a project path, e.g. `host/proxycache`) |
| `rancher_image_repository` | `rancher/rancher` | **Airgap:** image repo passed as the chart's `image.repository`, without the registry host |
| `rancher_preflight_verify_image` | `true` | Verify the Rancher server image (and the cert-manager images, in airgap with a pinned `cert_manager_version`) is present in the private registry before installing |
| `rancher_preflight_mode` | `api` | Preflight method: `api` (v2 manifest GET) or `pull` (`skopeo inspect`) |
| `cert_manager_preflight_images` | `[controller, webhook, cainjector, startupapicheck]` | cert-manager images checked by the preflight; add `acmesolver` for `rancher_tls_source=letsEncrypt` |
| `rancher_advanced_values` | `{}` | Extra Helm values merged into the Rancher release |

### `rancher_system_default_registry` (airgap)

Set this to your private registry URL **without a scheme** (e.g.
`privateregistry.example.com:5000`). When non-empty it is passed to the Rancher Helm chart
as the **top-level** `systemDefaultRegistry` value, which the chart uses at **install
 time** for two things:

1. It builds the **Rancher server pod image** as
   `<systemDefaultRegistry>/<image.repository>:<rancherImageTag>`. (The chart reads the
   *top-level* `systemDefaultRegistry` for this — `global.cattle.systemDefaultRegistry`
   is ignored for the server image.)
2. It sets the in-cluster `system-default-registry` setting, which rewrites Rancher's
   system images — including the `shell-image` setting (`rancher/shell:<tag>`, used by any
   Rancher feature that runs a `kubectl`/rancher-shell job) — to
   `<registry>/rancher/shell:<tag>`.

`image.repository` defaults to `rancher/rancher` (see `rancher_image_repository`); override
it only if your registry serves the image under a different repo.

This is **required for airgap**: without it, the chart keeps its default registry
(`registry.rancher.com`) for the server image and `shell-image` stays as the public
`rancher/shell:<tag>` reference — neither can be pulled, causing `ImagePullBackOff` /
broken shell jobs (for example the `WorkloadUpgradeTest` deployment-rollback path in
`rancher/tests`, failing with a misleading `resource name may not be empty`).

Notes:

- `shell-image` is seeded from `system-default-registry` at **Rancher startup** and is
  **not** rewritten when the setting is changed post-install, so it must be set at deploy
  time (which is what this variable does) — patching it after the fact requires a Rancher
  restart.
- `rancher/shell:<tag>` must exist at `<registry>/rancher/shell:<tag>`. Containerd registry
  *mirrors* (e.g. `docker.io` → `proxycache/...`) do not cover this verbatim reference, so
  the image must be mirrored to the registry root.
- **Harbor pull-through proxy:** if `docker.io` is mirrored under a project (e.g.
  `docker.io/*` → `host/proxycache/*`), include the project in this value
  (`host/proxycache`) and keep `rancher_image_repository` as the bare repo
  (`rancher/rancher`). The chart then pulls `host/proxycache/rancher/rancher:<tag>` — a
  *direct* registry pull that the containerd mirror does not rewrite — so the image must
  exist at that exact path. The registry preflight resolves credentials by matching either
  the full `host/project` string **or** the bare host against `private_registry_configs`,
  and builds the v2 manifest URL as `https://<host>/v2/[<project>/]<repo>/manifests/<tag>`.
- Leave empty for internet-connected deployments (the chart treats `""` as no registry).

### cert-manager image preflight (airgap)

The role installs the jetstack cert-manager chart with default values, so its pods
reference `quay.io/jetstack/cert-manager-<component>:v<version>` **verbatim** — unlike
the Rancher server image, they are not rewritten to the private registry. Kubelet
resolves them through the node-level containerd mirror: the `quay.io` entry of
`private_registry_mirrors`, typically a Harbor pull-through cache reached via the
rewrite rules (e.g. `quay.io/*` → `host/quaycache/*`).

When `rancher_system_default_registry` and `cert_manager_version` are both set, a
second preflight (after the Rancher image one) verifies those images through the exact
same resolution path: it takes the endpoint from the `quay.io` mirror entry, applies
each rewrite rule to the `jetstack` repository path, and checks
`<endpoint>/v2/<rewritten-path>/cert-manager-<component>:v<version>` for every image
in `cert_manager_preflight_images` (chart version and image tag are identical for all
cert-manager releases to date).

Outcomes:

- **200** — proceed.
- **404** — fail fast: the image is not in the registry. Mirror it from an
  internet-connected host (`docker pull <host>/<project>/cert-manager-<component>:<tag>`
  pulls *through* the proxy and warms the cache), or — if your registry fetches on
  demand — install `skopeo` and set `rancher_preflight_mode=pull` to exercise the real
  pull path, or skip the check with `rancher_preflight_verify_image=false`.
- **HTTP 5xx** (e.g. Harbor's `502 Bad Gateway`) — fail fast: the registry is up but
  its pull-through fetch toward quay.io failed; kubelet would fail identically. Fix
  the registry's quay.io proxy cache (egress / upstream config) before re-running.
- **401/403/unreachable** — warn and continue (the check could not run).

The check is skipped when `cert_manager_version` is empty (chart tag unknowable), when
`rancher_tls_source=secret` (no cert-manager install), or when no `quay.io` mirror is
configured (pods pull quay.io directly).


## Example

```yaml
# group_vars/all.yml
deploy_rancher: true
install_helm: true

rancher_hostname: "rancher.example.com"
rancher_bootstrap_password: "your-secure-password"
rancher_image_tag: v2.12.2
rancher_use_bundled_system_charts: true

# Airgap: private registry hosting the Rancher server image and system images.
# For a Harbor pull-through proxy, include the project path, e.g.
#   rancher_system_default_registry: "harbor.example.com/proxycache"
rancher_system_default_registry: "privateregistry.example.com:5000"
# Rancher image repo without the registry host (default rancher/rancher)
rancher_image_repository: "rancher/rancher"
```

```bash
ansible-playbook -i inventory/inventory.yml \
  ansible/rke2/airgap/playbooks/deploy/rancher-helm-deploy-playbook.yml
```

## Helm values applied

The role installs Rancher with (roughly):

```yaml
hostname: "{{ rancher_private_hostname }}"
bootstrapPassword: "{{ rancher_bootstrap_password }}"
useBundledSystemChart: "{{ rancher_use_bundled_system_charts }}"
rancherImageTag: "{{ rancher_image_tag }}"
ingress:
  tls:
    source: "{{ rancher_tls_source }}"
# Top-level systemDefaultRegistry is what the chart reads for the server image registry
# (<systemDefaultRegistry>/<image.repository>:<tag>) and uses to set
# CATTLE_SYSTEM_DEFAULT_REGISTRY. global.cattle.systemDefaultRegistry is ignored for
# the server image.
systemDefaultRegistry: "{{ rancher_system_default_registry }}"
image:
  repository: "{{ rancher_image_repository }}"
```

## Related

- Deploy playbook: [`ansible/rke2/airgap/playbooks/deploy/rancher-helm-deploy-playbook.yml`](../../rke2/airgap/playbooks/deploy/rancher-helm-deploy-playbook.yml)
- Airgap guide: [`ansible/rke2/airgap/README.md`](../../rke2/airgap/README.md)
