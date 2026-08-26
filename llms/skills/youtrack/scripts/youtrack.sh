#!/usr/bin/env bash

set -euo pipefail
set +x

readonly SCRIPT_NAME="$(basename "$0")"
readonly ISSUE_FIELDS='id,idReadable,summary,description,created,updated,resolved,reporter(id,login,fullName),project(id,name,shortName),tags(id,name),customFields(id,name,%24type,value(id,name,login,fullName,text,minutes,presentation))'
readonly COMMENT_FIELDS='id,text,created,updated,deleted,author(id,login,fullName)'
readonly COMMENT_PAGE_SIZE=100

usage() {
    cat <<'USAGE'
Usage:
  Issue read operations:
    youtrack.sh issues get ISSUE_ID [--json]
    youtrack.sh issues comments list ISSUE_ID [--json]

  Agile board operations, which the MCP server does not expose:
    youtrack.sh boards [--project KEY] [--name TEXT] [--json]
    youtrack.sh sprints --board NAME_OR_ID [--name TEXT] [--include-archived] [--json]
    youtrack.sh add --board NAME_OR_ID --sprint NAME_OR_ID [--dry-run] ISSUE_ID...

  Payload operations, for content too large or too awkward for the MCP tools:
    youtrack.sh comment ISSUE_ID (--file PATH | --stdin | --text TEXT)
    youtrack.sh attach ISSUE_ID --file PATH
    youtrack.sh api METHOD PATH [--data-file PATH | --data-stdin | --data JSON]

Use the MCP tools to create, update, search, and link issues.
Use this script to read one issue or its comments and manage boards and sprints.
Also use it for large payloads, attachments, and endpoints that MCP does not support.

With --file and --stdin the payload is streamed from disk to curl. It never
becomes a command argument.

Authentication comes from the environment: YOUTRACK_BASE_URL (the instance origin)
and YOUTRACK_AUTHORIZATION (the header value, e.g. "Bearer <token>"). The script
errors if either is empty. The token is written to a private curl config file
rather than an argument, so it does not appear in the process list.

Examples:
  youtrack.sh issues get ARTC-1234
  youtrack.sh issues get --json ARTC-1234
  youtrack.sh issues comments list ARTC-1234
  youtrack.sh issues comments list --json ARTC-1234
  youtrack.sh comment ARTC-1234 --file notes.md
  git log --oneline -20 | youtrack.sh comment ARTC-1234 --stdin
  youtrack.sh attach ARTC-1234 --file docs/plans/design.md
  youtrack.sh api GET /api/users/me?fields=id,login,fullName
USAGE
}

