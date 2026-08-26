# Global preferences

## Privileged commands (sudo)

- Give sudo/privileged commands as plain command blocks for me to paste into my own terminal — never suggest an agent-side passthrough prefix (e.g. Claude Code's `!`). My sudo uses a fingerprint prompt that doesn't work reliably under those, and agent shell tools have no terminal for sudo either (fingerprint times out, then "a terminal is required").
- Caution: if a `!`-prefixed one-liner gets pasted into a plain bash shell, the leading `!` negates the first command's exit status and silently kills the rest of an `&&` chain (this once caused a confusing half-installed state).
- For multi-step privileged installs, prefer several short commands (or a script I run once) over one long `&&` one-liner, so partial failures are visible.
