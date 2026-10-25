#!/bin/sh
# Live cluster tests. Needs the Policy CRD only — not the cedar-access-control
# webhook, controller, or in-cluster cedar binary.
#
# Opt-in: CEDAR_K9S_CLUSTER_TESTS=1. Runs against CEDAR_K9S_CONTEXT, or a
# kind-* context when unset, so a real cluster is never touched by default.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
export CEDAR_K9S_PAUSE=0 CEDAR_K9S_STRICT=1
LABEL="k9s-cedar-plugin-test=1"
FAIL=0
PREFIX="k9s-cedar-t"
CREATED_CRD=0

ok() { printf 'ok  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

if [ "${CEDAR_K9S_CLUSTER_TESTS:-0}" != "1" ]; then
  printf 'skip cluster: set CEDAR_K9S_CLUSTER_TESTS=1 to run\n'
  exit 0
fi

if [ -d "${HOME}/.cargo/bin" ]; then
  PATH="${HOME}/.cargo/bin:${PATH}"
  export PATH
fi

if ! command -v kubectl >/dev/null 2>&1; then
  printf 'skip cluster: kubectl not installed\n'
  exit 0
fi
if ! command -v cedar >/dev/null 2>&1; then
  printf 'skip cluster: cedar not installed\n'
  exit 0
fi
CONTEXT="${CEDAR_K9S_CONTEXT:-}"
if [ -z "$CONTEXT" ]; then
  current=$(kubectl config current-context 2>/dev/null || true)
  case "$current" in
    kind-*) CONTEXT=$current ;;
    *) CONTEXT=$(kubectl config get-contexts -o name 2>/dev/null | grep '^kind-' | head -n 1 || true) ;;
  esac
fi
if [ -z "$CONTEXT" ]; then
  printf 'skip cluster: no kind-* context (set CEDAR_K9S_CONTEXT)\n'
  exit 0
fi
if ! kubectl --context "$CONTEXT" get --raw=/healthz >/dev/null 2>&1; then
  printf 'skip cluster: context %s not reachable\n' "$CONTEXT"
  exit 0
fi

cleanup() {
  kubectl --context "$CONTEXT" delete policies.cedar.k8s.aws -l "$LABEL" --ignore-not-found >/dev/null 2>&1 || true
  if [ "$CREATED_CRD" -eq 1 ]; then
    kubectl --context "$CONTEXT" delete crd policies.cedar.k8s.aws --ignore-not-found >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

if ! kubectl --context "$CONTEXT" get crd policies.cedar.k8s.aws >/dev/null 2>&1; then
  kubectl --context "$CONTEXT" apply -f "$ROOT/examples/crd.yaml" >/dev/null
  CREATED_CRD=1
  kubectl --context "$CONTEXT" wait --for=condition=Established --timeout=60s crd/policies.cedar.k8s.aws >/dev/null
  ok "applied CRD snapshot"
else
  ok "CRD already present"
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/cedar-cluster.XXXXXX")
YAML="$TMP/yaml"
mkdir -p "$YAML"
INDEX="$TMP/index.txt"
trap 'cleanup; rm -rf "$TMP"' EXIT INT TERM

python3 - "$YAML" "$PREFIX" "$INDEX" << 'PY'
import pathlib, sys
out = pathlib.Path(sys.argv[1])
prefix = sys.argv[2]
index_path = pathlib.Path(sys.argv[3])

# These fixtures cannot affect real Kubernetes requests even if a Cedar
# authorizer watches this cluster: they use impossible test-only principals,
# and the malformed policy never parses.
fixtures = [
    ("ok", "safe", '''permit (
  principal == k8s::User::"__k9s_cedar_plugin_test__",
  action == k8s::Action::"get",
  resource is k8s::Resource
) when {
  resource.resource == "__k9s_cedar_plugin_test__"
};'''),
    ("ok", "typed-view", '''permit (
  principal is User,
  action == Action::"view",
  resource is Photo
);'''),
    ("fail", "parse-fail", '''permit (
  principal
  action
  resource
);'''),
]

manifests = []
for kind, suffix, content in fixtures:
    cr = f"{prefix}-{suffix}"
    indented = "\n".join(("    " + line) if line else "" for line in content.splitlines())
    yaml = f"""apiVersion: cedar.k8s.aws/v1alpha1
kind: Policy
metadata:
  name: {cr}
  labels:
    k9s-cedar-plugin-test: "1"
spec:
  validation:
    enforced: false
  content: |
{indented}
"""
    (out / f"{cr}.yaml").write_text(yaml + "\n")
    manifests.append((kind, cr))
index_path.write_text("\n".join(f"{k} {n}" for k, n in manifests) + "\n")
PY

kubectl --context "$CONTEXT" apply -f "$YAML" >/dev/null
ok "applied fixture Policies"

export RESOURCE_GROUP=cedar.k8s.aws RESOURCE_VERSION=v1alpha1 RESOURCE_NAME=policies CONTEXT
ok_name=""
fail_name=""
while read -r kind cr; do
  [ -n "${kind:-}" ] || continue
  NAME=$cr
  export NAME
  if [ "$kind" = "ok" ]; then
    if [ -z "$ok_name" ]; then
      ok_name=$cr
    fi
    if "$ROOT/plugin.sh" check-parse >/tmp/cedar-cl-ok.out 2>&1; then
      ok "cluster check-parse $cr"
    else
      fail "cluster check-parse $cr"
      cat /tmp/cedar-cl-ok.out
    fi
  else
    fail_name=$cr
    if "$ROOT/plugin.sh" check-parse >/tmp/cedar-cl-fail.out 2>&1; then
      fail "cluster check-parse should fail $cr"
    else
      ok "cluster check-parse fail $cr"
    fi
  fi
done <"$INDEX"

NAME=$ok_name
export NAME
if "$ROOT/plugin.sh" format >/tmp/cedar-cl-fmt.out 2>&1; then
  ok "cluster format $ok_name"
else
  fail "cluster format $ok_name"
  cat /tmp/cedar-cl-fmt.out
fi

if "$ROOT/plugin.sh" scan >/tmp/cedar-cl-scan.out 2>&1; then
  if grep -q 'PARSE_FAIL' /tmp/cedar-cl-scan.out && grep -q 'OK' /tmp/cedar-cl-scan.out; then
    ok "cluster scan mixed"
  else
    fail "cluster scan expected OK and PARSE_FAIL"
    cat /tmp/cedar-cl-scan.out
  fi
else
  fail "cluster scan"
  cat /tmp/cedar-cl-scan.out
fi

NAME=$ok_name
export NAME CEDAR_SCHEMA="$ROOT/tests/fixtures/schema/tiny.cedarschema"
while read -r kind cr; do
  [ -n "${kind:-}" ] || continue
  case "$cr" in
    *typed-view*)
      NAME=$cr
      export NAME
      if "$ROOT/plugin.sh" validate >/tmp/cedar-cl-val.out 2>&1; then
        ok "cluster validate $cr"
      else
        fail "cluster validate $cr"
        cat /tmp/cedar-cl-val.out
      fi
      ;;
  esac
done <"$INDEX"
unset CEDAR_SCHEMA

if [ "$FAIL" -ne 0 ]; then
  printf '%s cluster tests failed\n' "$FAIL"
  exit 1
fi
printf 'cluster tests passed\n'
