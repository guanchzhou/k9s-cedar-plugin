#!/bin/sh
# k9s plugin glue. Not a public CLI. Requires kubectl + official cedar on PATH.
# Reads k9s env: NAME, CONTEXT, KUBECONFIG, RESOURCE_GROUP, RESOURCE_VERSION, RESOURCE_NAME.
# Object name also comes from argv[2] ($NAME in the plugin YAML).
# Plugin YAML is scoped to Cedar-only aliases; :policies is Kyverno. Still GVR-guard here.
set -eu

# k9s launched from the GUI often lacks ~/.cargo/bin. Official cedar lives there.
if [ -d "${HOME}/.cargo/bin" ]; then
  case ":${PATH}:" in
    *:"${HOME}/.cargo/bin":*) ;;
    *) PATH="${HOME}/.cargo/bin:${PATH}"
       export PATH ;;
  esac
fi

PAUSE="${CEDAR_K9S_PAUSE:-1}"
MAX_BYTES="${CEDAR_K9S_MAX_BYTES:-262144}"
MAX_POLICIES="${CEDAR_K9S_MAX_POLICIES:-1000}"
EXPECTED_GROUP="cedar.k8s.aws"
EXPECTED_VERSION="v1alpha1"
EXPECTED_RESOURCE="policies"

# k9s interpolates $NAME in plugin args. Env NAME is often unset unless YAML
# references it, so accept the object name as argv[2] as well.
if [ -z "${NAME:-}" ] && [ -n "${2:-}" ]; then
  NAME=$2
fi

if [ -n "${CEDAR_K9S_LOG:-}" ]; then
  printf '%s action=%s name=%s gvr=%s/%s/%s context=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${1:-}" "${NAME:-}" \
    "${RESOURCE_GROUP:-}" "${RESOURCE_VERSION:-}" "${RESOURCE_NAME:-}" \
    "${CONTEXT:-}" >>"$CEDAR_K9S_LOG"
fi

pause() {
  if [ "$PAUSE" != "1" ]; then
    return 0
  fi
  printf '\nPress Enter to return to k9s... '
  # shellcheck disable=SC2034
  read -r _
}

die() {
  printf '%s\n' "$*" >&2
  pause
  exit 1
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    die "$1 not found on PATH"
  fi
}

guard_gvr() {
  group="${RESOURCE_GROUP:-}"
  version="${RESOURCE_VERSION:-}"
  resource="${RESOURCE_NAME:-}"
  if [ "$group" != "$EXPECTED_GROUP" ] || [ "$version" != "$EXPECTED_VERSION" ] || [ "$resource" != "$EXPECTED_RESOURCE" ]; then
    die "refusing GVR ${group:-?}/${version:-?}/${resource:-?} (want ${EXPECTED_GROUP}/${EXPECTED_VERSION}/${EXPECTED_RESOURCE})"
  fi
}

kctl() {
  if [ -n "${KUBECONFIG:-}" ] && [ -n "${CONTEXT:-}" ]; then
    kubectl --kubeconfig "$KUBECONFIG" --context "$CONTEXT" "$@"
  elif [ -n "${KUBECONFIG:-}" ]; then
    kubectl --kubeconfig "$KUBECONFIG" "$@"
  elif [ -n "${CONTEXT:-}" ]; then
    kubectl --context "$CONTEXT" "$@"
  else
    kubectl "$@"
  fi
}

write_content() {
  dest=$1
  content=$2
  bytes=$(printf '%s' "$content" | wc -c | tr -d ' ')
  if [ "$bytes" -gt "$MAX_BYTES" ]; then
    die "policy source is ${bytes} bytes (limit ${MAX_BYTES}); skipped"
  fi
  printf '%s' "$content" >"$dest"
}

fetch_content() {
  name=$1
  kctl get "policies.${EXPECTED_GROUP}" "$name" -o jsonpath='{.spec.content}'
}

