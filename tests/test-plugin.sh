#!/bin/sh
# Full plugin testsuite: language fixtures, mock-kubectl glue, and the live
# cluster suite when CEDAR_K9S_CLUSTER_TESTS=1.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
"$ROOT/tests/test-offline.sh"
"$ROOT/tests/test-cluster.sh"
printf 'all tests passed\n'
