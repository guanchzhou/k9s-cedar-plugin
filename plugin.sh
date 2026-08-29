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
  # Group+version is enough. RESOURCE_NAME is the GVR plural, but k9s docs also
  # call $NAME "resource name", so it may be the object name.
  if [ "$group" = "$EXPECTED_GROUP" ] && [ "$version" = "$EXPECTED_VERSION" ]; then
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
  trap 'rm -f "$tmp"' EXIT INT TERM
  chmod 600 "$tmp"
  content=$(fetch_content "$NAME")
  write_content "$tmp" "$content"
  # Details on stderr (k9s logs). One stdout line for overwriteOutput flash.
  printf 'Policy: %s\nGVR: %s/%s/%s\n\n' "$NAME" "$EXPECTED_GROUP" "$EXPECTED_VERSION" "$EXPECTED_RESOURCE" >&2
  cedar format --policies "$tmp" >&2
  printf '%s: formatted\n' "$NAME"
}

run_check_parse() {
  require_cmd cedar
  [ -n "${NAME:-}" ] || die "NAME is empty"
  tmp=$(mktemp "${TMPDIR:-/tmp}/cedar-policy.XXXXXX")
  trap 'rm -f "$tmp"' EXIT INT TERM
  chmod 600 "$tmp"
  content=$(fetch_content "$NAME")
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
  tmp=$(mktemp "${TMPDIR:-/tmp}/cedar-policy.XXXXXX")
  trap 'rm -f "$tmp"' EXIT INT TERM
  chmod 600 "$tmp"
  # here-doc so counters stay in this shell (a pipe would subshell them).
  while IFS= read -r name || [ -n "$name" ]; do
    [ -n "$name" ] || continue
    n=$((n + 1))
    if [ "$n" -gt "$MAX_POLICIES" ]; then
      printf 'STOPPED: more than %s policies\n' "$MAX_POLICIES" >&2
      break
    fi
    content=$(fetch_content "$name") || {
      printf '%-40s  FETCH_ERROR\n' "$name" >&2
      continue
    }
    bytes=$(printf '%s' "$content" | wc -c | tr -d ' ')
    if [ "$bytes" -gt "$MAX_BYTES" ]; then
      printf '%-40s  SKIP_TOO_LARGE (%s bytes)\n' "$name" "$bytes" >&2
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
  printf 'scan: %s OK, %s PARSE_FAIL\n' "$ok_n" "$fail_n"
}

# kubectl auth can-i analog, presented as Käldström's "Can P do A on R?"
# k8s verbs map to k8s::User / k8s::Action / k8s::Resource (RequestInfo + UserInfo).
# Optional entities file supplies Group parents. HTML report is the readable view.
trim() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

normalize_euid() {
  default_type=$1
  raw=$(trim "$2")
  [ -n "$raw" ] || return 1
  case "$raw" in
    *::*)
      printf '%s' "$raw"
      ;;
    */*)
      printf '%s::"%s"' "${raw%%/*}" "${raw#*/}"
      ;;
    *)
      printf '%s::"%s"' "$default_type" "$raw"
      ;;
  esac
}

is_k8s_verb() {
  case "$1" in
    get | list | watch | create | update | patch | delete | deletecollection | proxy | impersonate | sign | approve | bind | escalate) return 0 ;;
  esac
  return 1
}

