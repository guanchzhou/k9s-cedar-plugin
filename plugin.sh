#!/bin/sh
# k9s plugin glue. Not a public CLI. Requires kubectl + official cedar on PATH.
# Reads k9s env or plugin argv: NAME, CONTEXT, RESOURCE_GROUP/VERSION/NAME.
# Those env vars are unset unless plugins.yaml references the $VARS in args.
# Plugin YAML is scoped to Cedar-only aliases; :policies is Kyverno. Still GVR-guard here.
set -eu

PLUGIN_HOME=$(CDPATH= cd -- "$(dirname "$0")" && pwd)

# k9s launched from the GUI often lacks ~/.cargo/bin. Official cedar lives there.
if [ -d "${HOME}/.cargo/bin" ]; then
  case ":${PATH}:" in
    *:"${HOME}/.cargo/bin":*) ;;
    *) PATH="${HOME}/.cargo/bin:${PATH}"
       export PATH ;;
  esac
fi

PAUSE="${CEDAR_K9S_PAUSE:-0}"
STRICT="${CEDAR_K9S_STRICT:-0}"
MAX_BYTES="${CEDAR_K9S_MAX_BYTES:-262144}"
MAX_POLICIES="${CEDAR_K9S_MAX_POLICIES:-1000}"
EXPECTED_GROUP="cedar.k8s.aws"
EXPECTED_VERSION="v1alpha1"
EXPECTED_RESOURCE="policies"

# k9s Substitute() leaves $FOO in argv when that env key is missing.
usable() {
  [ -n "${1:-}" ] || return 1
  case "$1" in
    \$*) return 1 ;;
  esac
  return 0
}

input_arg() {
  if usable "${1:-}"; then
    printf '%s' "$1"
  fi
}

# argv: action name group version resource context
if [ -z "${NAME:-}" ] && usable "${2:-}"; then
  NAME=$2
fi
if [ -z "${RESOURCE_GROUP:-}" ] && usable "${3:-}"; then
  RESOURCE_GROUP=$3
fi
if [ -z "${RESOURCE_VERSION:-}" ] && usable "${4:-}"; then
  RESOURCE_VERSION=$4
fi
if [ -z "${RESOURCE_NAME:-}" ] && usable "${5:-}"; then
  RESOURCE_NAME=$5
fi
if [ -z "${CONTEXT:-}" ] && usable "${6:-}"; then
  CONTEXT=$6
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

# k9s cowCmd (Ruroh) on any nonzero exit. Status goes to stdout for overwriteOutput.
fail_status() {
  printf '%s\n' "$*" >&2
  printf '%s\n' "$*"
  if [ "$STRICT" = "1" ]; then
    pause
    exit 1
  fi
  exit 0
}

die() {
  fail_status "$*"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    die "$1 not found on PATH"
  fi
}

unset_or_dollar() {
  [ -z "${1:-}" ] && return 0
  case "$1" in
    \$*) return 0 ;;
  esac
  return 1
}

guard_gvr() {
  group="${RESOURCE_GROUP:-}"
  version="${RESOURCE_VERSION:-}"
  resource="${RESOURCE_NAME:-}"
  # Empty or uninterpolated $VARS: scopes already limited the shortcut.
  if unset_or_dollar "$group" && unset_or_dollar "$version" && unset_or_dollar "$resource"; then
    return 0
  fi
  if [ "$group" = "$EXPECTED_GROUP" ] && [ "$version" = "$EXPECTED_VERSION" ] && \
     { [ "$resource" = "$EXPECTED_RESOURCE" ] || unset_or_dollar "$resource"; }; then
    return 0
  fi
  die "refusing GVR ${group}/${version}/${resource} (want ${EXPECTED_GROUP}/${EXPECTED_VERSION}/${EXPECTED_RESOURCE})"
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
  formatted_tmp=""
  error_tmp=$(mktemp "${TMPDIR:-/tmp}/cedar-format-error.XXXXXX")
  cleanup_format() {
    rm -f "$tmp" "$formatted_tmp" "$error_tmp"
  }
  trap cleanup_format EXIT INT TERM
  chmod 600 "$tmp"
  if ! content=$(fetch_content "$NAME"); then
    fail_status "${NAME}: FETCH_ERROR"
  fi
  write_content "$tmp" "$content"

  format_report="${CEDAR_K9S_FORMAT_REPORT:-}"
  if [ -n "$format_report" ]; then
    format_dir=$(dirname "$format_report")
    [ -d "$format_dir" ] || die "format report directory not found: $format_dir"
    formatted_tmp=$(mktemp "${format_dir}/.k9s-cedar-format.XXXXXX")
  else
    format_report=$(mktemp "${TMPDIR:-/tmp}/k9s-cedar-format.XXXXXX")
    formatted_tmp=$format_report
  fi
  chmod 600 "$formatted_tmp"
  if ! cedar format --policies "$tmp" >"$formatted_tmp" 2>"$error_tmp"; then
    cat "$error_tmp" >&2
    fail_status "${NAME}: FORMAT_FAIL"
  fi
  if [ "$formatted_tmp" != "$format_report" ]; then
    mv -f "$formatted_tmp" "$format_report"
  fi
  formatted_tmp=""
  open_cani_report "$format_report"
  printf '%s: formatted\n' "$NAME"
}

