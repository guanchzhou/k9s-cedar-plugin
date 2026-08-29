# k9s Cedar plugin

k9s plugin for cluster-scoped Cedar `Policy` objects (`cedar.k8s.aws/v1alpha1`).

This is YAML plus a small POSIX glue script. It does not ship a new CLI. Analysis uses the official `cedar` binary from [cedar-policy-cli](https://github.com/cedar-policy/cedar/tree/main/cedar-policy-cli) and `kubectl`.

The Kubernetes CRD comes from [cedar-access-control-for-k8s](https://github.com/cedar-policy/cedar-access-control-for-k8s), which is an unmaintained proof of concept. Treat it as a frozen snapshot.

## Requires (on PATH)

- [k9s](https://github.com/derailed/k9s)
- `kubectl`
- `cedar` (`cargo install cedar-policy-cli`, or a `cedar-policy-cli-v*` release from https://github.com/cedar-policy/cedar/releases)

## Install

```sh
./install.sh
```

Writes snippets to `$XDG_CONFIG_HOME/k9s/plugins/cedar/` and appends CRD columns to `views.yaml` if missing. Adds a `cedarpol` alias without replacing existing `aliases.yaml` entries. Existing plugins in `plugins.yaml` are left unchanged. Plugin dirs are documented at https://k9scli.io/topics/plugins/.

Restart k9s (or re-enter the view).

## Open Cedar, not Kyverno

`:policies` is Kyverno Policy (`policies.kyverno.io`). Both CRDs use the plural `policies`, so that command does not open Cedar.

Use one of:

- `:cedarpol` (added by install)
- `:policies.cedar.k8s.aws`
- `:cedar.k8s.aws/v1alpha1/policies`

Plugin shortcuts are scoped to those Cedar-only aliases, not to `policies`, so they do not appear on the Kyverno view.

| Shortcut | Action |
|----------|--------|
| Shift-C | `cedar format` on `spec.content` |
| Shift-P | `cedar check-parse` |
| Shift-V | `cedar validate` (needs `CEDAR_SCHEMA` or the schema input) |
| Shift-A | list all Cedar Policy objects and check-parse each (max 1000, 256 KiB each). `override: true` so it wins over k9s Aliases on this view. |

Wrong GVR is still refused by `plugin.sh` if a shortcut is invoked off the Cedar view.

## Schema

Validation is optional. Set `CEDAR_SCHEMA` to a `.cedarschema` file, or type the path in the Shift-V prompt. Bundled Kubernetes schemas in the upstream repo are not auto-loaded.

`cedar authorize` is not wired: the CRD has no entities or request.

## RBAC

See `k9s/rbac.yaml` (`get`/`list` on `policies.cedar.k8s.aws`).

## Tests

Offline (Cedar fixtures + mock kubectl) always. Cluster tests run when `k8s-dev` (or `CEDAR_K9S_CONTEXT`) is reachable. They apply the Policy **CRD snapshot only** — not the cedar-access-control webhook.

```sh
./tests/test-plugin.sh
# or separately:
./tests/test-offline.sh
./tests/test-cluster.sh
```

## What to install in the cluster

For this plugin: **the CRD and Policy objects**. Nothing else.

```sh
kubectl apply -f examples/crd.yaml
kubectl apply -f examples/policy-ok.yaml -f examples/policy-bad.yaml
```

You do **not** install:

- the cedar-access-control-for-k8s admission/authorization webhooks or controller
- a `cedar` binary inside the cluster
- Cedar schemas as Kubernetes objects (Shift-V uses a file on the laptop via `CEDAR_SCHEMA`)

Those webhooks are how the PoC *enforces* policies. The plugin only *reads* `Policy` CRs and runs `cedar` on your Mac. `spec.validation` on the CR is a CRD-required field; this plugin does not enforce it.

## Demo cluster (kind / `container k8s`)

The CRD snapshot and two sample Policies are under `examples/`. `spec.validation` is required by the CRD.

```sh
kubectl apply -f examples/crd.yaml
kubectl apply -f examples/policy-ok.yaml -f examples/policy-bad.yaml
kubectl get policies.cedar.k8s.aws
```

Then in k9s: `:cedarpol`. Shift-P on `permit-all` should parse; `parse-fail` should not.

`plugin.sh` prepends `~/.cargo/bin` when that directory exists, so k9s started from the macOS GUI can still find `cedar`.
