#!/bin/sh
# Live cluster tests. Needs the Policy CRD only — not the cedar-access-control
# webhook, controller, or in-cluster cedar binary.
#
# Skip unless kubectl can reach CONTEXT (default k8s-dev).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
export CEDAR_K9S_PAUSE=0 CEDAR_K9S_STRICT=1
CONTEXT="${CEDAR_K9S_CONTEXT:-k8s-dev}"
LABEL="k9s-cedar-plugin-test=1"
FAIL=0
PREFIX="k9s-cedar-t"

ok() { printf 'ok  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

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
if ! kubectl --context "$CONTEXT" get --raw=/healthz >/dev/null 2>&1; then
  printf 'skip cluster: context %s not reachable\n' "$CONTEXT"
  exit 0
fi

cleanup() {
  kubectl --context "$CONTEXT" delete policies.cedar.k8s.aws -l "$LABEL" --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

if ! kubectl --context "$CONTEXT" get crd policies.cedar.k8s.aws >/dev/null 2>&1; then
  kubectl --context "$CONTEXT" apply -f "$ROOT/examples/crd.yaml" >/dev/null
  ok "applied CRD snapshot"
else
  ok "CRD already present"
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/cedar-cluster.XXXXXX")
YAML="$TMP/yaml"
mkdir -p "$YAML"
INDEX="$TMP/index.txt"
trap 'cleanup; rm -rf "$TMP"' EXIT INT TERM

python3 - "$ROOT" "$YAML" "$PREFIX" "$INDEX" << 'PY'
import pathlib, sys, re
root = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])
prefix = sys.argv[3]
index_path = pathlib.Path(sys.argv[4])

def name(stem: str) -> str:
    s = re.sub(r"[^a-z0-9-]", "-", stem.lower())
    s = re.sub(r"-+", "-", s).strip("-")
    n = f"{prefix}-{s}"
    return n[:63].rstrip("-")

manifests = []
dirs = (("ok", "parse-ok"), ("ok", "validate-ok"), ("fail", "parse-fail"))
seen = set()
for kind, directory in dirs:
    for f in sorted((root / "tests/fixtures" / directory).glob("*.cedar")):
        cr = name(f"{kind}-{f.stem}")
        if cr in seen:
            continue
        seen.add(cr)
        content = f.read_text()
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

export CEDAR_PRINCIPAL=alice CEDAR_ACTION=view CEDAR_RESOURCE=x
if "$ROOT/plugin.sh" can-i >/tmp/cedar-cl-cani.out 2>&1; then
  # Fixture set includes unconstrained forbid, which overrides permit (Cedar forbid-wins).
  if grep -q '^DENY ' /tmp/cedar-cl-cani.out && grep -q 'forbid-unconstrained' /tmp/cedar-cl-cani.out; then
    ok "cluster can-i DENY (forbid overrides)"
  else
    fail "cluster can-i expected DENY from forbid-unconstrained"
    cat /tmp/cedar-cl-cani.out
  fi
else
  fail "cluster can-i"
  cat /tmp/cedar-cl-cani.out
fi
unset CEDAR_PRINCIPAL CEDAR_ACTION CEDAR_RESOURCE

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