run_check_parse() {
  require_cmd cedar
  [ -n "${NAME:-}" ] || die "NAME is empty"
  tmp=$(mktemp "${TMPDIR:-/tmp}/cedar-policy.XXXXXX")
  trap 'rm -f "$tmp"' EXIT INT TERM
  chmod 600 "$tmp"
  if ! content=$(fetch_content "$NAME"); then
    fail_status "${NAME}: FETCH_ERROR"
  fi
  write_content "$tmp" "$content"
  if cedar check-parse --policies "$tmp" >&2; then
    printf '%s: parsed\n' "$NAME"
  else
    fail_status "${NAME}: PARSE_FAIL"
  fi
}

run_validate() {
  require_cmd cedar
  [ -n "${NAME:-}" ] || die "NAME is empty"
  schema_arg=$(input_arg "${1:-}")
  schema="${INPUT_SCHEMA:-${schema_arg:-${CEDAR_SCHEMA:-}}}"
  if [ -z "$schema" ]; then
    die "no schema: set CEDAR_SCHEMA or the plugin schema input. Parse/format still work without it."
  fi
  if [ ! -f "$schema" ]; then
    die "schema file not found: $schema"
  fi
  tmp=$(mktemp "${TMPDIR:-/tmp}/cedar-policy.XXXXXX")
  trap 'rm -f "$tmp"' EXIT INT TERM
  chmod 600 "$tmp"
  if ! content=$(fetch_content "$NAME"); then
    fail_status "${NAME}: FETCH_ERROR"
  fi
  write_content "$tmp" "$content"
  printf 'Policy: %s  validate --schema %s\n' "$NAME" "$schema" >&2
  if cedar validate --schema "$schema" --policies "$tmp" >&2; then
    printf '%s: valid\n' "$NAME"
  else
    fail_status "${NAME}: INVALID"
  fi
}

