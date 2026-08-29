#!/bin/sh
# Offline suite: Cedar language fixtures + plugin.sh against a mock kubectl.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
export CEDAR_K9S_PAUSE=0
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
    ok "plugin check-parse permit-all"
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
