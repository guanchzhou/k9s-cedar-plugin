#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
# Same lookup order as k9s itself.
if [ -n "${K9S_CONFIG_DIR:-}" ]; then
  DEST=$K9S_CONFIG_DIR
elif [ -n "${XDG_CONFIG_HOME:-}" ]; then
  DEST="$XDG_CONFIG_HOME/k9s"
elif [ "$(uname -s)" = Darwin ]; then
  DEST="$HOME/Library/Application Support/k9s"
else
  DEST="$HOME/.config/k9s"
fi
mkdir -p "$DEST"
DEST=$(CDPATH='' cd -- "$DEST" && pwd)
DEST=$(printf '%s' "$DEST" | sed 's|//*|/|g')
PLUGIN_DIR="$DEST/plugins/cedar"
PLUGIN_SH="$PLUGIN_DIR/plugin.sh"

mkdir -p "$PLUGIN_DIR" "$DEST/plugins"
cp "$ROOT/plugin.sh" "$PLUGIN_SH"
chmod 755 "$PLUGIN_SH"
cp "$ROOT/cani_report.py" "$PLUGIN_DIR/cani_report.py"

# k9s loads *.yaml from plugins/ (and nested dirs). Keep defs at plugins/cedar.yaml.
PLUGIN_SH_YAML=$(python3 - "$PLUGIN_SH" <<'PY'
import json, sys
print(json.dumps(sys.argv[1], ensure_ascii=False))
PY
)
PLUGIN_SH_SED=$(printf '%s' "$PLUGIN_SH_YAML" | sed -e 's/[\\&]/\\&/g' -e 's/|/\\|/g')
PLUGIN_YAML_TMP=$(mktemp "$DEST/plugins/.cedar.yaml.XXXXXX")
sed "s|command: PLUGIN_SH|command: $PLUGIN_SH_SED|" "$ROOT/k9s/plugins.yaml" >"$PLUGIN_YAML_TMP"
mv -f "$PLUGIN_YAML_TMP" "$DEST/plugins/cedar.yaml"

VIEWS="$DEST/views.yaml"
VIEW_KEY="cedar.k8s.aws/v1alpha1/policies"
if [ -f "$VIEWS" ] && grep -Eq "^[[:space:]]{2}${VIEW_KEY}:([[:space:]]|$)" "$VIEWS"; then
  printf 'views.yaml already has %s\n' "$VIEW_KEY"
elif [ ! -s "$VIEWS" ]; then
  printf 'views:\n  cedar.k8s.aws/v1alpha1/policies:\n    columns:\n      - NAME\n      - ENFORCED:.spec.validation.enforced\n      - VALMODE:.spec.validation.validationMode\n      - AGE\n' >"$VIEWS"
  printf 'wrote Cedar columns to %s\n' "$VIEWS"
elif grep -Eq '^views:[[:space:]]*$' "$VIEWS"; then
  printf '\n  # k9s-cedar-plugin\n  cedar.k8s.aws/v1alpha1/policies:\n    columns:\n      - NAME\n      - ENFORCED:.spec.validation.enforced\n      - VALMODE:.spec.validation.validationMode\n      - AGE\n' >>"$VIEWS"
  printf 'appended Cedar columns to %s\n' "$VIEWS"
else
  printf 'left %s unchanged: merge k9s/views.yaml under a block-style views: key\n' "$VIEWS" >&2
fi

# :policies is Kyverno. Do not clobber existing aliases.
ALIASES="$DEST/aliases.yaml"
CEDAR_ALIAS_LINE="  cedarpol: cedar.k8s.aws/v1alpha1/policies"
if [ ! -s "$ALIASES" ]; then
  printf 'aliases:\n%s\n' "$CEDAR_ALIAS_LINE" >"$ALIASES"
  printf 'wrote %s\n' "$ALIASES"
elif grep -Eq '^[[:space:]]*cedarpol:' "$ALIASES"; then
  printf 'aliases.yaml already has cedarpol\n'
elif grep -Eq '^aliases:[[:space:]]*$' "$ALIASES"; then
  printf '%s\n' "$CEDAR_ALIAS_LINE" >>"$ALIASES"
  printf 'appended cedarpol to %s\n' "$ALIASES"
else
  printf 'left %s unchanged: merge k9s/aliases.yaml under a block-style aliases: key\n' "$ALIASES" >&2
fi

printf 'Installed k9s snippets to %s\n' "$PLUGIN_DIR"
printf 'Requires: k9s, kubectl, cedar (cedar-policy-cli), python3. plugin.sh appends ~/.cargo/bin to PATH if needed.\n'
printf 'Quit k9s fully and launch it again. Open :cedarpol (not :policies — that is Kyverno). Select a Policy row. Shortcuts: Shift-C format, Shift-P check-parse, Shift-V validate, Shift-A scan, Shift-I can-i. Shift-I prompts P/A/R, opens a report, and flashes Allow/Deny.\n'
