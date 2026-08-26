#!/usr/bin/env bash

set -uo pipefail
readonly TEST_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_PATH="${TEST_DIRECTORY}/../scripts/youtrack.sh"
readonly FAKE_DIRECTORY="${TEST_DIRECTORY}/fakes"
readonly ORIGINAL_PATH="$PATH"
test_directory=''
command_status=0
command_error=''
set_up() {
    test_directory="$(mktemp -d)"
    chmod +x "${FAKE_DIRECTORY}/curl"; export PATH="${FAKE_DIRECTORY}:${ORIGINAL_PATH}"
    export YOUTRACK_BASE_URL='https://youtrack.example.test' YOUTRACK_AUTHORIZATION='Bearer test-token'
    export YOUTRACK_TEST_CURL_ARGUMENTS="${test_directory}/curl-arguments" YOUTRACK_TEST_CURL_CALLS="${test_directory}/curl-calls"
    export YOUTRACK_TEST_CURL_RESPONSE_FILE="${test_directory}/curl-response" YOUTRACK_TEST_CURL_EXIT_STATUS=0
    unset YOUTRACK_TEST_CURL_RESPONSES_DIRECTORY
    : >"$YOUTRACK_TEST_CURL_RESPONSE_FILE"
}
run_command() {
    command_status=0
    bash "$SCRIPT_PATH" "$@" >"${test_directory}/stdout" 2>"${test_directory}/stderr" || command_status=$?
    command_error="$(cat "${test_directory}/stderr")"
}
set_response() { printf '%s' "$1" >"$YOUTRACK_TEST_CURL_RESPONSE_FILE"; }
set_indexed_response() {
    local call_index="$1" response="$2" exit_status="${3:-0}"
    if [[ -z "${YOUTRACK_TEST_CURL_RESPONSES_DIRECTORY:-}" ]]; then
        export YOUTRACK_TEST_CURL_RESPONSES_DIRECTORY="${test_directory}/curl-responses"
        mkdir -p "$YOUTRACK_TEST_CURL_RESPONSES_DIRECTORY"
    fi
    printf '%s' "$response" >"${YOUTRACK_TEST_CURL_RESPONSES_DIRECTORY}/${call_index}.response"
    printf '%s\n' "$exit_status" >"${YOUTRACK_TEST_CURL_RESPONSES_DIRECTORY}/${call_index}.status"
}
reset_curl_recording() {
    rm -f "$YOUTRACK_TEST_CURL_CALLS" "$YOUTRACK_TEST_CURL_ARGUMENTS" "${YOUTRACK_TEST_CURL_ARGUMENTS}."*
}
curl_arguments_for_call() { cat "${YOUTRACK_TEST_CURL_ARGUMENTS}.$1"; }
install_color_forcing_jq() {
    local wrapper_directory="${test_directory}/color-jq"
    local real_jq
    real_jq="$(PATH="$ORIGINAL_PATH" command -v jq)"
    mkdir -p "$wrapper_directory"
    cat >"${wrapper_directory}/jq" <<EOF
#!/usr/bin/env bash
if ((\$# == 1)) && [[ "\$1" == '.' ]]; then
    exec ${real_jq@Q} -C "\$@"
fi
exec ${real_jq@Q} "\$@"
EOF
    chmod +x "${wrapper_directory}/jq"
    export PATH="${wrapper_directory}:${PATH}"
}
fail_assertion() { printf '%s\n' "$1" >&2; exit 1; }
assert_equals() { [[ "$1" == "$2" ]] || fail_assertion "Expected [$1] but got [$2]"; }
assert_contains() { [[ "$2" == *"$1"* ]] || fail_assertion "Expected [$2] to contain [$1]"; }
assert_file_bytes_equal() {
    printf '%s' "$1" >"${test_directory}/expected-bytes"; cmp -s "${test_directory}/expected-bytes" "$2" || fail_assertion 'The file bytes do not match'
}
assert_stdout_bytes_equal() { assert_file_bytes_equal "$1" "${test_directory}/stdout"; }
assert_failed() { [[ "$command_status" -ne 0 ]] || fail_assertion 'Expected the command to fail'; }
assert_curl_call_count() {
    local expected_count="$1" actual_count=0
    if [[ -f "$YOUTRACK_TEST_CURL_CALLS" ]]; then
        actual_count="$(wc -l <"$YOUTRACK_TEST_CURL_CALLS")"
    fi
    assert_equals "$expected_count" "$actual_count"
}
assert_issue_output() {
    local response="$1" expected="$2"; shift 2; set_response "$response"; run_command issues get "$@"
    assert_equals 0 "$command_status"; assert_stdout_bytes_equal "$expected"
}
assert_curl_was_not_called() { [[ ! -s "$YOUTRACK_TEST_CURL_CALLS" ]] || fail_assertion "Curl received these arguments: $(cat "$YOUTRACK_TEST_CURL_ARGUMENTS")"; }
assert_curl_used_safe_config() {
    local arguments_file="${1:-$YOUTRACK_TEST_CURL_ARGUMENTS}"
    local argument lowercase_argument authorization_secret="${YOUTRACK_AUTHORIZATION##* }"
    grep -Fxq -- '--config' "$arguments_file" || fail_assertion 'Curl did not receive the config option'
    while IFS= read -r argument; do
        lowercase_argument="${argument,,}"
        if [[ ( -n "$YOUTRACK_AUTHORIZATION" && "$argument" == *"$YOUTRACK_AUTHORIZATION"* ) ||
            ( -n "$authorization_secret" && "$argument" == *"$authorization_secret"* ) ||
            "$lowercase_argument" == *authorization:* || "$lowercase_argument" == *"authorization argument"* ]]; then
            fail_assertion 'Curl received an authorization argument'
        fi
    done <"$arguments_file"
}
assert_cli_failure_without_curl() {
    local expected_error="$1"; shift; run_command "$@"
    assert_failed; assert_stdout_bytes_equal ''; assert_contains "$expected_error" "$command_error"; assert_curl_was_not_called
}
assert_response_failure() {
    local response="$1" expected_error="$2"; shift 2; set_response "$response"; run_command issues get ARTC-42 "$@"
    assert_failed; assert_stdout_bytes_equal ''; assert_contains "$expected_error" "$command_error"
}
assert_comments_response_failure() {
    local response="$1" expected_error="$2"
    set_indexed_response 1 "$response"
    reset_curl_recording
    run_command issues comments list ARTC-42
    assert_failed; assert_stdout_bytes_equal ''; assert_contains "$expected_error" "$command_error"
}
text_output_preserves_descriptions_and_leaves_absent_fields_empty() {
    assert_issue_output '{"id":"2-42","idReadable":"ARTC-42","summary":"Read issue","description":"First line\n\n* item","customFields":[{"name":"State","value":{"name":"Open"}},{"name":"Type","value":{"name":"Bug"}},{"name":"Priority","value":{"name":"Major"}}]}' $'ARTC-42\tOpen\tBug\tMajor\tRead issue\n\nFirst line\n\n* item' ARTC-42
    assert_issue_output '{"idReadable":"ARTC-43","summary":"No fields","description":"","customFields":null}' $'ARTC-43\t\t\t\tNo fields\n' ARTC-43
}
json_output_is_exact_in_both_option_orders() {
    local response='{"id":"2-42","idReadable":"ARTC-42","summary":"Read issue","description":null,"tags":[{"id":"6-1","name":"read"}]}'
    local expected=$'{\n  "id": "2-42",\n  "idReadable": "ARTC-42",\n  "summary": "Read issue",\n  "description": null,\n  "tags": [\n    {\n      "id": "6-1",\n      "name": "read"\n    }\n  ]\n}\n'
    assert_issue_output "$response" "$expected" --json ARTC-42
    assert_issue_output "$response" "$expected" ARTC-42 --json
}
an_issue_request_uses_one_configured_get_with_the_projection_and_an_encoded_path() {
    local projection='id,idReadable,summary,description,created,updated,resolved,reporter(id,login,fullName),project(id,name,shortName),tags(id,name),customFields(id,name,%24type,value(id,name,login,fullName,text,minutes,presentation))'
    set_response '{"idReadable":"ARTC-42","summary":"Read issue"}'; run_command issues get 'ARTC/42 ?'
    assert_equals 0 "$command_status"; assert_file_bytes_equal $'call\n' "$YOUTRACK_TEST_CURL_CALLS"
    local arguments; arguments="$(cat "$YOUTRACK_TEST_CURL_ARGUMENTS")"
    assert_contains $'--request\nGET' "$arguments"
    assert_contains "https://youtrack.example.test/api/issues/ARTC%2F42%20%3F?fields=${projection}" "$arguments"
    assert_curl_used_safe_config
}
the_fake_curl_rejects_authorization_arguments_without_recording_their_values() {
    local fake_status=0 authorization_secret="${YOUTRACK_AUTHORIZATION##* }"
    "${FAKE_DIRECTORY}/curl" "value=${YOUTRACK_AUTHORIZATION}" "secret=${authorization_secret}" \
        'prefix Authorization: separate-value' >"${test_directory}/fake-stdout" 2>"${test_directory}/fake-stderr" || fake_status=$?
    [[ "$fake_status" -ne 0 ]] || fail_assertion 'Expected fake curl to fail'
    assert_file_bytes_equal $'[AUTHORIZATION ARGUMENT LEAK]\n[AUTHORIZATION ARGUMENT LEAK]\n[AUTHORIZATION ARGUMENT LEAK]\n' "$YOUTRACK_TEST_CURL_ARGUMENTS"
}
invalid_issue_arguments_and_operations_fail_before_curl_runs() {
    assert_cli_failure_without_curl 'issues get needs one issue ID' issues get
    assert_cli_failure_without_curl 'issues get needs one issue ID' issues get ''
    assert_cli_failure_without_curl 'issues get needs one issue ID' issues get $' \t\n'
    assert_cli_failure_without_curl 'issues get accepts one issue ID' issues get ARTC-42 ARTC-43
    assert_cli_failure_without_curl 'issues get accepts --json once' issues get --json --json ARTC-42
    assert_cli_failure_without_curl 'unknown issues get option: --other' issues get ARTC-42 --other
    assert_cli_failure_without_curl 'issues needs an operation' issues
    assert_cli_failure_without_curl 'unknown issues operation: list' issues list ARTC-42
}
malformed_basic_issue_responses_fail_without_output() {
    local numeric_value=42
    local -a cases=(
        '{"idReadable":' 'issue response is not valid JSON'
        'null' 'issue response must be an object'
        '{"idReadable":"ARTC-42"}' 'issue response needs string idReadable and summary fields'
        "{\"idReadable\":${numeric_value},\"summary\":\"Read issue\"}" 'issue response needs string idReadable and summary fields'
        "{\"idReadable\":\"ARTC-42\",\"summary\":\"Read issue\",\"description\":${numeric_value}}" 'the description in the issue response must be a string or null'
        '{"idReadable":"ARTC-42","summary":"Read issue","customFields":{}}' 'the customFields value in the issue response must be an array or null'
        '{"idReadable":"ARTC-42","summary":"Read issue","customFields":[{},null]}' 'each customFields entry in the issue response must be an object'
    )
    local index
    for ((index = 0; index < ${#cases[@]}; index += 2)); do
        assert_response_failure "${cases[index]}" "${cases[index + 1]}"
    done
}
malformed_projected_issue_fields_fail_without_output_in_text_and_json_modes() {
    local numeric_member=42 field_name fragment
    local -a json_fragments=(
        "\"id\":${numeric_member}" '"tags":{}' '"reporter":"someone"' '"project":null' '"created":null' '"updated":[]' '"resolved":false'
        "\"reporter\":{\"id\":${numeric_member}}" "\"reporter\":{\"login\":${numeric_member}}" "\"reporter\":{\"fullName\":${numeric_member}}"
        "\"project\":{\"id\":${numeric_member}}" "\"project\":{\"name\":${numeric_member}}" "\"project\":{\"shortName\":${numeric_member}}"
    )
    local -a text_fragments=(
        '"tags":[null]' '"tags":[{"name":"read"}]' '"tags":[{"id":"6-1"}]'
        "\"tags\":[{\"id\":${numeric_member},\"name\":\"read\"}]" "\"tags\":[{\"id\":\"6-1\",\"name\":${numeric_member}}]"
        '"customFields":[{}]' "\"customFields\":[{\"name\":${numeric_member}}]" "\"customFields\":[{\"name\":\"Assignee\",\"id\":${numeric_member}}]" "\"customFields\":[{\"name\":\"Assignee\",\"\$type\":${numeric_member}}]"
    )
    for field_name in State Type Priority; do
        text_fragments+=(
            "\"customFields\":[{\"name\":\"${field_name}\",\"value\":{\"name\":${numeric_member}}}]"
            "\"customFields\":[{\"name\":\"${field_name}\",\"value\":\"invalid\"}]"
        )
    done
    for fragment in "${json_fragments[@]}"; do
        assert_response_failure "{\"idReadable\":\"ARTC-42\",\"summary\":\"Read issue\",${fragment}}" 'issue response has malformed projected fields' --json
    done
    for fragment in "${text_fragments[@]}"; do
        assert_response_failure "{\"idReadable\":\"ARTC-42\",\"summary\":\"Read issue\",${fragment}}" 'issue response has malformed projected fields'
    done
}
valid_nulls_metadata_timestamps_and_polymorphic_custom_fields_produce_output() {
    local created_timestamp=1700000000000 updated_timestamp=1700000001000 resolved_timestamp=1700000002000
    assert_issue_output "{\"id\":\"2-44\",\"idReadable\":\"ARTC-44\",\"summary\":\"Valid fields\",\"created\":${created_timestamp},\"updated\":${updated_timestamp},\"resolved\":null,\"reporter\":null,\"project\":{\"id\":\"0-0\",\"name\":\"Artemis\",\"shortName\":\"ARTC\"},\"tags\":[],\"customFields\":[{\"id\":\"94-1\",\"name\":\"State\",\"\$type\":\"StateIssueCustomField\",\"value\":null},{\"name\":\"Assignee\",\"value\":[{\"login\":\"reader\"}]}]}" $'ARTC-44\t\t\t\tValid fields\n' ARTC-44
    assert_issue_output "{\"idReadable\":\"ARTC-45\",\"summary\":\"Resolved issue\",\"resolved\":${resolved_timestamp},\"reporter\":{\"login\":\"reader\"},\"project\":{}}" $'ARTC-45\t\t\t\tResolved issue\n' ARTC-45
}
a_curl_failure_does_not_print_its_response() {
    set_response '{"idReadable":"ARTC-42","summary":"Read issue"}'; export YOUTRACK_TEST_CURL_EXIT_STATUS=22; run_command issues get ARTC-42
    assert_failed; assert_stdout_bytes_equal ''; assert_file_bytes_equal $'call\n' "$YOUTRACK_TEST_CURL_CALLS"
}
an_existing_flat_api_command_still_dispatches() {
    set_response '{"login":"reader"}'; run_command api GET /api/users/me
    assert_equals 0 "$command_status"; assert_stdout_bytes_equal '{"login":"reader"}'
    assert_contains 'https://youtrack.example.test/api/users/me' "$(cat "$YOUTRACK_TEST_CURL_ARGUMENTS")"
}
empty_comment_results_have_exact_text_and_json_outputs() {
    set_indexed_response 1 '[]'
    run_command issues comments list ARTC-42
    assert_equals 0 "$command_status"; assert_stdout_bytes_equal ''; assert_curl_call_count 1

    reset_curl_recording
    run_command issues comments list ARTC-42 --json
    assert_equals 0 "$command_status"; assert_stdout_bytes_equal $'[]\n'; assert_curl_call_count 1
}
one_page_comment_text_output_has_exact_headers_text_and_separators() {
    set_indexed_response 1 '[{"id":"4-1","text":"First comment","created":1700000000000,"updated":1700000001000,"deleted":false,"author":{"id":"1-1","login":"alice","fullName":"Alice Example"}},{"id":"4-2","text":"Second comment","created":1700000002000,"updated":1700000003000,"deleted":true,"author":{"id":"1-2","login":"bob","fullName":"Bob Example"}}]'
    set_indexed_response 2 '[]'
    run_command issues comments list ARTC-42
    local expected=$'4-1\talice\tAlice Example\t1700000000000\t1700000001000\tfalse\n\nFirst comment\n\n4-2\tbob\tBob Example\t1700000002000\t1700000003000\ttrue\n\nSecond comment'
    assert_equals 0 "$command_status"; assert_stdout_bytes_equal "$expected"; assert_curl_call_count 2
}
one_page_comment_json_output_is_exact_and_keeps_objects_unchanged() {
    set_indexed_response 1 '[{"id":"4-1","text":"Hello","created":1700000000000,"updated":null,"deleted":false,"author":{"id":"1-1","login":"alice","fullName":"Alice Example"}}]'
    set_indexed_response 2 '[]'
    run_command issues comments list --json ARTC-42
    local expected=$'[\n  {\n    "id": "4-1",\n    "text": "Hello",\n    "created": 1700000000000,\n    "updated": null,\n    "deleted": false,\n    "author": {\n      "id": "1-1",\n      "login": "alice",\n      "fullName": "Alice Example"\n    }\n  }\n]\n'
    assert_equals 0 "$command_status"; assert_stdout_bytes_equal "$expected"; assert_curl_call_count 2
}
comment_json_output_explicitly_disables_jq_colors() {
    set_indexed_response 1 '[]'
    install_color_forcing_jq
    run_command issues comments list ARTC-42 --json
    assert_equals 0 "$command_status"; assert_stdout_bytes_equal $'[]\n'
}
comment_json_option_is_valid_before_or_after_the_issue_id() {
    set_indexed_response 1 '[]'
    run_command issues comments list --json ARTC-42
    assert_equals 0 "$command_status"; assert_stdout_bytes_equal $'[]\n'

    reset_curl_recording
    run_command issues comments list ARTC-42 --json
    assert_equals 0 "$command_status"; assert_stdout_bytes_equal $'[]\n'
}
null_comment_fields_render_as_documented_empty_values() {
    set_indexed_response 1 '[{"id":"4-null","text":null,"created":0,"updated":null,"deleted":true,"author":null}]'
    set_indexed_response 2 '[]'
    run_command issues comments list ARTC-42
    assert_equals 0 "$command_status"
    assert_stdout_bytes_equal $'4-null\t\t\t0\t\ttrue\n\n'
}
multiline_comment_text_is_not_normalized_or_given_a_trailing_newline() {
    set_indexed_response 1 '[{"id":"4-multiline","text":"First line\n\n\tindented\nlast line","created":1,"updated":2,"deleted":false,"author":{"id":"1-1","login":"alice","fullName":"Alice Example"}}]'
    set_indexed_response 2 '[]'
    run_command issues comments list ARTC-42
    local expected=$'4-multiline\talice\tAlice Example\t1\t2\tfalse\n\nFirst line\n\n\tindented\nlast line'
    assert_equals 0 "$command_status"; assert_stdout_bytes_equal "$expected"
}
comment_pagination_uses_returned_counts_and_continues_after_short_pages() {
    set_indexed_response 1 '[{"id":"4-1","text":"one","created":1,"updated":null,"deleted":false,"author":null},{"id":"4-2","text":"two","created":2,"updated":null,"deleted":false,"author":null}]'
    set_indexed_response 2 '[{"id":"4-3","text":"three","created":3,"updated":null,"deleted":false,"author":null}]'
    set_indexed_response 3 '[]'
    run_command issues comments list ARTC-42 --json
    assert_equals 0 "$command_status"; assert_curl_call_count 3
    assert_equals '4-1,4-2,4-3' "$(jq -r 'map(.id) | join(",")' "${test_directory}/stdout")"
    assert_contains '%24top=100&%24skip=0' "$(curl_arguments_for_call 1)"
    assert_contains '%24top=100&%24skip=2' "$(curl_arguments_for_call 2)"
    assert_contains '%24top=100&%24skip=3' "$(curl_arguments_for_call 3)"
    local call_index
    for call_index in 1 2 3; do
        assert_curl_used_safe_config "${YOUTRACK_TEST_CURL_ARGUMENTS}.${call_index}"
    done
}
duplicate_comments_remain_in_api_order() {
    set_indexed_response 1 '[{"id":"4-1","text":"first","created":1,"updated":null,"deleted":false,"author":null},{"id":"4-2","text":"second","created":2,"updated":null,"deleted":false,"author":null}]'
    set_indexed_response 2 '[{"id":"4-1","text":"first again","created":1,"updated":null,"deleted":false,"author":null}]'
    set_indexed_response 3 '[]'
    run_command issues comments list ARTC-42 --json
    assert_equals 0 "$command_status"
    assert_equals '4-1,4-2,4-1' "$(jq -r 'map(.id) | join(",")' "${test_directory}/stdout")"
}
a_comment_request_encodes_the_issue_id_and_sends_the_complete_projection() {
    local projection='id,text,created,updated,deleted,author(id,login,fullName)'
    set_indexed_response 1 '[]'
    run_command issues comments list 'ARTC/42 ?'
    assert_equals 0 "$command_status"; assert_curl_call_count 1
    local arguments; arguments="$(curl_arguments_for_call 1)"
    assert_contains $'--request\nGET' "$arguments"
    assert_contains "https://youtrack.example.test/api/issues/ARTC%2F42%20%3F/comments?fields=${projection}&%24top=100&%24skip=0" "$arguments"
    assert_curl_used_safe_config "${YOUTRACK_TEST_CURL_ARGUMENTS}.1"
}
invalid_comment_arguments_and_operations_fail_before_curl_runs() {
    assert_cli_failure_without_curl 'issues comments list needs one issue ID' issues comments list
    assert_cli_failure_without_curl 'issues comments list needs one issue ID' issues comments list ''
    assert_cli_failure_without_curl 'issues comments list needs one issue ID' issues comments list $' \t\n'
    assert_cli_failure_without_curl 'issues comments list accepts one issue ID' issues comments list ARTC-42 ARTC-43
    assert_cli_failure_without_curl 'issues comments list accepts --json once' issues comments list --json ARTC-42 --json
    assert_cli_failure_without_curl 'unknown issues comments list option: --other' issues comments list ARTC-42 --other
    assert_cli_failure_without_curl 'issues comments needs an operation' issues comments
    assert_cli_failure_without_curl 'issues comments needs an operation' issues comments ''
    assert_cli_failure_without_curl 'unknown issues comments operation: get' issues comments get ARTC-42
}
invalid_and_non_array_comment_pages_fail_without_output() {
    assert_comments_response_failure '{"id":' 'comment page is not valid JSON'
    assert_comments_response_failure '[] []' 'comment page is not valid JSON'
    assert_comments_response_failure '[{"id":"4-1","text":"text","created":01,"updated":null,"deleted":false,"author":null}]' 'comment page is not valid JSON'
    assert_comments_response_failure '[{"id":"4-1","text":"text","created":Infinity,"updated":null,"deleted":false,"author":null}]' 'comment page is not valid JSON'
    assert_comments_response_failure '[{"id":"4-1","text":"text","created":+1,"updated":null,"deleted":false,"author":null}]' 'comment page is not valid JSON'
    assert_comments_response_failure 'null' 'comment page must be an array'
    assert_comments_response_failure '{}' 'comment page must be an array'
    assert_comments_response_failure '"comments"' 'comment page must be an array'
}
a_comment_page_with_a_nul_byte_fails_as_invalid_json() {
    set_indexed_response 1 ''
    printf '[\0]' >"${YOUTRACK_TEST_CURL_RESPONSES_DIRECTORY}/1.response"
    reset_curl_recording
    run_command issues comments list ARTC-42
    assert_failed; assert_stdout_bytes_equal ''; assert_contains 'comment page is not valid JSON' "$command_error"
}
missing_and_malformed_projected_comment_fields_fail_without_output() {
    local valid_comment='{"id":"4-1","text":"text","created":1,"updated":2,"deleted":false,"author":{"id":"1-1","login":"alice","fullName":"Alice Example"}}'
    local field response index
    local -a fields=(id text created updated deleted author)
    for field in "${fields[@]}"; do
        response="$(jq -cn --argjson comment "$valid_comment" --arg field "$field" '[$comment | del(.[$field])]')"
        assert_comments_response_failure "$response" 'comment page has malformed projected fields'
    done

    local -a invalid_values=('null' 'false' '"now"' '[]' '0' '"reader"')
    for ((index = 0; index < ${#fields[@]}; index++)); do
        response="$(jq -cn --argjson comment "$valid_comment" --arg field "${fields[index]}" --argjson value "${invalid_values[index]}" '[$comment | .[$field] = $value]')"
        assert_comments_response_failure "$response" 'comment page has malformed projected fields'
    done

    local -a author_fields=(id login fullName)
    local -a author_invalid_values=('null' '0' 'false')
    for ((index = 0; index < ${#author_fields[@]}; index++)); do
        field="${author_fields[index]}"
        response="$(jq -cn --argjson comment "$valid_comment" --arg field "$field" '[$comment | .author |= del(.[$field])]')"
        assert_comments_response_failure "$response" 'comment page has malformed projected fields'
        response="$(jq -cn --argjson comment "$valid_comment" --arg field "$field" --argjson value "${author_invalid_values[index]}" '[$comment | .author[$field] = $value]')"
        assert_comments_response_failure "$response" 'comment page has malformed projected fields'
    done
    assert_comments_response_failure '[null]' 'comment page has malformed projected fields'
}
a_malformed_later_comment_page_prints_no_partial_output() {
    set_indexed_response 1 '[{"id":"4-1","text":"earlier","created":1,"updated":null,"deleted":false,"author":null}]'
    set_indexed_response 2 '{"not":"an array"}'
    run_command issues comments list ARTC-42
    assert_failed; assert_stdout_bytes_equal ''; assert_contains 'comment page must be an array' "$command_error"; assert_curl_call_count 2
}
a_later_comment_curl_failure_prints_no_partial_output() {
    set_indexed_response 1 '[{"id":"4-1","text":"earlier","created":1,"updated":null,"deleted":false,"author":null}]'
    set_indexed_response 2 '{"error":"later failure"}' 22
    run_command issues comments list ARTC-42
    assert_failed; assert_stdout_bytes_equal ''; assert_curl_call_count 2
}
an_empty_comment_page_stops_before_an_unconfigured_extra_request() {
    set_indexed_response 1 '[{"id":"4-1","text":"only","created":1,"updated":null,"deleted":false,"author":null}]'
    set_indexed_response 2 '[]'
    run_command issues comments list ARTC-42
    assert_equals 0 "$command_status"; assert_curl_call_count 2
}
an_existing_flat_comment_command_still_dispatches() {
    set_response '{"id":"4-9"}'
    run_command comment ARTC-42 --text 'existing behavior'
    assert_equals 0 "$command_status"; assert_stdout_bytes_equal $'COMMENTED\tARTC-42\t4-9\n'
    assert_contains 'https://youtrack.example.test/api/issues/ARTC-42/comments?fields=id' "$(cat "$YOUTRACK_TEST_CURL_ARGUMENTS")"
    assert_curl_used_safe_config
}
run_test() {
    local name="$1" function_name="$2"
    if (set_up; trap 'rm -rf "$test_directory"' EXIT; "$function_name"); then
        printf 'ok - %s\n' "$name"
    else
        printf 'not ok - %s\n' "$name"; tests_failed=$((tests_failed + 1))
    fi
}
tests_failed=0
run_test 'Text output shows issue fields, preserves descriptions, and leaves absent fields empty' text_output_preserves_descriptions_and_leaves_absent_fields_empty
run_test 'JSON output is exact in both option orders' json_output_is_exact_in_both_option_orders
run_test 'An issue request sends one encoded projected GET through curl config' an_issue_request_uses_one_configured_get_with_the_projection_and_an_encoded_path
run_test 'The fake curl rejects authorization arguments without recording their values' the_fake_curl_rejects_authorization_arguments_without_recording_their_values
run_test 'Invalid issue arguments and operations fail before curl runs' invalid_issue_arguments_and_operations_fail_before_curl_runs
run_test 'Invalid JSON and issue response shapes fail without output' malformed_basic_issue_responses_fail_without_output
run_test 'Malformed projected issue fields fail without output in text and JSON modes' malformed_projected_issue_fields_fail_without_output_in_text_and_json_modes
run_test 'Valid nulls, metadata, timestamps, and polymorphic custom fields produce output' valid_nulls_metadata_timestamps_and_polymorphic_custom_fields_produce_output
run_test 'A curl failure does not print its response' a_curl_failure_does_not_print_its_response
run_test 'An existing flat API command still dispatches' an_existing_flat_api_command_still_dispatches
run_test 'Empty comment results have exact text and JSON outputs' empty_comment_results_have_exact_text_and_json_outputs
run_test 'One-page comment text output has exact headers, text, and separators' one_page_comment_text_output_has_exact_headers_text_and_separators
run_test 'One-page comment JSON output is exact and keeps objects unchanged' one_page_comment_json_output_is_exact_and_keeps_objects_unchanged
run_test 'Comment JSON output explicitly disables jq colors' comment_json_output_explicitly_disables_jq_colors
run_test 'The comment JSON option works before or after the issue ID' comment_json_option_is_valid_before_or_after_the_issue_id
run_test 'Null comment fields render as documented empty values' null_comment_fields_render_as_documented_empty_values
run_test 'Multiline comment text is unchanged and receives no trailing newline' multiline_comment_text_is_not_normalized_or_given_a_trailing_newline
run_test 'Comment pagination uses returned counts and continues after short pages' comment_pagination_uses_returned_counts_and_continues_after_short_pages
run_test 'Duplicate comments remain in API order' duplicate_comments_remain_in_api_order
run_test 'A comment request encodes the issue ID and sends the complete projection' a_comment_request_encodes_the_issue_id_and_sends_the_complete_projection
run_test 'Invalid comment arguments and operations fail before curl runs' invalid_comment_arguments_and_operations_fail_before_curl_runs
run_test 'Invalid and non-array comment pages fail without output' invalid_and_non_array_comment_pages_fail_without_output
run_test 'A comment page containing a NUL byte fails as invalid JSON' a_comment_page_with_a_nul_byte_fails_as_invalid_json
run_test 'Missing and malformed projected comment fields fail without output' missing_and_malformed_projected_comment_fields_fail_without_output
run_test 'A malformed later comment page prints no partial output' a_malformed_later_comment_page_prints_no_partial_output
run_test 'A later comment curl failure prints no partial output' a_later_comment_curl_failure_prints_no_partial_output
run_test 'An empty comment page stops before an unconfigured extra request' an_empty_comment_page_stops_before_an_unconfigured_extra_request
run_test 'An existing flat comment command still dispatches' an_existing_flat_comment_command_still_dispatches
printf '%s tests failed\n' "$tests_failed"
[[ "$tests_failed" -eq 0 ]]
