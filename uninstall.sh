#!/bin/sh
set -eu

if [ -n "${K9S_CONFIG_DIR:-}" ]; then
  DEST=$K9S_CONFIG_DIR
elif [ -n "${XDG_CONFIG_HOME:-}" ]; then
  DEST="$XDG_CONFIG_HOME/k9s"
elif [ "$(uname -s)" = Darwin ]; then
  DEST="$HOME/Library/Application Support/k9s"
else
  DEST="$HOME/.config/k9s"
fi

if [ ! -d "$DEST" ]; then
  printf 'nothing to remove: %s does not exist\n' "$DEST"
  exit 0
fi

rm -f "$DEST/plugins/cedar.yaml"
rm -rf "$DEST/plugins/cedar"
printf 'removed Cedar plugin from %s/plugins\n' "$DEST"

# Only drop the exact blocks install.sh writes; anything else is left alone.
strip_file() {
  file=$1
  label=$2
  awk_prog=$3
  [ -f "$file" ] || return 0
  tmp=$(mktemp "$file.XXXXXX")
  awk "$awk_prog" "$file" >"$tmp"
  if cmp -s "$file" "$tmp"; then
    rm -f "$tmp"
  else
    mv -f "$tmp" "$file"
    printf 'removed %s from %s\n' "$label" "$file"
  fi
}

strip_file "$DEST/views.yaml" "Cedar columns" '
  /^$/ { blank++; next }
  $0 == "  # k9s-cedar-plugin" { blank = 0; next }
  $0 ~ /^  cedar\.k8s\.aws\/v1alpha1\/policies:[[:space:]]*$/ { skip = 1; next }
  skip && /^    / { next }
  { skip = 0; while (blank > 0) { print ""; blank-- } print }
  END { while (blank > 0) { print ""; blank-- } }
'
strip_file "$DEST/aliases.yaml" "cedarpol alias" '
  $0 == "  cedarpol: cedar.k8s.aws/v1alpha1/policies" { next }
  { print }
'

printf 'Quit k9s fully and launch it again.\n'
