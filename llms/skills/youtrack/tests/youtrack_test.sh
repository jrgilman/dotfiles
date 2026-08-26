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
    : >"$YOUTRACK_TEST_CURL_RESPONSE_FILE"
}
run_command() {
    command_status=0
    bash "$SCRIPT_PATH" "$@" >"${test_directory}/stdout" 2>"${test_directory}/stderr" || command_status=$?
    command_error="$(cat "${test_directory}/stderr")"
}
set_response() { printf '%s' "$1" >"$YOUTRACK_TEST_CURL_RESPONSE_FILE"; }
fail_assertion() { printf '%s\n' "$1" >&2; exit 1; }
assert_equals() { [[ "$1" == "$2" ]] || fail_assertion "Expected [$1] but got [$2]"; }
assert_contains() { [[ "$2" == *"$1"* ]] || fail_assertion "Expected [$2] to contain [$1]"; }
assert_file_bytes_equal() {
    printf '%s' "$1" >"${test_directory}/expected-bytes"; cmp -s "${test_directory}/expected-bytes" "$2" || fail_assertion 'The file bytes do not match'
}
assert_stdout_bytes_equal() { assert_file_bytes_equal "$1" "${test_directory}/stdout"; }
assert_failed() { [[ "$command_status" -ne 0 ]] || fail_assertion 'Expected the command to fail'; }
assert_issue_output() {
    local response="$1" expected="$2"; shift 2; set_response "$response"; run_command issues get "$@"
    assert_equals 0 "$command_status"; assert_stdout_bytes_equal "$expected"
}
assert_curl_was_not_called() { [[ ! -s "$YOUTRACK_TEST_CURL_CALLS" ]] || fail_assertion "Curl received these arguments: $(cat "$YOUTRACK_TEST_CURL_ARGUMENTS")"; }
assert_curl_used_safe_config() {
    local argument lowercase_argument authorization_secret="${YOUTRACK_AUTHORIZATION##* }"
    grep -Fxq -- '--config' "$YOUTRACK_TEST_CURL_ARGUMENTS" || fail_assertion 'Curl did not receive the config option'
    while IFS= read -r argument; do
        lowercase_argument="${argument,,}"
        if [[ ( -n "$YOUTRACK_AUTHORIZATION" && "$argument" == *"$YOUTRACK_AUTHORIZATION"* ) ||
            ( -n "$authorization_secret" && "$argument" == *"$authorization_secret"* ) ||
            "$lowercase_argument" == *authorization:* || "$lowercase_argument" == *"authorization argument"* ]]; then
            fail_assertion 'Curl received an authorization argument'
        fi
    done <"$YOUTRACK_TEST_CURL_ARGUMENTS"
}
assert_cli_failure_without_curl() {
    local expected_error="$1"; shift; run_command "$@"
    assert_failed; assert_stdout_bytes_equal ''; assert_contains "$expected_error" "$command_error"; assert_curl_was_not_called
}
assert_response_failure() {
    local response="$1" expected_error="$2"; shift 2; set_response "$response"; run_command issues get ARTC-42 "$@"
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
printf '%s tests failed\n' "$tests_failed"
[[ "$tests_failed" -eq 0 ]]
