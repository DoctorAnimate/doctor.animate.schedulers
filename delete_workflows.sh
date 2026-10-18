#!/usr/bin/env bash
# Delete ALL GitHub Actions workflow runs in the current repo, in parallel,
# printing a live status line every few seconds.
#
#   bash delete_workflows.sh            # 32 parallel deletes (default)
#   bash delete_workflows.sh 64         # more parallelism
#   PARALLEL=8 bash delete_workflows.sh
#   INTERVAL=2 bash delete_workflows.sh # status every 2s (default 5s)
#
# Requires: gh (installed + authenticated). Deletes everything. No confirmation, no undo.
# Ctrl+C stops it.

set -uo pipefail

PARALLEL="${1:-${PARALLEL:-32}}"
INTERVAL="${INTERVAL:-5}"
REPO="${GH_REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
LOG="$(mktemp -t del_runs.XXXXXX)"
MON=""
export REPO LOG

cleanup() { [ -n "$MON" ] && kill "$MON" 2>/dev/null; rm -f "$LOG"; }
trap cleanup EXIT INT TERM

# -> "<total_count>\t<created_at of newest remaining run>" (one API call)
status() {
  gh api "repos/$REPO/actions/runs?per_page=1" \
    -q '"\(.total_count)\t\(.workflow_runs[0].created_at)"' 2>/dev/null
}

# Live status line: totals come from the log file, remaining comes from the API.
monitor() {
  while sleep "$INTERVAL"; do
    line=$(status)
    rem=${line%%$'\t'*}
    newest=${line#*$'\t'}
    printf '[%s] deleted=%s failed=%s remaining=%s newest_left=%s\n' \
      "$(date +%H:%M:%S)" \
      "$(grep -c '^deleted ' "$LOG")" \
      "$(grep -c '^FAILED ' "$LOG")" \
      "${rem:-?}" "${newest:-?}"
  done
}

echo "Repo: $REPO | workers: $PARALLEL | status every ${INTERVAL}s"
echo "Starting... (Ctrl+C to stop)"
monitor &
MON=$!

round=0
while :; do
  round=$((round + 1))

  # List endpoint is paginated: 100 runs per request, follows every page.
  ids=$(gh api --paginate "repos/$REPO/actions/runs?per_page=100" -q '.workflow_runs[].id' 2>/dev/null)

  if [ -z "$ids" ]; then
    echo "No more workflow runs to delete."
    break
  fi

  d0=$(grep -c '^deleted ' "$LOG")
  f0=$(grep -c '^FAILED ' "$LOG")
  total=$(printf '%s\n' "$ids" | grep -c .)
  echo "Round $round: $total run(s) left -> deleting with $PARALLEL workers"

  # One DELETE per run, $PARALLEL at a time, 3 attempts each for transient
  # failures (GitHub secondary rate limits / 5xx). Results go to $LOG, which
  # the monitor is tallying.
  printf '%s\n' "$ids" | xargs -P "$PARALLEL" -n 1 bash -c '
    id="$1"
    for attempt in 1 2 3; do
      if gh api -X DELETE "repos/$REPO/actions/runs/$id" >/dev/null 2>&1; then
        echo "deleted $id" >> "$LOG"
        exit 0
      fi
      sleep 2
    done
    echo "FAILED $id" >> "$LOG"' _

  deleted=$(( $(grep -c '^deleted ' "$LOG") - d0 ))
  failed=$(( $(grep -c '^FAILED ' "$LOG") - f0 ))
  echo "Round $round finished: deleted $deleted, failed $failed, remaining $(status | cut -f1)"

  # Safety brake: a round that deletes nothing means stop instead of spinning.
  if [ "$deleted" -eq 0 ]; then
    echo "No progress this round - stopping (nothing deletable left)."
    break
  fi
done

if [ "$(grep -c '^FAILED ' "$LOG")" -gt 0 ]; then
  echo "Failed runs (left behind):"
  grep '^FAILED ' "$LOG"
fi
echo "Total deleted this run: $(grep -c '^deleted ' "$LOG") | remaining: $(status | cut -f1)"
