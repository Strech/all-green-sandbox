#!/usr/bin/env bash
set -euo pipefail

job="${JOB:?}"
min="${MIN:-5}"
max="${MAX:-15}"

matches() {
  [ -s ".sandbox/$1" ] && grep -Eqx -f <(grep -v '^\s*$' ".sandbox/$1") <<<"$job"
}

if matches fail; then
  echo "forced failure: $job"
  exit 1
fi

if [ "$GITHUB_RUN_ATTEMPT" = "1" ] && matches flaky; then
  echo "flaky failure on first attempt: $job"
  exit 1
fi

seconds=$((min + RANDOM % (max - min + 1)))
matches slow && seconds=$((seconds * 5))

echo "running $job for ${seconds}s"
sleep "$seconds"
echo "ok: $job"