run_scan() {
  require_cmd cedar
  printf 'Cedar Policy scan (check-parse)  context=%s\nlimit=%s policies, %s bytes each\n\n' "${CONTEXT:-default}" "$MAX_POLICIES" "$MAX_BYTES" >&2
  names=$(kctl get "policies.${EXPECTED_GROUP}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}') || die "failed to list policies.${EXPECTED_GROUP}"
  if [ -z "$names" ]; then
    printf 'scan: no Policy objects\n'
    return 0
  fi
  n=0
  ok_n=0
  fail_n=0
  error_n=0
  tmp=$(mktemp "${TMPDIR:-/tmp}/cedar-policy.XXXXXX")
  trap 'rm -f "$tmp"' EXIT INT TERM
  chmod 600 "$tmp"
  # here-doc so counters stay in this shell (a pipe would subshell them).
  while IFS= read -r name || [ -n "$name" ]; do
    [ -n "$name" ] || continue
    n=$((n + 1))
    if [ "$n" -gt "$MAX_POLICIES" ]; then
      printf 'STOPPED: more than %s policies\n' "$MAX_POLICIES" >&2
      error_n=$((error_n + 1))
      break
    fi
    content=$(fetch_content "$name") || {
      printf '%-40s  FETCH_ERROR\n' "$name" >&2
      error_n=$((error_n + 1))
      continue
    }
    bytes=$(printf '%s' "$content" | wc -c | tr -d ' ')
    if [ "$bytes" -gt "$MAX_BYTES" ]; then
      printf '%-40s  SKIP_TOO_LARGE (%s bytes)\n' "$name" "$bytes" >&2
      error_n=$((error_n + 1))
      continue
    fi
    printf '%s' "$content" >"$tmp"
    if cedar check-parse --policies "$tmp" >/dev/null 2>&1; then
      printf '%-40s  OK\n' "$name" >&2
      ok_n=$((ok_n + 1))
    else
      printf '%-40s  PARSE_FAIL\n' "$name" >&2
      fail_n=$((fail_n + 1))
    fi
  done <<EOF
$names
EOF
  if [ "$error_n" -gt 0 ]; then
    fail_status "scan: ${ok_n} OK, ${fail_n} PARSE_FAIL, ${error_n} ERROR — INCOMPLETE"
  fi
  printf 'scan: %s OK, %s PARSE_FAIL\n' "$ok_n" "$fail_n"
}

# kubectl auth can-i analog, presented as Käldström's "Can P do A on R?"
# k8s verbs map to k8s::User / k8s::Action / k8s::Resource (RequestInfo + UserInfo).
# Optional entities file supplies Group parents. HTML report is the readable view.
trim() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

make_euid() {
  python3 - "$1" "$2" <<'PY'
import json, sys
print(f"{sys.argv[1]}::{json.dumps(sys.argv[2], ensure_ascii=False)}")
PY
}

normalize_euid() {
  default_type=$1
  raw=$(trim "$2")
  [ -n "$raw" ] || return 1
  case "$raw" in
    *::*)
      printf '%s' "$raw"
      ;;
    [A-Z]*/*)
      make_euid "${raw%%/*}" "${raw#*/}"
      ;;
    *)
      make_euid "$default_type" "$raw"
      ;;
  esac
}

normalize_k8s_principal() {
  raw=$(trim "$1")
  case "$raw" in
    *::*) normalize_euid k8s::User "$raw" ;;
    system:serviceaccount:*:*) make_euid k8s::ServiceAccount "$raw" ;;
    system:node:*) make_euid k8s::Node "$raw" ;;
    *) make_euid k8s::User "$raw" ;;
  esac
}

is_k8s_verb() {
  case "$1" in
    get | list | watch | create | update | patch | delete | deletecollection | proxy | impersonate | sign | approve | bind | escalate | attest | use) return 0 ;;
  esac
  return 1
}

check_k8s_segment() {
  label=$1
  value=$2
  [ -z "$value" ] && return 0
  case "$value" in
    *[!A-Za-z0-9._:-]*) die "can-i: invalid ${label}: ${value}" ;;
  esac
}

# kubectl can-i resource: pods, pods/mypod, or pods/mypod/log.
parse_k8s_resource() {
  raw=$(trim "$1")
  ns=$(trim "$2")
  apigroup=$(trim "$3")
  apiversion=$(trim "$4")
  object_override=$(trim "$5")

  K8S_RESOURCE_NAME=${raw%%/*}
  rest=""
  [ "$raw" = "$K8S_RESOURCE_NAME" ] || rest=${raw#*/}
  K8S_OBJECT_NAME=${rest%%/*}
  K8S_SUBRESOURCE=""
  if [ -n "$rest" ] && [ "$rest" != "$K8S_OBJECT_NAME" ]; then
    K8S_SUBRESOURCE=${rest#*/}
  fi
  [ -z "$object_override" ] || K8S_OBJECT_NAME=$object_override

  check_k8s_segment resource "$K8S_RESOURCE_NAME"
  check_k8s_segment namespace "$ns"
  check_k8s_segment apiGroup "$apigroup"
  check_k8s_segment apiVersion "$apiversion"
  check_k8s_segment name "$K8S_OBJECT_NAME"
  check_k8s_segment subresource "$K8S_SUBRESOURCE"
  [ -n "$K8S_RESOURCE_NAME" ] || die "can-i: resource is empty"
  [ -n "$apiversion" ] || die "can-i: apiVersion is empty"

  if [ -n "$apigroup" ]; then
    path="/apis/${apigroup}/${apiversion}"
  else
    path="/api/${apiversion}"
  fi
  [ -z "$ns" ] || path="${path}/namespaces/${ns}"
  path="${path}/${K8S_RESOURCE_NAME}"
  [ -z "$K8S_OBJECT_NAME" ] || path="${path}/${K8S_OBJECT_NAME}"
  [ -z "$K8S_SUBRESOURCE" ] || path="${path}/${K8S_SUBRESOURCE}"
  K8S_RESOURCE_EUID=$(make_euid k8s::Resource "$path")
}

