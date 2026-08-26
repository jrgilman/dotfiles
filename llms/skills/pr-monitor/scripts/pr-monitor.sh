#!/usr/bin/env bash
# pr-monitor.sh — stream GitHub PR activity as one line per event.
#
# Watches, for each PR passed as an argument:
#   - CI checks         (emits when the check rollup flips to FAILED — with the failing
#                        check names — or to passed; re-runs re-notify)
#   - submitted reviews (author, state, body)
#   - issue comments    (author, body)
#   - inline review comments (author, path, body)
#   - state             (emits + stops watching that PR when it merges/closes)
#
# WHY THIS EXISTS: hand-rolled poll loops kept forgetting to watch CI checks, so a failed
# "Validate PR Body" / test run was invisible. This watches checks too. Don't re-derive it.
#
# USAGE:  cd <repo> && pr-monitor.sh <pr-number> [<pr-number> ...]
#   Run from inside the target git repo — gh resolves owner/repo from the working directory.
#   Launch it through the Monitor tool with persistent:true so each stdout line becomes a
#   notification. It baselines current activity on start (no events for pre-existing state)
#   and exits once every watched PR is closed.
#
# ENV:  POLL_INTERVAL   seconds between polls (default 60)
set -u

prs=("$@")
if [ ${#prs[@]} -eq 0 ]; then
  echo "usage: pr-monitor.sh <pr-number> [<pr-number> ...]" >&2
  exit 2
fi
interval="${POLL_INTERVAL:-60}"
dir="$(mktemp -d "${TMPDIR:-/tmp}/prmon.XXXXXX")"
trap 'rm -rf "$dir"' EXIT

# Reviewable surface of a PR: its state plus the ids of every review / comment / inline note.
fetch() {
  gh pr view "$1" --json state --jq '"state:\(.state)"' 2>/dev/null || true
  gh api "repos/{owner}/{repo}/pulls/$1/reviews"  --paginate --jq '.[] | "review:\(.id):\(.state)"' 2>/dev/null || true
  gh api "repos/{owner}/{repo}/issues/$1/comments" --paginate --jq '.[] | "comment:\(.id)"'          2>/dev/null || true
  gh api "repos/{owner}/{repo}/pulls/$1/comments"  --paginate --jq '.[] | "inline:\(.id)"'           2>/dev/null || true
}

# CI rollup: FAIL if any check failed, PENDING if any still running, PASS if all passed, NONE if none.
rollup() {
  local roll
  roll="$(gh pr checks "$1" --json bucket --jq '[.[].bucket]' 2>/dev/null || true)"
  if   printf '%s' "$roll" | grep -qE '"(fail|cancel|action_required|timed_out)"'; then echo FAIL
  elif printf '%s' "$roll" | grep -q '"pending"';                                   then echo PENDING
  elif [ -n "$roll" ] && [ "$roll" != "[]" ];                                       then echo PASS
  else echo NONE
  fi
}

# Baseline so pre-existing activity does not fire.
for pr in "${prs[@]}"; do
  fetch "$pr" | sort > "$dir/seen-$pr" 2>/dev/null || true
  rollup "$pr" > "$dir/roll-$pr"
done

while true; do
  sleep "$interval"
  active=0
  for pr in "${prs[@]}"; do
    [ -f "$dir/done-$pr" ] && continue
    active=1

    cur="$dir/cur-$pr"
    fetch "$pr" | sort > "$cur" 2>/dev/null || true
    if [ -s "$cur" ]; then
      new="$(comm -13 "$dir/seen-$pr" "$cur")"
      if [ -n "$new" ]; then
        while IFS= read -r line; do
          [ -z "$line" ] && continue
          kind="${line%%:*}"; rest="${line#*:}"
          case "$kind" in
            state)
              [ "$rest" != "OPEN" ] && { echo "PR #$pr is now $rest"; touch "$dir/done-$pr"; } ;;
            review)
              id="${rest%%:*}"; rstate="${rest##*:}"
              [ "$rstate" = "PENDING" ] && continue
              gh api "repos/{owner}/{repo}/pulls/$pr/reviews/$id" \
                --jq '"PR #'"$pr"' review (\(.state)) by \(.user.login): \(.body // "(no body)" | .[0:500])"' 2>/dev/null \
                || echo "PR #$pr new review $id ($rstate)" ;;
            comment)
              gh api "repos/{owner}/{repo}/issues/comments/$rest" \
                --jq '"PR #'"$pr"' comment by \(.user.login): \(.body | .[0:500])"' 2>/dev/null \
                || echo "PR #$pr new comment $rest" ;;
            inline)
              gh api "repos/{owner}/{repo}/pulls/comments/$rest" \
                --jq '"PR #'"$pr"' inline by \(.user.login) on \(.path): \(.body | .[0:500])"' 2>/dev/null \
                || echo "PR #$pr new inline $rest" ;;
          esac
        done <<< "$new"
        sort -u "$dir/seen-$pr" "$cur" > "$dir/seen-$pr.tmp" && mv "$dir/seen-$pr.tmp" "$dir/seen-$pr"
      fi
    fi

    # CI rollup — emit only on a change into a terminal state. A re-run resets to PENDING first,
    # so the next terminal state differs from the stored one and re-notifies.
    rs="$(rollup "$pr")"
    last="$(cat "$dir/roll-$pr" 2>/dev/null || echo)"
    if [ "$rs" != "$last" ]; then
      case "$rs" in
        FAIL) echo "PR #$pr CI FAILED:"; gh pr checks "$pr" 2>/dev/null | grep -iE 'fail|cancel|timed' | head -6 ;;
        PASS) echo "PR #$pr CI passed." ;;
      esac
    fi
    echo "$rs" > "$dir/roll-$pr"
  done
  [ "$active" -eq 0 ] && { echo "All watched PRs closed. pr-monitor exiting."; break; }
done
