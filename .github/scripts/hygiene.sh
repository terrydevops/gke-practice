#!/usr/bin/env bash
# Repo hygiene (docs/ci-standard.md B9): tracked text files are English only.
# Commits here carry Co-Authored-By on purpose, so the attribution check that
# eth-docker-practice runs is off unless CHECK_ATTRIBUTION=1.
set -euo pipefail
cd "$(dirname "$0")/../.."

rc=0
check() { # name grep-args...
  local name=$1 out; shift
  printf '%-10s' "$name"
  if out=$(git grep -nI "$@"); then
    echo FAIL; echo "$out"; rc=1
  else
    echo ok
  fi
}
check cjk -P '[\x{4e00}-\x{9fff}\x{3000}-\x{303f}\x{ff00}-\x{ffef}]'
if [ "${CHECK_ATTRIBUTION:-0}" = 1 ]; then
  # brackets keep this script from matching itself
  check names -iE 'cl[a]ude|co-a[u]thored-by'
fi
exit "$rc"