resource_plural_label() {
  raw=$(trim "$1")
  case "$raw" in
    *::*)
      printf '%s' "$raw"
      ;;
    */*)
      printf '%s' "${raw%%/*}"
      ;;
    *)
      printf '%s' "$raw"
      ;;
  esac
}

write_entities() {
  dest=$1
  mode=$2
  ns=$3
  apigroup=$4
  resource_name=$5
  objname=$6
  subresource=$7
  base_file=$8
  principal_euid=$9
  resource_euid=${10}
  python3 - "$dest" "$mode" "$ns" "$apigroup" "$resource_name" \
    "$objname" "$subresource" "$base_file" "$principal_euid" "$resource_euid" <<'PY'
import json, os, re, sys

dest, mode, ns, apigroup, resource_name, objname, subresource, base_file = sys.argv[1:9]
euid_args = sys.argv[9:]
pat = re.compile(r'^(.+)::("(?:\\.|[^"\\])*")$')

def split_euid(euid):
    match = pat.fullmatch(euid)
    if not match:
        raise ValueError(f"invalid Cedar entity UID: {euid}")
    return match.group(1), json.loads(match.group(2))

entities = []
if base_file:
    with open(base_file, encoding="utf-8") as f:
        entities = json.load(f)
    if not isinstance(entities, list):
        raise ValueError("entities JSON must be an array")

by_uid = {}
order = []
for entity in entities:
    uid = entity.get("uid") if isinstance(entity, dict) else None
    if not isinstance(uid, dict) or not isinstance(uid.get("type"), str) or not isinstance(uid.get("id"), str):
        raise ValueError("every entity must have string uid.type and uid.id")
    key = (uid["type"], uid["id"])
    if key in by_uid:
        raise ValueError(f"duplicate entity UID: {key[0]}::{json.dumps(key[1])}")
    by_uid[key] = entity
    order.append(key)

for euid in euid_args:
    typ, eid = split_euid(euid)
    attrs = {}
    if mode == "k8s":
        if typ == "k8s::User":
            attrs["name"] = eid
        elif typ == "k8s::ServiceAccount":
            parts = eid.split(":", 3)
            if len(parts) != 4 or parts[:2] != ["system", "serviceaccount"]:
                raise ValueError(f"invalid Kubernetes service account identity: {eid}")
            attrs.update({"namespace": parts[2], "name": parts[3]})
        elif typ == "k8s::Node":
            prefix = "system:node:"
            attrs["name"] = eid[len(prefix):] if eid.startswith(prefix) else eid
        elif typ == "k8s::Resource":
            attrs.update({"apiGroup": apigroup, "resource": resource_name})
            if ns:
                attrs["namespace"] = ns
            if objname:
                attrs["name"] = objname
            if subresource:
                attrs["subresource"] = subresource

    key = (typ, eid)
    if key in by_uid:
        current = by_uid[key]
        merged_attrs = dict(current.get("attrs") or {})
        merged_attrs.update(attrs)
        current["attrs"] = merged_attrs
        current.setdefault("parents", [])
    else:
        by_uid[key] = {
            "uid": {"type": typ, "id": eid},
            "attrs": attrs,
            "parents": [],
        }
        order.append(key)

with open(dest, "w", encoding="utf-8") as f:
    json.dump([by_uid[key] for key in order], f)
    f.write("\n")
os.chmod(dest, 0o600)
PY
}

write_cani_report() {
  report=$1
  [ -f "$PLUGIN_HOME/cani_report.py" ] || return 1
  python3 "$PLUGIN_HOME/cani_report.py" \
    --out "$report" \
    --decision "$2" \
    --principal-label "$3" \
    --principal-euid "$4" \
    --action-label "$5" \
    --action-euid "$6" \
    --resource-label "$7" \
    --resource-euid "$8" \
    --namespace "$9" \
    --apigroup "${10}" \
    --object-name "${11}" \
    --mode "${12}" \
    --context "${13}" \
    --included "${14}" \
    --skipped "${15}" \
    --included-names "${16}" \
    --policies-file "${17}" \
    --entities-file "${18}" \
    --authorize-log-file "${19}" \
    --matrix-file "${20}"
}

open_cani_report() {
  report=$1
  [ -f "$report" ] || return 0
  if [ "$STRICT" = "1" ] || [ "${CEDAR_K9S_NO_OPEN:-0}" = "1" ]; then
    printf 'report: %s\n' "$report" >&2
    return 0
  fi
  if command -v open >/dev/null 2>&1; then
    open "$report" || printf 'could not open report: %s\n' "$report" >&2
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$report" || printf 'could not open report: %s\n' "$report" >&2
  fi
  printf 'report: %s\n' "$report" >&2
}

run_can_i() {
  require_cmd cedar
  require_cmd python3
  principal_arg=$(input_arg "${1:-}")
  action_arg=$(input_arg "${2:-}")
  resource_arg=$(input_arg "${3:-}")
  namespace_arg=$(input_arg "${4:-}")
  apigroup_arg=$(input_arg "${5:-}")
  principal_raw=$(trim "${INPUT_PRINCIPAL:-${INPUT_USER:-${principal_arg:-${CEDAR_PRINCIPAL:-}}}}")
  action_raw=$(trim "${INPUT_ACTION:-${INPUT_VERB:-${action_arg:-${CEDAR_ACTION:-}}}}")
  resource_raw=$(trim "${INPUT_RESOURCE:-${resource_arg:-${CEDAR_RESOURCE:-}}}")
  ns=$(trim "${INPUT_NAMESPACE:-${namespace_arg:-${CEDAR_NAMESPACE:-}}}")
  apigroup=$(trim "${INPUT_APIGROUP:-${apigroup_arg:-${CEDAR_APIGROUP:-}}}")
  apiversion=$(trim "${CEDAR_APIVERSION:-v1}")
  CANI_OBJECT_NAME=$(trim "${INPUT_OBJECT_NAME:-${CEDAR_OBJECT_NAME:-}}")
  [ -n "$principal_raw" ] || die "can-i: need principal (P / user, or CEDAR_PRINCIPAL)"
  [ -n "$action_raw" ] || die "can-i: need action (A / verb, or CEDAR_ACTION)"
  [ -n "$resource_raw" ] || die "can-i: need resource (R, or CEDAR_RESOURCE)"

  mode=cedar
  case "$action_raw" in
    k8s::Action::*) mode=k8s ;;
    *::*) ;;
    *)
      if is_k8s_verb "$action_raw" || [ -n "$ns" ] || [ -n "$apigroup" ]; then
        mode=k8s
      fi
      ;;
  esac
  case "$resource_raw" in
    *::*) mode=cedar ;;
    [A-Z]*/*) mode=cedar ;;
  esac

  p_label=$principal_raw
  a_label=$action_raw
  case "$principal_raw" in
    *::*) p_label=${principal_raw##*::} ; p_label=$(printf '%s' "$p_label" | tr -d '"') ;;
  esac
  case "$action_raw" in
    *::*) a_label=${action_raw##*::} ; a_label=$(printf '%s' "$a_label" | tr -d '"') ;;
  esac

  if [ "$mode" = k8s ]; then
    principal=$(normalize_k8s_principal "$principal_raw")
    action=$(normalize_euid 'k8s::Action' "$action_raw")
    parse_k8s_resource "$resource_raw" "$ns" "$apigroup" "$apiversion" "$CANI_OBJECT_NAME"
    resource=$K8S_RESOURCE_EUID
    objname=$K8S_OBJECT_NAME
    r_label=$(resource_plural_label "$resource_raw")
  else
    principal=$(normalize_euid User "$principal_raw")
    action=$(normalize_euid Action "$action_raw")
    resource=$(normalize_euid Resource "$resource_raw")
    objname=$CANI_OBJECT_NAME
    r_label=$resource_raw
    case "$resource_raw" in
      *::*) r_label=${resource_raw##*::} ; r_label=$(printf '%s' "$r_label" | tr -d '"') ;;
    esac
  fi
  schema="${INPUT_SCHEMA:-${CEDAR_SCHEMA:-}}"
  entities_in="${INPUT_ENTITIES:-${CEDAR_ENTITIES:-}}"
  context_in="${INPUT_CONTEXT:-${CEDAR_CONTEXT:-}}"
  [ -z "$schema" ] || [ -f "$schema" ] || die "schema file not found: $schema"
  [ -z "$entities_in" ] || [ -f "$entities_in" ] || die "entities file not found: $entities_in"
  [ -z "$context_in" ] || [ -f "$context_in" ] || die "context file not found: $context_in"

  work=$(mktemp -d "${TMPDIR:-/tmp}/cedar-cani.XXXXXX")
  trap 'rm -rf "$work"' EXIT INT TERM
  pol="$work/policies.cedar"
  ent="$work/entities.json"
  ctx="$work/context.json"
  out="$work/authorize.out"
  matrix="$work/matrix.json"
  aggregate_out="$work/aggregate.out"
  : >"$pol"
  included_names=""

  names=$(kctl get "policies.${EXPECTED_GROUP}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}') || die "failed to list policies.${EXPECTED_GROUP}"
  n=0
  included=0
  skipped=0
  tmp="$work/candidate.cedar"
  : >"$tmp"
  chmod 600 "$tmp"
  while IFS= read -r name || [ -n "$name" ]; do
    [ -n "$name" ] || continue
    n=$((n + 1))
    if [ "$n" -gt "$MAX_POLICIES" ]; then
      skipped=$((skipped + 1))
      printf 'INCOMPLETE: more than %s policies\n' "$MAX_POLICIES" >&2
      break
    fi
    content=$(fetch_content "$name") || {
      skipped=$((skipped + 1))
      printf '%s: FETCH_ERROR\n' "$name" >&2
      continue
    }
    bytes=$(printf '%s' "$content" | wc -c | tr -d ' ')
    if [ "$bytes" -gt "$MAX_BYTES" ]; then
      skipped=$((skipped + 1))
      printf '%s: SKIP_TOO_LARGE (%s bytes)\n' "$name" "$bytes" >&2
      continue
    fi
    printf '%s' "$content" >"$tmp"
    if ! cedar check-parse --policies "$tmp" >/dev/null 2>&1; then
      skipped=$((skipped + 1))
      printf '%s: PARSE_FAIL\n' "$name" >&2
      continue
    fi
    if printf '%s' "$content" | grep -q '@id('; then
      printf '%s\n' "$content" >>"$pol"
    else
      printf '@id("%s")\n%s\n' "$name" "$content" >>"$pol"
    fi
    included=$((included + 1))
    if [ -n "$included_names" ]; then
      included_names="${included_names},${name}"
    else
      included_names=$name
    fi
  done <<EOF
$names
EOF
  if [ "$skipped" -gt 0 ]; then
    die "can-i: INDETERMINATE (${skipped} policy source(s) unavailable)"
  fi

  if ! cedar check-parse --policies "$pol" >"$aggregate_out" 2>&1; then
    cat "$aggregate_out" >&2
    die "can-i: INDETERMINATE (combined policy set is invalid)"
  fi

  resource_name=""
  subresource=""
  if [ "$mode" = k8s ]; then
    resource_name=$K8S_RESOURCE_NAME
    subresource=$K8S_SUBRESOURCE
  fi
  if ! write_entities "$ent" "$mode" "$ns" "$apigroup" "$resource_name" \
      "$objname" "$subresource" "$entities_in" "$principal" "$resource"; then
    die "can-i: INDETERMINATE (invalid entities)"
  fi
  if [ -n "$context_in" ]; then
    cp "$context_in" "$ctx"
  else
    printf '{}\n' >"$ctx"
  fi
  chmod 600 "$ctx"

  set -- authorize -v --policies "$pol" --entities "$ent" --context "$ctx" \
    --principal "$principal" --action "$action" --resource "$resource"
  if [ -n "$schema" ]; then
    set -- "$@" --schema "$schema"
  fi

  set +e
  cedar "$@" >"$out" 2>&1
  rc=$?
  set -e
  cat "$out" >&2

  if grep -q '^error while evaluating policy' "$out"; then
    die "can-i: INDETERMINATE (policy evaluation error)"
  fi
  decision=$(awk '/^ALLOW$/{print "ALLOW"; exit} /^DENY$/{print "DENY"; exit}' "$out")
  case "$rc:$decision" in
    0:ALLOW | 2:DENY) ;;
    *) die "can-i: cedar authorize failed (exit ${rc})" ;;
  esac
  determining=$(awk '/due to the following policies:/{grab=1; next} grab{if($0 ~ /^[[:space:]]*$/) exit; if($0 !~ /^[[:space:]]/) exit; gsub(/^[[:space:]]+/, ""); print}' "$out" | paste -sd, -)
  extra=""
  if [ -n "$determining" ]; then
    extra="  ·  ${determining}"
  fi
  if [ -n "$ns" ]; then
    extra="  ns=${ns}${extra}"
  fi

  printf '[]\n' >"$matrix"
  if [ "$mode" = k8s ]; then
    matrix_json="["
    first=1
    matrix_out="$work/matrix-authorize.out"
    for verb in get list watch create update patch delete; do
      verb_euid=$(normalize_euid 'k8s::Action' "$verb")
      set -- authorize --policies "$pol" --entities "$ent" --context "$ctx" \
        --principal "$principal" --action "$verb_euid" --resource "$resource"
      if [ -n "$schema" ]; then
        set -- "$@" --schema "$schema"
      fi
      set +e
      cedar "$@" >"$matrix_out" 2>&1
      mrc=$?
      set -e
      if grep -q '^error while evaluating policy' "$matrix_out"; then
        mdec=ERROR
      else
        case "$mrc" in
          0) mdec=ALLOW ;;
          2) mdec=DENY ;;
          *) mdec=ERROR ;;
        esac
      fi
      if [ "$first" -eq 1 ]; then
        first=0
      else
        matrix_json="${matrix_json},"
      fi
      matrix_json="${matrix_json}{\"verb\":\"${verb}\",\"decision\":\"${mdec}\"}"
    done
    matrix_json="${matrix_json}]"
    printf '%s\n' "$matrix_json" >"$matrix"
  fi

  report="${CEDAR_K9S_REPORT:-}"
  if [ -z "$report" ]; then
    report=$(mktemp "${TMPDIR:-/tmp}/k9s-cedar-can-i.XXXXXX")
    chmod 600 "$report"
  fi
  case "$decision" in
    ALLOW | DENY)
      if ! write_cani_report "$report" "$decision" "$p_label" "$principal" \
          "$a_label" "$action" "$r_label" "$resource" \
          "$ns" "$apigroup" "$objname" "$mode" "${CONTEXT:-default}" \
          "$included" "$skipped" "$included_names" \
          "$pol" "$ent" "$out" "$matrix"; then
        die "can-i: decision ${decision}, but report generation failed"
      fi
      open_cani_report "$report"
      printf '%s  %s  %s  %s%s\n' "$decision" "$p_label" "$a_label" "$r_label" "$extra"
      ;;
  esac
}

ACTION="${1:-}"
case "$ACTION" in
  format | check-parse | validate | scan | can-i) ;;
  *)
    die "usage: plugin.sh format|check-parse|validate|scan|can-i"
    ;;
esac

guard_gvr
require_cmd kubectl

case "$ACTION" in
  format) run_format ;;
  check-parse) run_check_parse ;;
  validate) run_validate "${7:-}" ;;
  scan) run_scan ;;
  can-i) run_can_i "${7:-}" "${8:-}" "${9:-}" "${10:-}" "${11:-}" ;;
esac

pause
exit 0
