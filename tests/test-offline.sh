#!/bin/sh
# Offline suite: Cedar language fixtures + plugin.sh against a mock kubectl.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
export CEDAR_K9S_PAUSE=0 CEDAR_K9S_STRICT=1
FAIL=0
FIXTURES="$ROOT/tests/fixtures"
SCHEMA="$FIXTURES/schema/tiny.cedarschema"
K8S_SCHEMA="$FIXTURES/schema/k8s-authorization.cedarschema"
K8S_GET_SCHEMA="$FIXTURES/schema/k8s-get-only.cedarschema"
MOCK_BIN="$ROOT/tests/mocks"

ok() { printf 'ok  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

require_cedar() {
  if [ -d "${HOME}/.cargo/bin" ]; then
    PATH="${HOME}/.cargo/bin:${PATH}"
    export PATH
  fi
  if ! command -v cedar >/dev/null 2>&1; then
    fail "cedar is required for offline tests"
    return 1
  fi
  return 0
}

if ! command -v python3 >/dev/null 2>&1; then
  printf 'FAIL  python3 is required for offline tests and can-i\n' >&2
  exit 1
fi

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

# --- installer: never corrupt existing YAML or special-character paths ---
INSTALL_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cedar-install.XXXXXX")
SPECIAL_DEST="$INSTALL_DIR/config&| #home"
if K9S_CONFIG_DIR="$SPECIAL_DEST" "$ROOT/install.sh" >/tmp/cedar-install-special.out 2>&1; then
  SPECIAL_DEST_REAL=$(CDPATH= cd -- "$SPECIAL_DEST" && pwd)
else
  SPECIAL_DEST_REAL=$SPECIAL_DEST
fi
if grep -Fq "command: \"$SPECIAL_DEST_REAL/plugins/cedar/plugin.sh\"" "$SPECIAL_DEST/plugins/cedar.yaml"; then
  ok "installer escapes plugin command path"
else
  fail "installer corrupts special-character path"
  cat /tmp/cedar-install-special.out
fi

COMPACT_DEST="$INSTALL_DIR/compact"
mkdir -p "$COMPACT_DEST"
printf 'views: {}\n' >"$COMPACT_DEST/views.yaml"
printf 'aliases: {foo: pods}\n' >"$COMPACT_DEST/aliases.yaml"
if K9S_CONFIG_DIR="$COMPACT_DEST" "$ROOT/install.sh" >/tmp/cedar-install-compact.out 2>&1 && \
   [ "$(cat "$COMPACT_DEST/views.yaml")" = "views: {}" ] && \
   [ "$(cat "$COMPACT_DEST/aliases.yaml")" = "aliases: {foo: pods}" ]; then
  ok "installer leaves unsupported compact YAML unchanged"
else
  fail "installer corrupts compact YAML"
  cat /tmp/cedar-install-compact.out
fi

COMMENT_DEST="$INSTALL_DIR/comment"
mkdir -p "$COMMENT_DEST"
printf 'views:\n  # cedar.k8s.aws/v1alpha1/policies is documented here\n' >"$COMMENT_DEST/views.yaml"
if K9S_CONFIG_DIR="$COMMENT_DEST" "$ROOT/install.sh" >/tmp/cedar-install-comment.out 2>&1 && \
   grep -Eq '^  cedar\.k8s\.aws/v1alpha1/policies:$' "$COMMENT_DEST/views.yaml"; then
  ok "installer ignores marker text in comments"
else
  fail "installer mistook comment for installed view"
  cat /tmp/cedar-install-comment.out
fi
rm -rf "$INSTALL_DIR"

if PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$ROOT" python3 - <<'PY'
from cani_report import parse_determining
log = "ALLOW\n\nnote: this decision was due to the following policies:\n  policy id with spaces\n"
raise SystemExit(0 if parse_determining(log) == ["policy id with spaces"] else 1)
PY
then
  ok "report preserves determining policy ids with spaces"
else
  fail "report truncates determining policy ids with spaces"
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

  # k9s substitutes plugin inputs into argv; it does not export INPUT_*.
  # Shift-V's seventh argument must therefore reach run_validate.
  NAME=""
  export NAME
  if "$ROOT/plugin.sh" validate typed-view cedar.k8s.aws v1alpha1 policies test-context "$SCHEMA" \
      >/tmp/cedar-plugin-val-argv.out 2>&1; then
    ok "plugin validate schema from k9s argv"
  else
    fail "plugin validate schema from k9s argv"
    cat /tmp/cedar-plugin-val-argv.out
  fi
  NAME=typed-view
  export NAME

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

  SCAN_SKIP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cedar-scan-skip.XXXXXX")
  cp "$FIXTURES"/parse-ok/permit-unconstrained.cedar "$SCAN_SKIP_DIR/too-big.cedar"
  CEDAR_MOCK_DIR="$SCAN_SKIP_DIR"
  CEDAR_K9S_MAX_BYTES=1
  export CEDAR_MOCK_DIR CEDAR_K9S_MAX_BYTES
  if "$ROOT/plugin.sh" scan >/tmp/cedar-plugin-scan-incomplete.out 2>&1; then
    fail "scan must not report success when no policy was analyzed"
  elif grep -q 'INCOMPLETE' /tmp/cedar-plugin-scan-incomplete.out; then
    ok "plugin scan reports skipped policies as incomplete"
  else
    fail "scan incomplete summary missing"
    cat /tmp/cedar-plugin-scan-incomplete.out
  fi
  unset CEDAR_K9S_MAX_BYTES
  CEDAR_MOCK_DIR="$MOCK_DIR"
  export CEDAR_MOCK_DIR
  rm -rf "$SCAN_SKIP_DIR"

  CANI_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cedar-cani-clean.XXXXXX")
  cp "$FIXTURES"/parse-ok/permit-unconstrained.cedar "$CANI_DIR/permit-all.cedar"
  CEDAR_MOCK_DIR="$CANI_DIR"
  export CEDAR_MOCK_DIR
  unset CEDAR_PRINCIPAL CEDAR_ACTION CEDAR_RESOURCE CEDAR_NAMESPACE CEDAR_APIGROUP
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

  # Shift-I's five dialog values are argv 7..11 after the k9s resource args.
  CEDAR_K9S_REPORT=/tmp/cedar-plugin-cani.html
  export CEDAR_K9S_REPORT
  if "$ROOT/plugin.sh" can-i permit-all cedar.k8s.aws v1alpha1 policies test-context \
      alice view x '$INPUT_NAMESPACE' '$INPUT_APIGROUP' \
      >/tmp/cedar-plugin-cani-allow.out 2>&1; then
    if grep -q '^ALLOW ' /tmp/cedar-plugin-cani-allow.out && grep -q 'permit-all' /tmp/cedar-plugin-cani-allow.out; then
      ok "plugin can-i inputs from k9s argv"
    else
      fail "plugin can-i argv expected ALLOW from permit-all"
      cat /tmp/cedar-plugin-cani-allow.out
    fi
    if grep -q 'Can P do A on R' "$CEDAR_K9S_REPORT" && grep -q 'UserInfo' "$CEDAR_K9S_REPORT"; then
      ok "plugin can-i HTML report"
    else
      fail "plugin can-i HTML report missing"
    fi
  else
    fail "plugin can-i inputs from k9s argv"
    cat /tmp/cedar-plugin-cani-allow.out
  fi

  # Reports must replace, not follow, a pre-existing symlink and must not be
  # readable by other local users.
  REPORT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cedar-report-safe.XXXXXX")
  printf 'do not overwrite\n' >"$REPORT_DIR/victim"
  ln -s "$REPORT_DIR/victim" "$REPORT_DIR/report.html"
  CEDAR_K9S_REPORT="$REPORT_DIR/report.html"
  export CEDAR_K9S_REPORT
  if CEDAR_PRINCIPAL=alice CEDAR_ACTION=view CEDAR_RESOURCE=x \
      "$ROOT/plugin.sh" can-i >/tmp/cedar-plugin-report-safe.out 2>&1; then
    if [ "$(cat "$REPORT_DIR/victim")" = "do not overwrite" ] && \
       [ ! -L "$REPORT_DIR/report.html" ] && \
       grep -q 'Can P do A on R' "$REPORT_DIR/report.html" && \
       python3 -c 'import os,sys; raise SystemExit(0 if os.stat(sys.argv[1]).st_mode & 0o077 == 0 else 1)' \
         "$REPORT_DIR/report.html"; then
      ok "plugin can-i report is atomic and private"
    else
      fail "plugin can-i report followed symlink or has unsafe mode"
    fi
  else
    fail "plugin can-i secure report"
    cat /tmp/cedar-plugin-report-safe.out
  fi

  # Format keeps k9s visible, so the formatted policy must be opened from a
  # private file rather than disappearing on captured stderr.
  FORMAT_REPORT="$REPORT_DIR/formatted.cedar"
  CEDAR_K9S_FORMAT_REPORT="$FORMAT_REPORT"
  export CEDAR_K9S_FORMAT_REPORT
  NAME=permit-all
  export NAME
  if "$ROOT/plugin.sh" format >/tmp/cedar-plugin-format-report.out 2>&1; then
    if grep -q 'permit' "$FORMAT_REPORT" && \
       python3 -c 'import os,sys; raise SystemExit(0 if os.stat(sys.argv[1]).st_mode & 0o077 == 0 else 1)' \
         "$FORMAT_REPORT"; then
      ok "plugin format writes a private visible result"
    else
      fail "plugin format result missing or has unsafe mode"
    fi
  else
    fail "plugin format visible result"
    cat /tmp/cedar-plugin-format-report.out
  fi
  unset CEDAR_K9S_FORMAT_REPORT

  # The generated Kubernetes request must validate against the frozen PoC
  # authorization schema and use its canonical API-path resource UID.
  K8S_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cedar-cani-k8s.XXXXXX")
  cp "$FIXTURES"/parse-ok/k8s-authz-pods.cedar "$K8S_DIR/k8s-authz-pods.cedar"
  CEDAR_MOCK_DIR="$K8S_DIR"
  CEDAR_PRINCIPAL=test-user
  CEDAR_ACTION=get
  CEDAR_RESOURCE=pods
  CEDAR_NAMESPACE=default
  CEDAR_SCHEMA="$K8S_SCHEMA"
  CEDAR_K9S_REPORT=/tmp/cedar-plugin-cani-k8s.html
  export CEDAR_MOCK_DIR CEDAR_PRINCIPAL CEDAR_ACTION CEDAR_RESOURCE CEDAR_NAMESPACE CEDAR_SCHEMA CEDAR_K9S_REPORT
  if "$ROOT/plugin.sh" can-i >/tmp/cedar-plugin-cani-k8s.out 2>&1; then
    if grep -q '^ALLOW ' /tmp/cedar-plugin-cani-k8s.out && \
       grep -q 'k8s::Resource::&quot;/api/v1/namespaces/default/pods&quot;' "$CEDAR_K9S_REPORT"; then
      ok "plugin can-i frozen-PoC k8s mapping"
    else
      fail "plugin can-i frozen-PoC k8s mapping or canonical resource UID"
      cat /tmp/cedar-plugin-cani-k8s.out
    fi
  else
    fail "plugin can-i frozen-PoC k8s schema"
    cat /tmp/cedar-plugin-cani-k8s.out
  fi

  MATRIX_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cedar-cani-matrix.XXXXXX")
  cat >"$MATRIX_DIR/get-only.cedar" <<'EOF'
permit (
  principal is k8s::User,
  action == k8s::Action::"get",
  resource is k8s::Resource
) when {
  principal.name == "test-user" &&
  resource.resource == "pods"
};
EOF
  CEDAR_MOCK_DIR="$MATRIX_DIR"
  CEDAR_SCHEMA="$K8S_GET_SCHEMA"
  CEDAR_K9S_REPORT="$MATRIX_DIR/report.html"
  export CEDAR_MOCK_DIR CEDAR_SCHEMA CEDAR_K9S_REPORT
  if "$ROOT/plugin.sh" can-i >/tmp/cedar-plugin-cani-matrix.out 2>&1 && \
     grep -q 'class="err">?</td>' "$CEDAR_K9S_REPORT"; then
    ok "plugin can-i matrix applies schema and marks unsupported verbs"
  else
    fail "plugin can-i matrix ignored schema"
    cat /tmp/cedar-plugin-cani-matrix.out
  fi

  MATRIX_ERROR_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cedar-cani-matrix-error.XXXXXX")
  cp "$FIXTURES"/parse-ok/permit-unconstrained.cedar "$MATRIX_ERROR_DIR/00-permit.cedar"
  cat >"$MATRIX_ERROR_DIR/99-delete-error.cedar" <<'EOF'
forbid (
  principal,
  action == k8s::Action::"delete",
  resource
) when {
  resource.missingAttribute == true
};
EOF
  CEDAR_MOCK_DIR="$MATRIX_ERROR_DIR"
  CEDAR_K9S_REPORT="$MATRIX_ERROR_DIR/report.html"
  unset CEDAR_SCHEMA
  export CEDAR_MOCK_DIR CEDAR_K9S_REPORT
  if "$ROOT/plugin.sh" can-i >/tmp/cedar-plugin-cani-matrix-error.out 2>&1 && \
     grep -q 'class="err">?</td>' "$CEDAR_K9S_REPORT"; then
    ok "plugin can-i matrix rejects ALLOW with evaluation errors"
  else
    fail "plugin can-i matrix treated evaluation error as ALLOW"
    cat /tmp/cedar-plugin-cani-matrix-error.out
  fi

  CEDAR_MOCK_DIR="$CANI_DIR"
  CEDAR_K9S_REPORT="$CANI_DIR/verbs.html"
  unset CEDAR_NAMESPACE CEDAR_APIGROUP
  export CEDAR_MOCK_DIR CEDAR_K9S_REPORT
  for verb in use attest; do
    if "$ROOT/plugin.sh" can-i permit-all cedar.k8s.aws v1alpha1 policies test-context \
        test-user "$verb" pods '$INPUT_NAMESPACE' '$INPUT_APIGROUP' \
        >/tmp/cedar-plugin-cani-verb.out 2>&1 && \
       grep -q "k8s::Action::&quot;${verb}&quot;" "$CEDAR_K9S_REPORT"; then
      ok "plugin can-i maps Kubernetes verb $verb"
    else
      fail "plugin can-i routed Kubernetes verb $verb to generic model"
      cat /tmp/cedar-plugin-cani-verb.out
    fi
  done

  # A hierarchy file augments the generated request entities; it must not
  # replace the Resource attributes needed by the policy.
  GROUP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cedar-cani-group.XXXXXX")
  cp "$FIXTURES"/parse-ok/k8s-viewer-group.cedar "$GROUP_DIR/viewer.cedar"
  python3 - "$GROUP_DIR/entities.json" <<'PY'
import json, sys
json.dump([
    {
        "uid": {"type": "k8s::User", "id": "test-user"},
        "attrs": {},
        "parents": [{"type": "k8s::Group", "id": "viewers"}],
    },
    {
        "uid": {"type": "k8s::Group", "id": "viewers"},
        "attrs": {"name": "viewers"},
        "parents": [],
    },
], open(sys.argv[1], "w"))
PY
  CEDAR_MOCK_DIR="$GROUP_DIR"
  CEDAR_ENTITIES="$GROUP_DIR/entities.json"
  CEDAR_SCHEMA="$K8S_SCHEMA"
  export CEDAR_MOCK_DIR CEDAR_ENTITIES CEDAR_SCHEMA
  if "$ROOT/plugin.sh" can-i >/tmp/cedar-plugin-cani-group.out 2>&1 && \
     grep -q '^ALLOW ' /tmp/cedar-plugin-cani-group.out; then
    ok "plugin can-i merges hierarchy with request entities"
  else
    fail "plugin can-i hierarchy merge"
    cat /tmp/cedar-plugin-cani-group.out
  fi
  unset CEDAR_ENTITIES

  # Cedar may still print ALLOW when another policy raises an evaluation
  # error. An authorization check must surface that as indeterminate.
  EVAL_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cedar-cani-eval.XXXXXX")
  cp "$FIXTURES"/parse-ok/permit-unconstrained.cedar "$EVAL_DIR/00-permit.cedar"
  cat >"$EVAL_DIR/99-error.cedar" <<'EOF'
forbid (principal, action, resource) when {
  resource.missingAttribute == true
};
EOF
  CEDAR_MOCK_DIR="$EVAL_DIR"
  unset CEDAR_SCHEMA
  export CEDAR_MOCK_DIR
  if "$ROOT/plugin.sh" can-i >/tmp/cedar-plugin-cani-eval.out 2>&1; then
    fail "can-i must reject policy evaluation errors"
  elif grep -q 'INDETERMINATE' /tmp/cedar-plugin-cani-eval.out; then
    ok "plugin can-i fails closed on evaluation error"
  else
    fail "can-i evaluation error message missing"
    cat /tmp/cedar-plugin-cani-eval.out
  fi

  # An incomplete policy set is not authoritative. Never emit ALLOW after a
  # parse/fetch/size/limit skip.
  INCOMPLETE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cedar-cani-incomplete.XXXXXX")
  cp "$FIXTURES"/parse-ok/permit-unconstrained.cedar "$INCOMPLETE_DIR/00-permit.cedar"
  cp "$FIXTURES"/parse-fail/missing-commas.cedar "$INCOMPLETE_DIR/99-broken-forbid.cedar"
  CEDAR_MOCK_DIR="$INCOMPLETE_DIR"
  CEDAR_PRINCIPAL=alice
  CEDAR_ACTION=view
  CEDAR_RESOURCE=x
  unset CEDAR_NAMESPACE CEDAR_SCHEMA
  export CEDAR_MOCK_DIR CEDAR_PRINCIPAL CEDAR_ACTION CEDAR_RESOURCE
  if "$ROOT/plugin.sh" can-i >/tmp/cedar-plugin-cani-incomplete.out 2>&1; then
    fail "can-i must reject an incomplete policy set"
  elif grep -q 'INDETERMINATE' /tmp/cedar-plugin-cani-incomplete.out; then
    ok "plugin can-i fails closed on skipped policy"
  else
    fail "can-i incomplete policy message missing"
    cat /tmp/cedar-plugin-cani-incomplete.out
  fi

  LIMIT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cedar-cani-limit.XXXXXX")
  cp "$FIXTURES"/parse-ok/permit-unconstrained.cedar "$LIMIT_DIR/00-permit.cedar"
  cp "$FIXTURES"/parse-ok/forbid-unconstrained.cedar "$LIMIT_DIR/99-forbid.cedar"
  CEDAR_MOCK_DIR="$LIMIT_DIR"
  CEDAR_K9S_MAX_POLICIES=1
  export CEDAR_MOCK_DIR CEDAR_K9S_MAX_POLICIES
  if "$ROOT/plugin.sh" can-i >/tmp/cedar-plugin-cani-limit.out 2>&1; then
    fail "can-i must reject policy-limit truncation"
  elif grep -q 'INDETERMINATE' /tmp/cedar-plugin-cani-limit.out; then
    ok "plugin can-i fails closed on policy limit"
  else
    fail "can-i policy-limit message missing"
    cat /tmp/cedar-plugin-cani-limit.out
  fi
  unset CEDAR_K9S_MAX_POLICIES

  CEDAR_MOCK_DIR="$CANI_DIR"
  CEDAR_ENTITIES="$CANI_DIR/missing-entities.json"
  export CEDAR_MOCK_DIR CEDAR_ENTITIES
  if "$ROOT/plugin.sh" can-i >/tmp/cedar-plugin-cani-missing-entities.out 2>&1; then
    fail "can-i must reject missing entities file"
  elif grep -q 'entities file not found' /tmp/cedar-plugin-cani-missing-entities.out; then
    ok "plugin can-i rejects missing entities file"
  else
    fail "can-i missing entities message missing"
  fi
  unset CEDAR_ENTITIES

  CEDAR_CONTEXT="$CANI_DIR/missing-context.json"
  export CEDAR_CONTEXT
  if "$ROOT/plugin.sh" can-i >/tmp/cedar-plugin-cani-missing-context.out 2>&1; then
    fail "can-i must reject missing context file"
  elif grep -q 'context file not found' /tmp/cedar-plugin-cani-missing-context.out; then
    ok "plugin can-i rejects missing context file"
  else
    fail "can-i missing context message missing"
  fi
  unset CEDAR_CONTEXT

  CEDAR_MOCK_DIR="$MOCK_DIR"
  export CEDAR_MOCK_DIR
  unset CEDAR_PRINCIPAL CEDAR_ACTION CEDAR_RESOURCE CEDAR_NAMESPACE CEDAR_SCHEMA CEDAR_K9S_REPORT
  rm -rf "$CANI_DIR" "$K8S_DIR" "$MATRIX_DIR" "$MATRIX_ERROR_DIR" \
    "$GROUP_DIR" "$EVAL_DIR" \
    "$INCOMPLETE_DIR" "$LIMIT_DIR" "$REPORT_DIR"

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
  if "$ROOT/plugin.sh" format permit-all cedar.k8s.aws v1alpha1 widgets \
      >/tmp/cedar-plugin-argv-bad-resource.out 2>&1; then
    fail "wrong argv resource should fail"
  elif grep -q 'refusing GVR' /tmp/cedar-plugin-argv-bad-resource.out; then
    ok "wrong argv resource refused"
  else
    fail "wrong argv resource message missing"
    cat /tmp/cedar-plugin-argv-bad-resource.out
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
  NAME=missing
  export NAME
  if "$ROOT/plugin.sh" check-parse >/tmp/cedar-plugin-k9s-fetch.out 2>&1; then
    if grep -q 'FETCH_ERROR' /tmp/cedar-plugin-k9s-fetch.out; then
      ok "k9s mode fetch failure exits 0 with status"
    else
      fail "k9s mode fetch failure status missing"
      cat /tmp/cedar-plugin-k9s-fetch.out
    fi
  else
    fail "k9s mode fetch failure should not exit nonzero"
    cat /tmp/cedar-plugin-k9s-fetch.out
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