run_format() {
  require_cmd cedar
  [ -n "${NAME:-}" ] || die "NAME is empty"
  tmp=$(mktemp "${TMPDIR:-/tmp}/cedar-policy.XXXXXX")
  trap 'rm -f "$tmp"' EXIT INT TERM
  chmod 600 "$tmp"
  content=$(fetch_content "$NAME")
  write_content "$tmp" "$content"
  printf 'Policy: %s\nGVR: %s/%s/%s\n\n' "$NAME" "$EXPECTED_GROUP" "$EXPECTED_VERSION" "$EXPECTED_RESOURCE"
  cedar format --policies "$tmp"
}

run_check_parse() {
  require_cmd cedar
  [ -n "${NAME:-}" ] || die "NAME is empty"
  tmp=$(mktemp "${TMPDIR:-/tmp}/cedar-policy.XXXXXX")
  trap 'rm -f "$tmp"' EXIT INT TERM
  chmod 600 "$tmp"
  content=$(fetch_content "$NAME")
  write_content "$tmp" "$content"
  printf 'Policy: %s  check-parse\n\n' "$NAME"
  if cedar check-parse --policies "$tmp"; then
    printf '\nOK: parsed\n'
  else
    pause
    exit 1
  fi
}

run_validate() {
  require_cmd cedar
  [ -n "${NAME:-}" ] || die "NAME is empty"
  schema="${INPUT_SCHEMA:-${CEDAR_SCHEMA:-}}"
  if [ -z "$schema" ]; then
    die "no schema: set CEDAR_SCHEMA or the plugin schema input. Parse/format still work without it."
  fi
  if [ ! -f "$schema" ]; then
    die "schema file not found: $schema"
  fi
  tmp=$(mktemp "${TMPDIR:-/tmp}/cedar-policy.XXXXXX")
  trap 'rm -f "$tmp"' EXIT INT TERM
  chmod 600 "$tmp"
  content=$(fetch_content "$NAME")
  write_content "$tmp" "$content"
  printf 'Policy: %s  validate --schema %s\n\n' "$NAME" "$schema"
  cedar validate --schema "$schema" --policies "$tmp"
}

run_scan() {
  require_cmd cedar
  printf 'Cedar Policy scan (check-parse)  context=%s\nlimit=%s policies, %s bytes each\n\n' "${CONTEXT:-default}" "$MAX_POLICIES" "$MAX_BYTES"
  names=$(kctl get "policies.${EXPECTED_GROUP}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}') || die "failed to list policies.${EXPECTED_GROUP}"
  if [ -z "$names" ]; then
    printf 'No Policy objects found.\n'
    return 0
  fi
  n=0
  tmp=$(mktemp "${TMPDIR:-/tmp}/cedar-policy.XXXXXX")
  trap 'rm -f "$tmp"' EXIT INT TERM
  chmod 600 "$tmp"
  printf '%s\n' "$names" | while IFS= read -r name || [ -n "$name" ]; do
    [ -n "$name" ] || continue
    n=$((n + 1))
    if [ "$n" -gt "$MAX_POLICIES" ]; then
      printf 'STOPPED: more than %s policies\n' "$MAX_POLICIES"
      break
    fi
    content=$(fetch_content "$name") || {
      printf '%-40s  FETCH_ERROR\n' "$name"
      continue
    }
    bytes=$(printf '%s' "$content" | wc -c | tr -d ' ')
    if [ "$bytes" -gt "$MAX_BYTES" ]; then
      printf '%-40s  SKIP_TOO_LARGE (%s bytes)\n' "$name" "$bytes"
      continue
    fi
    printf '%s' "$content" >"$tmp"
    if cedar check-parse --policies "$tmp" >/dev/null 2>&1; then
      printf '%-40s  OK\n' "$name"
    else
      printf '%-40s  PARSE_FAIL\n' "$name"
    fi
  done
}

ACTION="${1:-}"
case "$ACTION" in
  format | check-parse | validate | scan) ;;
  *)
    die "usage: plugin.sh format|check-parse|validate|scan"
    ;;
esac

guard_gvr
require_cmd kubectl

case "$ACTION" in
  format) run_format ;;
  check-parse) run_check_parse ;;
  validate) run_validate ;;
  scan) run_scan ;;
esac

pause
exit 0