# kubectl can-i resource: pods or pods/mypod. Cedar Type/id (Photo/x) stays cedar-mode.
normalize_k8s_resource() {
  raw=$(trim "$1")
  ns=$(trim "$2")
  case "$raw" in
    *::*)
      printf '%s' "$raw"
      return 0
      ;;
    */*)
      raw=${raw%%/*}
      ;;
  esac
  if [ -n "$ns" ]; then
    printf 'k8s::Resource::"%s/%s"' "$ns" "$raw"
  else
    printf 'k8s::Resource::"%s"' "$raw"
  fi
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
  ns=$2
  apigroup=$3
  objname=$4
  shift 4
  if ! command -v python3 >/dev/null 2>&1; then
    printf '[]\n' >"$dest"
    return 0
  fi
  python3 - "$dest" "$ns" "$apigroup" "$objname" "$@" <<'PY'
import json, re, sys
dest, ns, apigroup, objname = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
pat = re.compile(r'^(.+)::"(.*)"$')
seen = set()
ents = []
for euid in sys.argv[5:]:
    m = pat.match(euid)
    if not m:
        continue
    typ, eid = m.group(1), m.group(2)
    key = (typ, eid)
    if key in seen:
        continue
    seen.add(key)
    attrs = {}
    if typ.endswith("User") or typ.endswith("ServiceAccount"):
        attrs["name"] = eid
        attrs["username"] = eid
        attrs["groups"] = []
    if typ.endswith("Resource"):
        plural = eid
        if "/" in eid and not eid.startswith("/"):
            maybe_ns, maybe_res = eid.split("/", 1)
            if maybe_res:
                plural = maybe_res
        attrs["apiGroup"] = apigroup
        attrs["resource"] = plural
        attrs["resourceCombined"] = plural
        if ns:
            attrs["namespace"] = ns
        if objname:
            attrs["name"] = objname
    ents.append({"uid": {"type": typ, "id": eid}, "attrs": attrs, "parents": []})
with open(dest, "w", encoding="utf-8") as f:
    json.dump(ents, f)
PY
}

write_cani_report() {
  report=$1
  [ -f "$PLUGIN_HOME/cani_report.py" ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
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
    open "$report"
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$report"
  fi
  printf 'report: %s\n' "$report" >&2
}

run_can_i() {
  require_cmd cedar
  principal_raw=$(trim "${INPUT_PRINCIPAL:-${INPUT_USER:-${CEDAR_PRINCIPAL:-}}}")
  action_raw=$(trim "${INPUT_ACTION:-${INPUT_VERB:-${CEDAR_ACTION:-}}}")
  resource_raw=$(trim "${INPUT_RESOURCE:-${CEDAR_RESOURCE:-}}")
  ns=$(trim "${INPUT_NAMESPACE:-${CEDAR_NAMESPACE:-}}")
  apigroup=$(trim "${INPUT_APIGROUP:-${CEDAR_APIGROUP:-}}")
  CANI_OBJECT_NAME=$(trim "${INPUT_OBJECT_NAME:-${CEDAR_OBJECT_NAME:-}}")
  [ -n "$principal_raw" ] || die "can-i: need principal (P / user, or CEDAR_PRINCIPAL)"
  [ -n "$action_raw" ] || die "can-i: need action (A / verb, or CEDAR_ACTION)"
  [ -n "$resource_raw" ] || die "can-i: need resource (R, or CEDAR_RESOURCE)"

  mode=cedar
  case "$action_raw" in
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
  if [ -z "$CANI_OBJECT_NAME" ]; then
    case "$resource_raw" in
      *::*) ;;
      */*) CANI_OBJECT_NAME=${resource_raw#*/} ;;
    esac
  fi

  if [ "$mode" = k8s ]; then
    principal=$(normalize_euid 'k8s::User' "$principal_raw")
    action=$(normalize_euid 'k8s::Action' "$action_raw")
    resource=$(normalize_k8s_resource "$resource_raw" "$ns")
    r_label=$(resource_plural_label "$resource_raw")
  else
    principal=$(normalize_euid User "$principal_raw")
    action=$(normalize_euid Action "$action_raw")
    resource=$(normalize_euid Resource "$resource_raw")
    r_label=$resource_raw
    case "$resource_raw" in
      *::*) r_label=${resource_raw##*::} ; r_label=$(printf '%s' "$r_label" | tr -d '"') ;;
    esac
  fi
  objname=$CANI_OBJECT_NAME
  schema="${INPUT_SCHEMA:-${CEDAR_SCHEMA:-}}"
  entities_in="${INPUT_ENTITIES:-${CEDAR_ENTITIES:-}}"
  context_in="${INPUT_CONTEXT:-${CEDAR_CONTEXT:-}}"

  work=$(mktemp -d "${TMPDIR:-/tmp}/cedar-cani.XXXXXX")
  trap 'rm -rf "$work"' EXIT INT TERM
  pol="$work/policies.cedar"
  ent="$work/entities.json"
  ctx="$work/context.json"
  out="$work/authorize.out"
  matrix="$work/matrix.json"
  : >"$pol"
  included_names=""

  names=$(kctl get "policies.${EXPECTED_GROUP}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}') || die "failed to list policies.${EXPECTED_GROUP}"
  n=0
  included=0
  skipped=0
  tmp=$(mktemp "${TMPDIR:-/tmp}/cedar-policy.XXXXXX")
  chmod 600 "$tmp"
  while IFS= read -r name || [ -n "$name" ]; do
    [ -n "$name" ] || continue
    n=$((n + 1))
    if [ "$n" -gt "$MAX_POLICIES" ]; then
      printf 'STOPPED: more than %s policies\n' "$MAX_POLICIES" >&2
      break
    fi
    content=$(fetch_content "$name") || {
      skipped=$((skipped + 1))
      continue
    }
    bytes=$(printf '%s' "$content" | wc -c | tr -d ' ')
    if [ "$bytes" -gt "$MAX_BYTES" ]; then
      skipped=$((skipped + 1))
      continue
    fi
    printf '%s' "$content" >"$tmp"
    if ! cedar check-parse --policies "$tmp" >/dev/null 2>&1; then
      skipped=$((skipped + 1))
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
  rm -f "$tmp"

  extra_actions=""
  if [ "$mode" = k8s ]; then
    extra_actions='k8s::Action::"get" k8s::Action::"list" k8s::Action::"watch" k8s::Action::"create" k8s::Action::"update" k8s::Action::"patch" k8s::Action::"delete"'
  fi
  if [ -n "$entities_in" ] && [ -f "$entities_in" ]; then
    cp "$entities_in" "$ent"
  else
    # shellcheck disable=SC2086
    write_entities "$ent" "$ns" "$apigroup" "$objname" "$principal" "$action" "$resource" $extra_actions
  fi
  if [ -n "$context_in" ] && [ -f "$context_in" ]; then
    cp "$context_in" "$ctx"
  else
    printf '{}\n' >"$ctx"
  fi

  set -- authorize -v --policies "$pol" --entities "$ent" --context "$ctx" \
    --principal "$principal" --action "$action" --resource "$resource"
  if [ -n "$schema" ]; then
    [ -f "$schema" ] || die "schema file not found: $schema"
    set -- "$@" --schema "$schema"
  fi

  set +e
  cedar "$@" >"$out" 2>&1
  rc=$?
  set -e
  cat "$out" >&2

  decision=$(awk '/^ALLOW$/{print "ALLOW"; exit} /^DENY$/{print "DENY"; exit}' "$out")
  determining=$(awk '/due to the following policies:/{grab=1; next} grab{if($0 ~ /^[[:space:]]*$/) exit; if($0 !~ /^[[:space:]]/) exit; gsub(/^[[:space:]]+/, ""); print}' "$out" | paste -sd, -)
  extra=""
  if [ -n "$determining" ]; then
    extra="  ·  ${determining}"
  fi
  if [ "$skipped" -gt 0 ]; then
    extra="${extra}  skipped=${skipped}"
  fi
  if [ -n "$ns" ]; then
    extra="  ns=${ns}${extra}"
  fi

  printf '[]\n' >"$matrix"
  if [ "$mode" = k8s ] && command -v python3 >/dev/null 2>&1; then
    matrix_json="["
    first=1
    for verb in get list watch create update patch delete; do
      verb_euid=$(normalize_euid 'k8s::Action' "$verb")
      set +e
      cedar authorize --policies "$pol" --entities "$ent" --context "$ctx" \
        --principal "$principal" --action "$verb_euid" --resource "$resource" >/dev/null 2>&1
      mrc=$?
      set -e
      mdec=DENY
      [ "$mrc" -eq 0 ] && mdec=ALLOW
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

  report="${CEDAR_K9S_REPORT:-${TMPDIR:-/tmp}/k9s-cedar-can-i.html}"
  case "$decision" in
    ALLOW | DENY)
      write_cani_report "$report" "$decision" "$p_label" "$principal" \
        "$a_label" "$action" "$r_label" "$resource" \
        "$ns" "$apigroup" "$objname" "$mode" "${CONTEXT:-default}" \
        "$included" "$skipped" "$included_names" \
        "$pol" "$ent" "$out" "$matrix" || true
      open_cani_report "$report"
      printf '%s  %s  %s  %s%s\n' "$decision" "$p_label" "$a_label" "$r_label" "$extra"
      ;;
    *)
      die "can-i: cedar authorize failed (exit ${rc})"
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
  validate) run_validate ;;
  scan) run_scan ;;
  can-i) run_can_i ;;
esac

pause
exit 0
