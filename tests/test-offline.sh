#!/bin/sh
# Offline suite: Cedar language fixtures + plugin.sh against a mock kubectl.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
export CEDAR_K9S_PAUSE=0 CEDAR_K9S_STRICT=1
FAIL=0
FIXTURES="$ROOT/tests/fixtures"
SCHEMA="$FIXTURES/schema/tiny.cedarschema"
MOCK_BIN="$ROOT/tests/mocks"

ok() { printf 'ok  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

require_cedar() {
  if [ -d "${HOME}/.cargo/bin" ]; then
    PATH="${HOME}/.cargo/bin:${PATH}"
    export PATH
  fi
  if ! command -v cedar >/dev/null 2>&1; then
    printf 'cedar not installed; skip language fixtures\n'
    return 1
  fi
  return 0
}

# --- k9s YAML: never scope on Kyverno's policies alias ---
if grep -Eq '^[[:space:]]+- policies$' "$ROOT/k9s/plugins.yaml"; then
  fail "plugins.yaml scoped to policies (Kyverno collision)"
else
  ok "plugin scopes are Cedar-only"
fi
if grep -Eq '^[[:space:]]+- policy$' "$ROOT/k9s/plugins.yaml"; then
  fail "plugins.yaml scoped to policy"
else
  ok "plugin scopes omit bare policy"
fi
for alias in "cedar.k8s.aws/v1alpha1/policies" "policies.cedar.k8s.aws" "cedarpol"; do
  if grep -Fq -- "$alias" "$ROOT/k9s/plugins.yaml"; then
    ok "plugins.yaml has scope $alias"
  else
    fail "plugins.yaml missing scope $alias"
  fi
done
if grep -Eq '^[[:space:]]*background: false' "$ROOT/k9s/plugins.yaml"; then
  fail "plugins.yaml suspends k9s (background: false)"
else
  ok "plugins.yaml is background: true"
fi
if grep -Eq '^[[:space:]]*overwriteOutput: true' "$ROOT/k9s/plugins.yaml"; then
  ok "plugins.yaml overwriteOutput"
else
  fail "plugins.yaml missing overwriteOutput"
fi
if grep -Fq '$RESOURCE_GROUP' "$ROOT/k9s/plugins.yaml" && \
   grep -Fq '$RESOURCE_VERSION' "$ROOT/k9s/plugins.yaml" && \
   grep -Fq '$RESOURCE_NAME' "$ROOT/k9s/plugins.yaml"; then
  ok "plugins.yaml passes GVR args"
else
  fail "plugins.yaml missing GVR args"
fi
if grep -Fq 'cedar-can-i:' "$ROOT/k9s/plugins.yaml" && grep -Fq 'Shift-I' "$ROOT/k9s/plugins.yaml"; then
  ok "plugins.yaml has cedar-can-i"
else
  fail "plugins.yaml missing cedar-can-i"
fi
# k9s 0.51 ValidatePlugins tries plugins.json first. A directory file
# without this wrapper is rejected as "plugins is required", and one
# failed file makes k9s drop every plugin shortcut.
if grep -Eq '^plugins:' "$ROOT/k9s/plugins.yaml"; then
  ok "plugins.yaml has plugins: wrapper"
else
  fail "plugins.yaml missing plugins: wrapper (k9s 0.51)"
fi
# cedar-can-i is last; count its - name: entries (k9s inputs maxItems is 5).
cani_inputs=$(awk '
  $0 ~ /cedar-can-i:/ {p=1; n=0; next}
  p && $0 ~ /^[[:space:]]+- name:/ {n++}
  END {print n+0}
' "$ROOT/k9s/plugins.yaml")
if [ "$cani_inputs" -eq 0 ]; then
  fail "cedar-can-i has no inputs"
elif [ "$cani_inputs" -gt 5 ]; then
  fail "cedar-can-i has $cani_inputs inputs (k9s max 5)"
else
  ok "cedar-can-i inputs ($cani_inputs) within k9s max 5"
fi

# --- GVR guard (before cedar/kubectl) ---
RESOURCE_GROUP=example.com
RESOURCE_VERSION=v1
RESOURCE_NAME=policies
NAME=x
export RESOURCE_GROUP RESOURCE_VERSION RESOURCE_NAME NAME
if "$ROOT/plugin.sh" format >/tmp/cedar-plugin-gvr.out 2>&1; then
  fail "GVR guard should fail"
else
  if grep -q 'refusing GVR' /tmp/cedar-plugin-gvr.out; then
    ok "GVR guard"
  else
    fail "GVR guard message missing"
    cat /tmp/cedar-plugin-gvr.out
  fi
fi

if "$ROOT/plugin.sh" not-a-verb >/tmp/cedar-plugin-usage.out 2>&1; then
  fail "bad verb should fail"
else
  if grep -q 'usage:' /tmp/cedar-plugin-usage.out; then
    ok "usage on bad verb"
  else
    fail "usage message missing"
  fi
fi

if require_cedar; then
  for f in "$FIXTURES"/parse-ok/*.cedar; do
    base=$(basename "$f")
    if cedar check-parse --policies "$f" >/dev/null 2>&1; then
      ok "parse $base"
    else
      fail "parse $base"
      cedar check-parse --policies "$f" || true
    fi
    if cedar format --policies "$f" >/dev/null 2>&1; then
      ok "format $base"
    else
      fail "format $base"
    fi
  done
  for f in "$FIXTURES"/parse-fail/*.cedar; do
    base=$(basename "$f")
    if cedar check-parse --policies "$f" >/dev/null 2>&1; then
      fail "expected parse fail $base"
    else
      ok "parse-fail $base"
    fi
  done
  for f in "$FIXTURES"/validate-ok/*.cedar; do
    base=$(basename "$f")
    if cedar validate --schema "$SCHEMA" --policies "$f" >/dev/null 2>&1; then
      ok "validate $base"
    else
      fail "validate $base"
      cedar validate --schema "$SCHEMA" --policies "$f" || true
    fi
  done
  for f in "$FIXTURES"/validate-fail/*.cedar; do
    base=$(basename "$f")
    if cedar validate --schema "$SCHEMA" --policies "$f" >/dev/null 2>&1; then
      fail "expected validate fail $base"
    else
      ok "validate-fail $base"
    fi
  done

  MOCK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cedar-mock.XXXXXX")
  trap 'rm -rf "$MOCK_DIR"' EXIT INT TERM
  cp "$FIXTURES"/parse-ok/permit-unconstrained.cedar "$MOCK_DIR/permit-all.cedar"
  cp "$FIXTURES"/parse-fail/missing-commas.cedar "$MOCK_DIR/parse-fail.cedar"
  cp "$FIXTURES"/validate-ok/typed-view.cedar "$MOCK_DIR/typed-view.cedar"
  # 200-byte blob for size guard
  python3 -c 'import pathlib,sys; pathlib.Path(sys.argv[1]).write_text("permit (principal, action, resource);\n" + ("x" * 200) + "\n")' "$MOCK_DIR/too-big.cedar"

  PATH="$MOCK_BIN:$PATH"
  export PATH CEDAR_MOCK_DIR="$MOCK_DIR"
  RESOURCE_GROUP=cedar.k8s.aws
  RESOURCE_VERSION=v1alpha1
  RESOURCE_NAME=policies
  NAME=""
  export RESOURCE_GROUP RESOURCE_VERSION RESOURCE_NAME NAME
  if "$ROOT/plugin.sh" check-parse >/tmp/cedar-plugin-empty-name.out 2>&1; then
    fail "empty NAME should fail"
  else
    if grep -q 'NAME is empty' /tmp/cedar-plugin-empty-name.out; then
      ok "empty NAME"
    else
      fail "empty NAME message missing"
      cat /tmp/cedar-plugin-empty-name.out
    fi
  fi
  NAME=""
  export NAME
  if "$ROOT/plugin.sh" check-parse permit-all >/tmp/cedar-plugin-argv-name.out 2>&1; then
    ok "plugin check-parse NAME from argv"
  else
    fail "plugin check-parse NAME from argv"
    cat /tmp/cedar-plugin-argv-name.out
  fi
  NAME=permit-all
  export NAME
  if "$ROOT/plugin.sh" check-parse >/tmp/cedar-plugin-ok.out 2>&1; then
    if grep -q 'permit-all: parsed' /tmp/cedar-plugin-ok.out; then
      ok "plugin check-parse permit-all"
    else
      fail "plugin check-parse missing status line"
      cat /tmp/cedar-plugin-ok.out
    fi
  else
    fail "plugin check-parse permit-all"
    cat /tmp/cedar-plugin-ok.out
  fi
  if "$ROOT/plugin.sh" format >/tmp/cedar-plugin-fmt.out 2>&1; then
    if grep -q 'permit' /tmp/cedar-plugin-fmt.out; then
      ok "plugin format permit-all"
    else
      fail "plugin format missing permit"
      cat /tmp/cedar-plugin-fmt.out
    fi
  else
    fail "plugin format permit-all"
    cat /tmp/cedar-plugin-fmt.out
  fi

  NAME=parse-fail
  export NAME
  if "$ROOT/plugin.sh" check-parse >/tmp/cedar-plugin-bad.out 2>&1; then
    fail "plugin check-parse parse-fail should fail"
  else
    ok "plugin check-parse parse-fail"
  fi

  NAME=typed-view
  export NAME
  unset CEDAR_SCHEMA
  if "$ROOT/plugin.sh" validate >/tmp/cedar-plugin-noschema.out 2>&1; then
    fail "validate without schema should fail"
  else
    if grep -q 'no schema' /tmp/cedar-plugin-noschema.out; then
      ok "plugin validate requires schema"
    else
      fail "plugin validate missing schema message"
      cat /tmp/cedar-plugin-noschema.out
    fi
  fi
  CEDAR_SCHEMA="$SCHEMA"
  export CEDAR_SCHEMA
  if "$ROOT/plugin.sh" validate >/tmp/cedar-plugin-val.out 2>&1; then
    ok "plugin validate typed-view"
  else
    fail "plugin validate typed-view"
    cat /tmp/cedar-plugin-val.out
  fi
  unset CEDAR_SCHEMA

  if "$ROOT/plugin.sh" scan >/tmp/cedar-plugin-scan.out 2>&1; then
    if grep -q 'permit-all' /tmp/cedar-plugin-scan.out && grep -q 'PARSE_FAIL' /tmp/cedar-plugin-scan.out; then
      ok "plugin scan mixed results"
    else
      fail "plugin scan expected OK and PARSE_FAIL"
      cat /tmp/cedar-plugin-scan.out
    fi
  else
    fail "plugin scan"
    cat /tmp/cedar-plugin-scan.out
  fi

  unset CEDAR_PRINCIPAL CEDAR_ACTION CEDAR_RESOURCE
  if "$ROOT/plugin.sh" can-i >/tmp/cedar-plugin-cani-need.out 2>&1; then
    fail "can-i without principal should fail"
  else
    if grep -q 'need principal' /tmp/cedar-plugin-cani-need.out; then
      ok "plugin can-i requires principal"
    else
      fail "plugin can-i missing principal message"
      cat /tmp/cedar-plugin-cani-need.out
    fi
  fi
  CEDAR_PRINCIPAL=alice
  CEDAR_ACTION=view
  CEDAR_RESOURCE=x
  CEDAR_K9S_REPORT=/tmp/cedar-plugin-cani.html
  export CEDAR_PRINCIPAL CEDAR_ACTION CEDAR_RESOURCE CEDAR_K9S_REPORT
  if "$ROOT/plugin.sh" can-i >/tmp/cedar-plugin-cani-allow.out 2>&1; then
    if grep -q '^ALLOW ' /tmp/cedar-plugin-cani-allow.out && grep -q 'permit-all' /tmp/cedar-plugin-cani-allow.out; then
      ok "plugin can-i ALLOW"
    else
      fail "plugin can-i expected ALLOW from permit-all"
      cat /tmp/cedar-plugin-cani-allow.out
    fi
    if grep -q 'Can P do A on R' "$CEDAR_K9S_REPORT" && grep -q 'UserInfo' "$CEDAR_K9S_REPORT"; then
      ok "plugin can-i HTML report"
    else
      fail "plugin can-i HTML report missing"
    fi
  else
    fail "plugin can-i ALLOW"
    cat /tmp/cedar-plugin-cani-allow.out
  fi
  CEDAR_ACTION=get
  CEDAR_RESOURCE=pods
  CEDAR_NAMESPACE=default
  CEDAR_K9S_REPORT=/tmp/cedar-plugin-cani-k8s.html
  export CEDAR_ACTION CEDAR_RESOURCE CEDAR_NAMESPACE CEDAR_K9S_REPORT
  if "$ROOT/plugin.sh" can-i >/tmp/cedar-plugin-cani-k8s.out 2>&1; then
    if grep -q '^ALLOW ' /tmp/cedar-plugin-cani-k8s.out && grep -q 'k8s::Action' /tmp/cedar-plugin-cani-k8s.html; then
      ok "plugin can-i k8s RequestInfo mapping"
    else
      fail "plugin can-i k8s mapping"
      cat /tmp/cedar-plugin-cani-k8s.out
    fi
  else
    fail "plugin can-i k8s"
    cat /tmp/cedar-plugin-cani-k8s.out
  fi
  unset CEDAR_NAMESPACE
  CEDAR_ACTION=view
  CEDAR_RESOURCE=x
  CEDAR_K9S_REPORT=/tmp/cedar-plugin-cani-deny.html
  export CEDAR_ACTION CEDAR_RESOURCE CEDAR_K9S_REPORT
  FORBID_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cedar-forbid.XXXXXX")
  cp "$FIXTURES"/parse-ok/forbid-unconstrained.cedar "$FORBID_DIR/forbid-all.cedar"
  CEDAR_MOCK_DIR="$FORBID_DIR"
  export CEDAR_MOCK_DIR
  if "$ROOT/plugin.sh" can-i >/tmp/cedar-plugin-cani-deny.out 2>&1; then
    if grep -q '^DENY ' /tmp/cedar-plugin-cani-deny.out; then
      ok "plugin can-i DENY"
    else
      fail "plugin can-i expected DENY from forbid"
      cat /tmp/cedar-plugin-cani-deny.out
    fi
  else
    fail "plugin can-i DENY should exit 0"
    cat /tmp/cedar-plugin-cani-deny.out
  fi
  CEDAR_MOCK_DIR="$MOCK_DIR"
  export CEDAR_MOCK_DIR
  unset CEDAR_PRINCIPAL CEDAR_ACTION CEDAR_RESOURCE CEDAR_NAMESPACE CEDAR_K9S_REPORT
  rm -rf "$FORBID_DIR"

  NAME=permit-all
  export NAME
  unset RESOURCE_GROUP RESOURCE_VERSION RESOURCE_NAME
  if "$ROOT/plugin.sh" check-parse >/tmp/cedar-plugin-empty-gvr.out 2>&1; then
    ok "empty GVR skipped"
  else
    fail "empty GVR should skip guard"
    cat /tmp/cedar-plugin-empty-gvr.out
  fi
  NAME=""
  export NAME
  if "$ROOT/plugin.sh" check-parse permit-all cedar.k8s.aws v1alpha1 policies >/tmp/cedar-plugin-argv-gvr.out 2>&1; then
    ok "GVR from argv"
  else
    fail "GVR from argv"
    cat /tmp/cedar-plugin-argv-gvr.out
  fi
  if "$ROOT/plugin.sh" format x example.com v1 policies >/tmp/cedar-plugin-argv-bad-gvr.out 2>&1; then
    fail "wrong argv GVR should fail"
  else
    if grep -q 'refusing GVR' /tmp/cedar-plugin-argv-bad-gvr.out; then
      ok "wrong argv GVR refused"
    else
      fail "wrong argv GVR message missing"
      cat /tmp/cedar-plugin-argv-bad-gvr.out
    fi
  fi
  NAME=""
  export NAME
  if "$ROOT/plugin.sh" check-parse permit-all '$RESOURCE_GROUP' '$RESOURCE_VERSION' '$RESOURCE_NAME' >/tmp/cedar-plugin-dollar-gvr.out 2>&1; then
    ok "uninterpolated \$RESOURCE_* skipped"
  else
    fail "uninterpolated \$RESOURCE_* should skip guard"
    cat /tmp/cedar-plugin-dollar-gvr.out
  fi
  RESOURCE_GROUP=cedar.k8s.aws
  RESOURCE_VERSION=v1alpha1
  RESOURCE_NAME=policies
  export RESOURCE_GROUP RESOURCE_VERSION RESOURCE_NAME

  NAME=parse-fail
  export NAME
  unset CEDAR_K9S_STRICT
  if "$ROOT/plugin.sh" check-parse >/tmp/cedar-plugin-k9s-exit.out 2>&1; then
    if grep -q 'PARSE_FAIL' /tmp/cedar-plugin-k9s-exit.out; then
      ok "k9s mode PARSE_FAIL exits 0"
    else
      fail "k9s mode missing PARSE_FAIL status"
      cat /tmp/cedar-plugin-k9s-exit.out
    fi
  else
    fail "k9s mode should not exit 1 (Ruroh dialog)"
    cat /tmp/cedar-plugin-k9s-exit.out
  fi
  CEDAR_K9S_STRICT=1
  export CEDAR_K9S_STRICT

  NAME=too-big
  export NAME
  CEDAR_K9S_MAX_BYTES=50
  export CEDAR_K9S_MAX_BYTES
  if "$ROOT/plugin.sh" check-parse >/tmp/cedar-plugin-big.out 2>&1; then
    fail "oversized policy should fail"
  else
    if grep -q 'policy source is' /tmp/cedar-plugin-big.out; then
      ok "plugin size limit"
    else
      fail "plugin size limit message missing"
      cat /tmp/cedar-plugin-big.out
    fi
  fi
  unset CEDAR_K9S_MAX_BYTES
fi

# cargo prepend: k9s GUI PATH
if [ -x "${HOME}/.cargo/bin/cedar" ]; then
  OLD_PATH=$PATH
  PATH="/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin"
  export PATH
  RESOURCE_GROUP=example.com
  RESOURCE_VERSION=v1
  RESOURCE_NAME=policies
  NAME=x
  export RESOURCE_GROUP RESOURCE_VERSION RESOURCE_NAME NAME
  if "$ROOT/plugin.sh" format >/tmp/cedar-plugin-path.out 2>&1; then
    fail "expected GVR guard after cargo PATH prepend"
  elif grep -q 'refusing GVR' /tmp/cedar-plugin-path.out; then
    ok "cargo bin prepended (GVR guard reached)"
  elif grep -q 'cedar not found' /tmp/cedar-plugin-path.out; then
    fail "cedar still missing after cargo prepend"
    cat /tmp/cedar-plugin-path.out
  else
    ok "cargo prepend (guard or kubectl failed later)"
  fi
  PATH=$OLD_PATH
  export PATH
fi

if [ "$FAIL" -ne 0 ]; then
  printf '%s failed\n' "$FAIL"
  exit 1
fi
printf 'offline tests passed\n'
