---
name: pr-monitor
description: Stream a GitHub PR's activity — CI checks, submitted reviews, comments, and merge/close — as background notifications, one line per event. Use when watching one or more open PRs for review feedback or CI results; launch its script through the Monitor tool instead of hand-writing a poll loop (hand-rolled ones keep forgetting to watch CI checks, so failed checks go unseen).
---

# PR Monitor

Watches one or more open PRs and emits one line per new event:

- **CI checks** — when the check rollup flips to FAILED (with the failing check names) or to passed. A re-run resets to pending first, so the next terminal state re-notifies.
- **Submitted reviews** — author, state (APPROVED / CHANGES_REQUESTED / COMMENTED), body.
- **Issue comments** and **inline review comments** — author, path, body.
- **State** — emits and stops watching a PR once it merges or closes.

It baselines current activity on start, so pre-existing reviews/comments/checks don't fire, and it exits once every watched PR is closed.

## Launch it

Run the script through the **Monitor tool** with `persistent: true`, from the repo root (gh resolves owner/repo from the working directory):

```
Monitor(
  persistent: true,
  timeout_ms: 3600000,
  description: "CI / reviews / comments / merge on PRs #78, #79",
  command: "cd /path/to/repo && bash ~/.codex/skills/pr-monitor/scripts/pr-monitor.sh 78 79"
)
```

Pass every PR number to watch as an argument. To change the watched set (a new PR opened, one merged), `TaskStop` the old monitor and relaunch with the full current set.

## Notes

- `POLL_INTERVAL` (env) sets seconds between polls; default 60.
- Because comments post through the `gh` CLI as the token owner, your *own* posted comments and review replies echo back once as events — benign. Fetch the item and confirm it's yours rather than acting on it. (This is why the token owner and a human reviewer can look identical; distinguish by content/timing, not author.)
- Requires `gh` authenticated, run inside the target repo, remote on GitHub.
- It only watches — it never comments, reviews, merges, or mutates anything.
