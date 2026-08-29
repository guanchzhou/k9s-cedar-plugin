#!/bin/sh
# Full plugin testsuite: language fixtures, mock-kubectl glue, optional live cluster.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
"$ROOT/tests/test-offline.sh"
"$ROOT/tests/test-cluster.sh"
printf 'all tests passed\n'
