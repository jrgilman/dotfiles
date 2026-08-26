#!/usr/bin/env bash
#
# One-time setup for the youtrack skill: create the auth env file and
# wire it into your shell so YOUTRACK_BASE_URL / YOUTRACK_AUTHORIZATION get exported.
# Idempotent — safe to re-run; it never overwrites an existing env file or duplicates
# the source line.
#
#   scripts/setup.sh [RC_FILE]     # RC_FILE defaults to ~/.bashrc
#
set -euo pipefail

env_dir="${HOME}/.config/llm-skills"
env_file="${env_dir}/youtrack-agile.env"
rc_file="${1:-${HOME}/.bashrc}"
source_line="set -a; . \"${env_file}\" 2>/dev/null; set +a"

mkdir -p "$env_dir"

if [[ -e "$env_file" ]]; then
    echo "env file already exists, left as-is: $env_file"
else
    cat >"$env_file" <<'ENVFILE'
# YouTrack auth for the youtrack skill. Keep this file OUT of version control.
# Replace the token below; YOUTRACK_BASE_URL is the YouTrack instance origin.
YOUTRACK_BASE_URL=https://oscillas.youtrack.cloud
YOUTRACK_AUTHORIZATION=Bearer REPLACE_WITH_TOKEN
ENVFILE
    echo "created env file: $env_file"
fi
chmod 600 "$env_file"

if [[ -f "$rc_file" ]] && grep -qF "$env_file" "$rc_file"; then
    echo "already wired into: $rc_file"
else
    printf '\n# youtrack skill auth\n%s\n' "$source_line" >>"$rc_file"
    echo "wired source line into: $rc_file"
fi

cat <<NEXT

Done. Next:
  1. Edit $env_file and replace REPLACE_WITH_TOKEN with your token.
  2. Open a new shell, or run: source "$rc_file"
NEXT
