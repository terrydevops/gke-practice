#!/usr/bin/env bash
# Writes a saved plan to the job summary (docs/ci-standard.md T5), with every
# cluster user replaced by ***. ::add-mask:: covers the logs; the summary is
# redacted here so it does not depend on that.
#   plan-summary.sh <dir> <planfile> <title>
set -euo pipefail
dir=$1 plan=$2 title=$3
out=$(mktemp)
terraform -chdir="$dir" show -no-color "$plan" > "$out"
printf '%s' "${CLUSTER_USERS:-[]}" | jq -r '.[] | sub("^[A-Za-z]+:"; "")' |
  while read -r u; do
    [ -n "$u" ] && U="$u" perl -pi -e 's/\Q$ENV{U}\E/***/g' "$out"
  done
{
  echo "### $title"
  echo
  grep -E '^(Plan:|No changes)' "$out" || echo "(no summary line)"
  echo
  echo '<details><summary>Full plan</summary>'
  echo
  echo '```text'
  cat "$out"
  echo '```'
  echo
  echo '</details>'
} >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"
rm -f "$out"
