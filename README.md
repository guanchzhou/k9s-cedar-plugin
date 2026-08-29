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

Writes `$XDG_CONFIG_HOME/k9s/plugins/cedar.yaml` (plugin defs) and `plugins/cedar/plugin.sh`. Appends CRD columns to `views.yaml` if missing. Adds a `cedarpol` alias without replacing existing `aliases.yaml` entries. Existing plugins in the root `plugins.yaml` are left unchanged.

k9s 0.51 validates directory files against `plugins.json` first, so `cedar.yaml` must start with a `plugins:` map. One invalid plugin file makes k9s drop **every** plugin shortcut. After install, **quit k9s and launch it again** (`:cedarpol` is not a restart). On the Cedar table, select a Policy row, then Shift-I.

## Open Cedar, not Kyverno

`:policies` is Kyverno Policy (`policies.kyverno.io`). Both CRDs use the plural `policies`, so that command does not open Cedar.

Use one of:

- `:cedarpol` (added by install)
- `:policies.cedar.k8s.aws`
- `:cedar.k8s.aws/v1alpha1/policies`

Plugin shortcuts are scoped to those Cedar-only aliases, not to `policies`, so they do not appear on the Kyverno view. They run in the background: the k9s table stays on screen. A one-line status is flashed at the bottom (`overwriteOutput`). Parse/validate failures are that status line (`parse-fail: PARSE_FAIL`), not a k9s error dialog. Details go to k9s logs. Restart k9s after install so it reloads `background: true`.

| Shortcut | Action |
|----------|--------|
| Shift-C | `cedar format` on `spec.content` |
| Shift-P | `cedar check-parse` |
| Shift-V | `cedar validate` (needs `CEDAR_SCHEMA` or the schema input) |
| Shift-A | list all Cedar Policy objects and check-parse each (max 1000, 256 KiB each). `override: true` so it wins over k9s Aliases on this view. |
| Shift-I | Cedar can-i: `cedar authorize` against parseable Policy CRs. Prompts are **P / A / R** (user, verb, resource), like `kubectl auth can-i`. Opens a slide-style report (`Can P do A on R?`). The k9s table stays; status line is `ALLOW  alice  get  pods`. |

Wrong GVR is still refused by `plugin.sh` if a shortcut is invoked off the Cedar view. Empty GVR is allowed: k9s often omits those env vars even on the Cedar view.

## Schema

Validation is optional. Set `CEDAR_SCHEMA` to a `.cedarschema` file, or type the path in the Shift-V prompt. Bundled Kubernetes schemas in the upstream repo are not auto-loaded.

Shift-I is `kubectl auth can-i` for Cedar, not Kubernetes RBAC. Prompts follow Lucas Käldström’s Cedar talks: **Can P do A on R?** Kubernetes verbs (`get`, `list`, `create`, …) plus an optional namespace become `k8s::User` / `k8s::Action` / `k8s::Resource` with RequestInfo attributes (`namespace`, `apiGroup`, `resource`). Short Cedar names (`alice`, `view`, `Photo/x`) stay `User` / `Action` / `Photo`. k9s allows at most five plugin inputs, so the dialog is user, verb, resource, namespace, API group. Put a real entity hierarchy in `CEDAR_ENTITIES` and a schema in `CEDAR_SCHEMA` if you need them. The readable result is an HTML slide written to `$TMPDIR/k9s-cedar-can-i.html` and opened beside k9s. The status flash is `ALLOW  alice  get  pods  ·  permit-all`. Unparseable CRs are skipped. This is not a relation graph and does not call `kubectl auth can-i`.

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
