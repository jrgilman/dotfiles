# Plan for issue read commands

## Goal

Add two native read commands:

```bash
youtrack.sh issues get ISSUE_ID [--json]
youtrack.sh issues comments list ISSUE_ID [--json]
```

The commands will follow the resource-first structure in `../command-structure.md`.
This work will not change existing flat commands.

## Command behavior

### `issues get`

Request one issue by its readable identifier.
Reject a missing identifier, extra identifiers, and unknown options.
Encode the identifier before adding it to the request path.

Request these issue details:

- Identifier and summary
- Description
- Project
- State, type, priority, and assignee
- Reporter
- Tags
- Created and updated times
- Resolution status

Default output will show a concise issue view.
The `--json` option will print the complete projected issue object.

### `issues comments list`

Request all comments for one issue.
Reject a missing identifier, extra identifiers, and unknown options.

Request comments in pages of 100.
Advance the offset by the returned item count.
Continue until YouTrack returns an empty page.
Preserve the API result order.

Buffer all pages before printing output.
If any page fails, return a nonzero status and print no partial comment list.

Default output will show each comment header and its unchanged text.
The `--json` option will print one array with all comments.
An empty result will print `[]` in JSON mode.

## Test-first steps

1. Add a dependency-free shell test runner under `tests/`.
2. Add a fake `curl` command that records requests and returns fixture responses.
3. Write failing tests for both command structures and output modes.
4. Write failing tests for missing identifiers, extra arguments, and unknown options.
5. Write failing tests for issue identifier encoding.
6. Write failing tests for empty and multi-page comment results.
7. Write failing tests for malformed responses and later-page failures.
8. Add the nested `issues` command dispatcher.
9. Add a shared parser for one issue identifier and optional `--json`.
10. Implement the issue request and both output modes.
11. Implement comment pagination and both output modes.
12. Update `SKILL.md` and the script usage text.
13. Run the complete shell test file.

## Files

- `scripts/youtrack.sh`
- `tests/youtrack_test.sh`
- `tests/fakes/curl`
- `SKILL.md`

## Acceptance criteria

- `issues get` returns the requested issue in text and JSON modes.
- `issues comments list` returns every comment in text and JSON modes.
- Comment pagination does not omit or duplicate results.
- A later-page failure does not print a partial comment list.
- Invalid input fails before an API request.
- Malformed JSON and unexpected response shapes fail clearly.
- Existing commands continue to work without aliases or parser changes.
- The usage text and skill documentation describe both new commands.
