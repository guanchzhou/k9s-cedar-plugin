#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
DEST="${K9S_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/k9s}"
mkdir -p "$DEST"
DEST=$(CDPATH= cd -- "$DEST" && pwd)
DEST=$(printf '%s' "$DEST" | sed 's|//*|/|g')
PLUGIN_DIR="$DEST/plugins/cedar"
PLUGIN_SH="$PLUGIN_DIR/plugin.sh"

mkdir -p "$PLUGIN_DIR" "$DEST/plugins"
cp "$ROOT/plugin.sh" "$PLUGIN_SH"
chmod 755 "$PLUGIN_SH"

# k9s loads *.yaml from plugins/ (and nested dirs). Keep defs at plugins/cedar.yaml.
sed "s|command: PLUGIN_SH|command: $PLUGIN_SH|" "$ROOT/k9s/plugins.yaml" >"$DEST/plugins/cedar.yaml"

VIEWS="$DEST/views.yaml"
MARKER="cedar.k8s.aws/v1alpha1/policies"
if [ -f "$VIEWS" ] && grep -q "$MARKER" "$VIEWS"; then
  printf 'views.yaml already has %s\n' "$MARKER"
else
  if [ ! -f "$VIEWS" ]; then
    printf 'views:\n' >"$VIEWS"
  fi
  printf '\n  # k9s-cedar-plugin\n  cedar.k8s.aws/v1alpha1/policies:\n    columns:\n      - NAME\n      - ENFORCED:.spec.validation.enforced\n      - VALMODE:.spec.validation.validationMode\n      - AGE\n' >>"$VIEWS"
  printf 'appended Cedar columns to %s\n' "$VIEWS"
fi

# :policies is Kyverno. Do not clobber existing aliases.
ALIASES="$DEST/aliases.yaml"
CEDAR_ALIAS_LINE="  cedarpol: cedar.k8s.aws/v1alpha1/policies"
if [ ! -f "$ALIASES" ]; then
  printf 'aliases:\n%s\n' "$CEDAR_ALIAS_LINE" >"$ALIASES"
  printf 'wrote %s\n' "$ALIASES"
elif grep -Eq '^[[:space:]]*cedarpol:' "$ALIASES"; then
  printf 'aliases.yaml already has cedarpol\n'
else
  if ! grep -Eq '^aliases:' "$ALIASES"; then
    printf '\naliases:\n' >>"$ALIASES"
  fi
  printf '%s\n' "$CEDAR_ALIAS_LINE" >>"$ALIASES"
  printf 'appended cedarpol to %s\n' "$ALIASES"
fi

printf 'Installed k9s snippets to %s\n' "$PLUGIN_DIR"
printf 'Requires: k9s, kubectl, cedar (cedar-policy-cli). plugin.sh prepends ~/.cargo/bin if needed.\n'
printf 'In k9s open :cedarpol (not :policies — that is Kyverno). Shortcuts: Shift-C format, Shift-P check-parse, Shift-V validate, Shift-A scan.\n'