fail() {
    printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

configure_api() {
    [[ -n "${YOUTRACK_AUTHORIZATION:-}" ]] || fail "YOUTRACK_AUTHORIZATION is empty — set it before running (e.g. source your .env)"
    [[ -n "${YOUTRACK_BASE_URL:-}" ]] || fail "YOUTRACK_BASE_URL is empty — set it before running (e.g. source your .env)"

    authorization_value="$YOUTRACK_AUTHORIZATION"

    base_url="${YOUTRACK_BASE_URL%/}"
    base_url="${base_url%/api}"
}

# The Authorization header goes in a private curl config file, not an argument,
# so the token never shows up in the process list. The file is removed on exit.
auth_config_file=""
auth_config_args=()

prepare_auth_config() {
    [[ -n "$auth_config_file" ]] && return 0

    auth_config_file="$(mktemp)"
    chmod 600 "$auth_config_file"
    printf 'header = "Authorization: %s"\n' "$authorization_value" >"$auth_config_file"
    auth_config_args=(--config "$auth_config_file")
    trap 'rm -f "$auth_config_file"' EXIT
}

api_request() {
    local method="$1"
    local path="$2"
    local body="${3:-}"

    prepare_auth_config

    local -a curl_args=(
        --fail-with-body
        --silent
        --show-error
        --request "$method"
        "${auth_config_args[@]}"
        --header 'Accept: application/json'
    )

    if [[ -n "$body" ]]; then
        curl_args+=(--header 'Content-Type: application/json' --data "$body")
    fi

    curl "${curl_args[@]}" "${base_url}${path}"
}

get_issue() {
    local issue_id=''
    local has_issue_id=false
    local output_json=false
    while (($#)); do
        case "$1" in
            --json)
                [[ "$output_json" == false ]] || fail "issues get accepts --json once"
                output_json=true
                shift
                ;;
            -*) fail "unknown issues get option: $1" ;;
            *)
                [[ "$has_issue_id" == false ]] || fail "issues get accepts one issue ID"
                issue_id="$1"
                has_issue_id=true
                shift
                ;;
        esac
    done
    [[ "$issue_id" =~ [^[:space:]] ]] || fail "issues get needs one issue ID"
    local encoded_issue_id
    local response
    encoded_issue_id="$(jq -rn --arg issue_id "$issue_id" '$issue_id | @uri')"
    response="$(api_request GET "/api/issues/${encoded_issue_id}?fields=${ISSUE_FIELDS}")"
    jq -e -s 'length == 1' <<<"$response" >/dev/null 2>&1 || fail "issue response is not valid JSON"
    jq -e 'type == "object"' <<<"$response" >/dev/null || fail "issue response must be an object"
    jq -e '(.idReadable | type == "string") and (.summary | type == "string")' <<<"$response" >/dev/null \
        || fail "issue response needs string idReadable and summary fields"
    jq -e '((has("description") | not) or .description == null or ((.description | type) == "string"))' \
        <<<"$response" >/dev/null || fail "the description in the issue response must be a string or null"
    jq -e '((has("customFields") | not) or .customFields == null or ((.customFields | type) == "array"))' \
        <<<"$response" >/dev/null || fail "the customFields value in the issue response must be an array or null"
    jq -e 'if .customFields == null then true else (.customFields | map(type == "object") | all) end' \
        <<<"$response" >/dev/null || fail "each customFields entry in the issue response must be an object"
    jq -e '
        def field_has_type_when_present($name; $expected_type):
            (has($name) | not) or ((.[$name] | type) == $expected_type);
        def fields_are_strings_when_present($names):
            . as $object
            | all($names[]; . as $name
                | ($object | has($name) | not) or (($object[$name] | type) == "string"));
        field_has_type_when_present("id"; "string")
        and field_has_type_when_present("created"; "number")
        and field_has_type_when_present("updated"; "number")
        and ((has("resolved") | not) or .resolved == null or ((.resolved | type) == "number"))
        and (
            (has("reporter") | not)
            or .reporter == null
            or (if (.reporter | type) == "object"
                then (.reporter | fields_are_strings_when_present(["id", "login", "fullName"]))
                else false end)
        )
        and (
            (has("project") | not)
            or (if (.project | type) == "object"
                then (.project | fields_are_strings_when_present(["id", "name", "shortName"]))
                else false end)
        )
        and (
            (has("tags") | not)
            or (if (.tags | type) == "array"
                then all(.tags[];
                    if type == "object"
                    then ((.id | type) == "string") and ((.name | type) == "string")
                    else false end)
                else false end)
        )
        and (if .customFields == null then true else all(.customFields[];
            ((.name | type) == "string")
            and fields_are_strings_when_present(["id", "$type"])
            and (if .name == "State" or .name == "Type" or .name == "Priority"
                then .value == null or (if (.value | type) == "object"
                    then ((.value.name | type) == "string")
                    else false end)
                else true end)
        ) end)
    ' <<<"$response" >/dev/null || fail "issue response has malformed projected fields"
    if [[ "$output_json" == true ]]; then
        jq . <<<"$response"
        return
    fi
    jq -r '
        def field($name):
            ([.customFields[]? | select(.name == $name) | .value.name?][0] // "");
        [.idReadable, field("State"), field("Type"), field("Priority"), .summary] | @tsv
    ' <<<"$response"
    if jq -e '(.description | type) == "string" and .description != ""' <<<"$response" >/dev/null; then
        printf '\n'
        jq -j '.description' <<<"$response"
    fi
}

strict_json_document() {
    local response_file="$1"
    python3 - "$response_file" <<'PYTHON'
import json
import sys


def reject_nonstandard_constant(value):
    raise ValueError(f"nonstandard JSON constant: {value}")


try:
    with open(sys.argv[1], encoding="utf-8") as response:
        json.load(response, parse_constant=reject_nonstandard_constant)
except (OSError, UnicodeError, ValueError):
    raise SystemExit(1)
PYTHON
}

request_comment_page() {
    local path="$1"
    local response_file
    local cleanup_command
    prepare_auth_config
    response_file="$(mktemp)" || return 2
    printf -v cleanup_command 'rm -f -- %q %q' "$auth_config_file" "$response_file"
    trap "$cleanup_command" EXIT
    chmod 600 "$response_file" || {
        rm -f "$response_file"
        return 2
    }
    if ! api_request GET "$path" >"$response_file"; then
        rm -f "$response_file"
        return 2
    fi
    if ! strict_json_document "$response_file"; then
        rm -f "$response_file"
        return 3
    fi
    if ! cat "$response_file"; then
        rm -f "$response_file"
        return 2
    fi
    rm -f "$response_file"
}

validate_comment_page() {
    local page="$1"
    jq -e -s 'length == 1' <<<"$page" >/dev/null 2>&1 \
        || fail "comment page is not valid JSON"
    jq -e 'type == "array"' <<<"$page" >/dev/null \
        || fail "comment page must be an array"
    jq -e '
        all(.[];
            if type != "object" then false
            else
                (has("id") and ((.id | type) == "string"))
                and (has("text") and (.text == null or ((.text | type) == "string")))
                and (has("created") and ((.created | type) == "number"))
                and (has("updated") and (.updated == null or ((.updated | type) == "number")))
                and (has("deleted") and ((.deleted | type) == "boolean"))
                and (has("author") and (
                    if .author == null then true
                    elif (.author | type) == "object" then
                        (.author | has("id")) and ((.author.id | type) == "string")
                        and (.author | has("login")) and ((.author.login | type) == "string")
                        and (.author | has("fullName")) and ((.author.fullName | type) == "string")
                    else false
                    end
                ))
            end
        )
    ' <<<"$page" >/dev/null 2>&1 || fail "comment page has malformed projected fields"
}

list_issue_comments() {
    local issue_id=''
    local has_issue_id=false
    local output_json=false
    while (($#)); do
        case "$1" in
            --json)
                [[ "$output_json" == false ]] || fail "issues comments list accepts --json once"
                output_json=true
                shift
                ;;
            -*) fail "unknown issues comments list option: $1" ;;
            *)
                [[ "$has_issue_id" == false ]] || fail "issues comments list accepts one issue ID"
                issue_id="$1"
                has_issue_id=true
                shift
                ;;
        esac
    done
    [[ "$issue_id" =~ [^[:space:]] ]] || fail "issues comments list needs one issue ID"
    require_command python3

    local encoded_issue_id
    local offset=0
    local page
    local page_count
    local page_status
    local comments='[]'
    encoded_issue_id="$(jq -rn --arg issue_id "$issue_id" '$issue_id | @uri')"
    while :; do
        page_status=0
        page="$(request_comment_page "/api/issues/${encoded_issue_id}/comments?fields=${COMMENT_FIELDS}&%24top=${COMMENT_PAGE_SIZE}&%24skip=${offset}")" \
            || page_status=$?
        case "$page_status" in
            0) ;;
            3) fail "comment page is not valid JSON" ;;
            *) fail "comment request failed" ;;
        esac
        validate_comment_page "$page"
        page_count="$(jq 'length' <<<"$page")"
        if ((page_count == 0)); then
            break
        fi
        comments="$(printf '%s\n%s\n' "$comments" "$page" | jq -s '.[0] + .[1]')"
        offset=$((offset + page_count))
    done

    if [[ "$output_json" == true ]]; then
        jq -M . <<<"$comments"
        return
    fi
    jq -j '
        . as $comments
        | to_entries[]
        | .key as $index
        | .value as $comment
        | (([
                $comment.id,
                ($comment.author.login // ""),
                ($comment.author.fullName // ""),
                $comment.created,
                ($comment.updated // ""),
                $comment.deleted
            ] | @tsv)
            + "\n\n"
            + ($comment.text // "")
            + (if ($index + 1) < ($comments | length) then "\n\n" else "" end))
    ' <<<"$comments"
}

dispatch_issue_comments() {
    (($# > 0)) || fail "issues comments needs an operation, for example list"
    [[ -n "$1" ]] || fail "issues comments needs an operation, for example list"
    local operation="$1"
    shift

    case "$operation" in
        list) list_issue_comments "$@" ;;
        *) fail "unknown issues comments operation: $operation" ;;
    esac
}

dispatch_issues() {
    (($# > 0)) || fail "issues needs an operation, for example get"
    [[ -n "$1" ]] || fail "issues needs an operation, for example get"
    local operation="$1"
    shift

    case "$operation" in
        get) get_issue "$@" ;;
        comments) dispatch_issue_comments "$@" ;;
        *) fail "unknown issues operation: $operation" ;;
    esac
}

# Sends a body read straight from a file, so a large payload never becomes an
# argument and never passes through the caller's context.
api_request_from_file() {
    local method="$1"
    local path="$2"
    local body_file="$3"

    prepare_auth_config

    curl \
        --fail-with-body \
        --silent \
        --show-error \
        --request "$method" \
        "${auth_config_args[@]}" \
        --header 'Accept: application/json' \
        --header 'Content-Type: application/json' \
        --data-binary "@${body_file}" \
        "${base_url}${path}"
}

fetch_boards() {
    api_request GET '/api/agiles?fields=id,name,projects(id,name,shortName)&%24top=100'
}

resolve_unique() {
    local json="$1"
    local selector="$2"
    local kind="$3"
    local matches
    local count

    matches="$(jq --arg selector "$selector" '
        [ .[] | select(.id == $selector or ((.name | ascii_downcase) == ($selector | ascii_downcase))) ]
    ' <<<"$json")"

    if [[ "$(jq 'length' <<<"$matches")" -eq 0 ]]; then
        matches="$(jq --arg selector "$selector" '
            [ .[] | select((.name | ascii_downcase) | contains($selector | ascii_downcase)) ]
        ' <<<"$json")"
    fi

    count="$(jq 'length' <<<"$matches")"
    if [[ "$count" -eq 0 ]]; then
        fail "no $kind matches: $selector"
    fi
    if [[ "$count" -gt 1 ]]; then
        jq -r '.[] | "  \(.id)\t\(.name)"' <<<"$matches" >&2
        fail "ambiguous $kind selector: $selector"
    fi

    jq -c '.[0]' <<<"$matches"
}

resolve_board() {
    local selector="$1"
    resolve_unique "$(fetch_boards)" "$selector" 'Agile Board'
}

fetch_sprints() {
    local board_id="$1"
    api_request GET "/api/agiles/${board_id}/sprints?fields=id,name,archived,start,finish,goal&%24top=100"
}

print_boards() {
    local project_key=''
    local name=''
    local output_json=false
    local boards

    while (($#)); do
        case "$1" in
            --project)
                (($# >= 2)) || fail "--project requires a key"
                project_key="$2"
                shift 2
                ;;
            --name)
                (($# >= 2)) || fail "--name requires text"
                name="$2"
                shift 2
                ;;
            --json)
                output_json=true
                shift
                ;;
            *) fail "unknown boards argument: $1" ;;
        esac
    done

    boards="$(fetch_boards)"
    if [[ -n "$project_key" ]]; then
        boards="$(jq --arg project "$project_key" '
            [ .[] | select(any(.projects[]?; (.shortName | ascii_downcase) == ($project | ascii_downcase))) ]
        ' <<<"$boards")"
    fi
    if [[ -n "$name" ]]; then
        boards="$(jq --arg name "$name" '
            [ .[] | select((.name | ascii_downcase) | contains($name | ascii_downcase)) ]
        ' <<<"$boards")"
    fi

    if [[ "$output_json" == true ]]; then
        jq . <<<"$boards"
    else
        jq -r '.[] | [.id, .name, ([.projects[].shortName] | join(","))] | @tsv' <<<"$boards"
    fi
}

print_sprints() {
    local board_selector=''
    local name=''
    local include_archived=false
    local output_json=false
    local board
    local board_id
    local sprints

    while (($#)); do
        case "$1" in
            --board)
                (($# >= 2)) || fail "--board requires a name or ID"
                board_selector="$2"
                shift 2
                ;;
            --name)
                (($# >= 2)) || fail "--name requires text"
                name="$2"
                shift 2
                ;;
            --include-archived)
                include_archived=true
                shift
                ;;
            --json)
                output_json=true
                shift
                ;;
            *) fail "unknown sprints argument: $1" ;;
        esac
    done

    [[ -n "$board_selector" ]] || fail "sprints requires --board"
    board="$(resolve_board "$board_selector")"
    board_id="$(jq -r '.id' <<<"$board")"
    sprints="$(fetch_sprints "$board_id")"

    if [[ "$include_archived" != true ]]; then
        sprints="$(jq '[ .[] | select(.archived != true) ]' <<<"$sprints")"
    fi
    if [[ -n "$name" ]]; then
        sprints="$(jq --arg name "$name" '
            [ .[] | select((.name | ascii_downcase) | contains($name | ascii_downcase)) ]
        ' <<<"$sprints")"
    fi

    if [[ "$output_json" == true ]]; then
        jq . <<<"$sprints"
    else
        jq -r '.[] | [.id, .name, (.archived | tostring)] | @tsv' <<<"$sprints"
    fi
}

add_issues() {
    local board_selector=''
    local sprint_selector=''
    local dry_run=false
    local -a issue_ids=()
    local board
    local board_id
    local sprint
    local sprint_id
    local sprints
    local sprint_issues
    local issue_id
    local issue
    local internal_issue_id
    local readable_issue_id
    local issue_project
    local request_body

    while (($#)); do
        case "$1" in
            --board)
                (($# >= 2)) || fail "--board requires a name or ID"
                board_selector="$2"
                shift 2
                ;;
            --sprint)
                (($# >= 2)) || fail "--sprint requires a name or ID"
                sprint_selector="$2"
                shift 2
                ;;
            --dry-run)
                dry_run=true
                shift
                ;;
            --*) fail "unknown add argument: $1" ;;
            *)
                issue_ids+=("$1")
                shift
                ;;
        esac
    done

    [[ -n "$board_selector" ]] || fail "add requires --board"
    [[ -n "$sprint_selector" ]] || fail "add requires --sprint"
    ((${#issue_ids[@]} > 0)) || fail "add requires at least one issue ID"

    board="$(resolve_board "$board_selector")"
    board_id="$(jq -r '.id' <<<"$board")"
    sprints="$(fetch_sprints "$board_id" | jq '[ .[] | select(.archived != true) ]')"
    sprint="$(resolve_unique "$sprints" "$sprint_selector" 'active sprint')"
    sprint_id="$(jq -r '.id' <<<"$sprint")"
    sprint_issues="$(api_request GET "/api/agiles/${board_id}/sprints/${sprint_id}/issues?fields=id,idReadable&%24top=1000")"

    for issue_id in "${issue_ids[@]}"; do
        issue="$(api_request GET "/api/issues/${issue_id}?fields=id,idReadable,summary,project(id,name,shortName)")"
        internal_issue_id="$(jq -r '.id' <<<"$issue")"
        readable_issue_id="$(jq -r '.idReadable' <<<"$issue")"
        issue_project="$(jq -r '.project.shortName' <<<"$issue")"

        if ! jq -e --arg project "$issue_project" 'any(.projects[]?; .shortName == $project)' <<<"$board" >/dev/null; then
            fail "$readable_issue_id belongs to $issue_project, which is not attached to board $(jq -r '.name' <<<"$board")"
        fi

        if jq -e --arg id "$internal_issue_id" 'any(.[]; .id == $id)' <<<"$sprint_issues" >/dev/null; then
            printf 'ALREADY\t%s\t%s\t%s\n' "$readable_issue_id" "$(jq -r '.name' <<<"$board")" "$(jq -r '.name' <<<"$sprint")"
            continue
        fi

        if [[ "$dry_run" == true ]]; then
            printf 'WOULD_ADD\t%s\t%s\t%s\n' "$readable_issue_id" "$(jq -r '.name' <<<"$board")" "$(jq -r '.name' <<<"$sprint")"
            continue
        fi

        request_body="$(jq -cn --arg id "$internal_issue_id" '{id: $id}')"
        api_request POST "/api/agiles/${board_id}/sprints/${sprint_id}/issues?fields=id,idReadable" "$request_body" >/dev/null
        printf 'ADDED\t%s\t%s\t%s\n' "$readable_issue_id" "$(jq -r '.name' <<<"$board")" "$(jq -r '.name' <<<"$sprint")"
        sprint_issues="$(jq --arg id "$internal_issue_id" --arg readable "$readable_issue_id" '. + [{id: $id, idReadable: $readable}]' <<<"$sprint_issues")"
    done
}

## Reads a payload from --file, --stdin, or --text into a temp file and echoes
## the path. Keeps large content out of arguments.
read_payload_to_file() {
    local source_kind="$1"
    local source_value="${2:-}"
    local payload_file

    payload_file="$(mktemp)"
    chmod 600 "$payload_file"

    case "$source_kind" in
        file)
            [[ -r "$source_value" ]] || fail "cannot read file: $source_value"
            cat -- "$source_value" >"$payload_file"
            ;;
        stdin)
            cat >"$payload_file"
            ;;
        text)
            printf '%s' "$source_value" >"$payload_file"
            ;;
    esac

    [[ -s "$payload_file" ]] || fail "payload is empty"
    printf '%s' "$payload_file"
}

add_comment() {
    local issue_id=""
    local source_kind=""
    local source_value=""

    while (($# > 0)); do
        case "$1" in
            --file) source_kind=file; source_value="${2:-}"; shift 2 ;;
            --stdin) source_kind=stdin; shift ;;
            --text) source_kind=text; source_value="${2:-}"; shift 2 ;;
            -*) fail "unknown option for comment: $1" ;;
            *) [[ -z "$issue_id" ]] && issue_id="$1" || fail "unexpected argument: $1"; shift ;;
        esac
    done

    [[ -n "$issue_id" ]] || fail "comment needs an issue id, for example ARTC-1234"
    [[ -n "$source_kind" ]] || fail "comment needs --file PATH, --stdin, or --text TEXT"

    local payload_file body_file
    payload_file="$(read_payload_to_file "$source_kind" "$source_value")"
    body_file="$(mktemp)"
    chmod 600 "$body_file"
    jq -Rs '{text: .}' <"$payload_file" >"$body_file"

    api_request_from_file POST "/api/issues/${issue_id}/comments?fields=id" "$body_file" \
        | jq -r --arg issue "$issue_id" '"COMMENTED\t\($issue)\t\(.id)"'

    rm -f "$payload_file" "$body_file"
}

attach_file() {
    local issue_id=""
    local attachment_path=""

    while (($# > 0)); do
        case "$1" in
            --file) attachment_path="${2:-}"; shift 2 ;;
            -*) fail "unknown option for attach: $1" ;;
            *) [[ -z "$issue_id" ]] && issue_id="$1" || fail "unexpected argument: $1"; shift ;;
        esac
    done

    [[ -n "$issue_id" ]] || fail "attach needs an issue id, for example ARTC-1234"
    [[ -n "$attachment_path" ]] || fail "attach needs --file PATH"
    [[ -r "$attachment_path" ]] || fail "cannot read file: $attachment_path"

    prepare_auth_config

    curl \
        --fail-with-body \
        --silent \
        --show-error \
        --request POST \
        "${auth_config_args[@]}" \
        --header 'Accept: application/json' \
        --form "file=@${attachment_path}" \
        "${base_url}/api/issues/${issue_id}/attachments?fields=id,name,size" \
        | jq -r --arg issue "$issue_id" '(if type == "array" then .[0] else . end) | "ATTACHED\t\($issue)\t\(.name)\t\(.size) bytes\t\(.id)"'
}

raw_api() {
    local method=""
    local path=""
    local source_kind=""
    local source_value=""

    while (($# > 0)); do
        case "$1" in
            --data-file) source_kind=file; source_value="${2:-}"; shift 2 ;;
            --data-stdin) source_kind=stdin; shift ;;
            --data) source_kind=text; source_value="${2:-}"; shift 2 ;;
            -*) fail "unknown option for api: $1" ;;
            *)
                if [[ -z "$method" ]]; then method="$1"
                elif [[ -z "$path" ]]; then path="$1"
                else fail "unexpected argument: $1"
                fi
                shift
                ;;
        esac
    done

    [[ -n "$method" ]] || fail "api needs a method, for example GET or POST"
    [[ -n "$path" ]] || fail "api needs a path, for example /api/issues/ARTC-1234"
    [[ "$path" == /* ]] || fail "path must start with a slash: $path"

    if [[ -z "$source_kind" ]]; then
        api_request "$method" "$path"
        return
    fi

    local body_file
    body_file="$(read_payload_to_file "$source_kind" "$source_value")"
    jq -e . <"$body_file" >/dev/null 2>&1 || fail "body is not valid JSON"
    api_request_from_file "$method" "$path" "$body_file"
    rm -f "$body_file"
}

require_command curl
require_command jq

(($# > 0)) || {
    usage
    exit 1
}

command_name="$1"
shift
configure_api

case "$command_name" in
    issues) dispatch_issues "$@" ;;
    boards) print_boards "$@" ;;
    sprints) print_sprints "$@" ;;
    add) add_issues "$@" ;;
    comment) add_comment "$@" ;;
    attach) attach_file "$@" ;;
    api) raw_api "$@" ;;
    -h|--help|help) usage ;;
    *)
        usage >&2
        fail "unknown command: $command_name"
        ;;
esac
