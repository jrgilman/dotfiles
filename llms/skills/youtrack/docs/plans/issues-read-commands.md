# Plan for issue comment reads

## Current state

The `issues get` command is complete on `master`.
Its parser, response checks, output modes, and authorization tests are the baseline for this work.

This slice adds one command:

```bash
youtrack.sh issues comments list ISSUE_ID [--json]
```

The command follows the resource-first structure in `../command-structure.md`.
Existing flat commands keep their current behavior.
The `comment` command still writes one comment.
This work does not add an alias.

## Command grammar

Add a `comments` subresource under `issues`.
Add a nested dispatcher for the `list` operation.

Accept one nonempty issue ID and one optional `--json` option.
Accept the option before or after the issue ID.
Reject these inputs before curl runs:

- A missing or blank issue ID
- More than one issue ID
- A repeated `--json` option
- An unknown option
- A missing comments operation
- An unknown comments operation

Encode the issue ID as one URI path segment.
Do not refactor the existing `issues get` parser in this slice.

## Request

Use this endpoint:

```text
GET /api/issues/ISSUE_ID/comments
```

Use this projection:

```text
id,text,created,updated,deleted,author(id,login,fullName)
```

Send these query parameters on every request:

```text
fields=PROJECTION&%24top=100&%24skip=OFFSET
```

The official API documents `$top`, `$skip`, and nullable comment fields:

<https://www.jetbrains.com/help/youtrack/devportal/resource-api-issues-issueID-comments.html>

## Response validation

Validate each complete page before adding it to the result.
Require exactly one JSON document whose top-level value is an array.
Reject invalid JSON, concatenated documents, and all other top-level values.

Require every projected key on each comment:

- `id` exists and is a string.
- `text` exists and is a string or null.
- `created` exists and is a number.
- `updated` exists and is a number or null.
- `deleted` exists and is a Boolean.
- `author` exists and is an object or null.
- A nonnull author has string `id`, `login`, and `fullName` fields.

A malformed page returns a nonzero status.
The command prints no result bytes after any response failure.

## Pagination

Start with an offset of zero and a page size of 100.
Add each validated page to one in-memory result array.
Advance the offset by the returned item count.
Continue after a short nonempty page.
Stop only after a valid empty page.
Preserve the API order without sorting or removing duplicates.

Do not print a page while pagination continues.
A later curl failure must not print comments from earlier pages.

## Output

### JSON mode

Print one pretty JSON array through `jq`.
Keep each projected comment object unchanged.
Print one trailing newline after the array.
An empty result prints these exact bytes:

```text
[]
```

### Text mode

Print no bytes for an empty result.
Print one header for each comment with these tab-separated columns:

```text
ID	AUTHOR_LOGIN	AUTHOR_FULL_NAME	CREATED	UPDATED	DELETED
```

Use empty author columns when `author` is null.
Use an empty `UPDATED` column when `updated` is null.
Print `true` or `false` in the `DELETED` column.

Print one blank line after each header.
Print the comment text without normalization or a forced trailing newline.
Treat null text as empty text.
Put two newline bytes between comment blocks.
Do not add a separator after the final comment.

## Test-first work

Extend the fake curl command before production code.
Keep its current single-response behavior for existing tests.
Add call-indexed responses and exit statuses for pagination tests.
Make indexed mode fail when a call has no configured response.
Configure a final empty page in every successful pagination test.
Record each request separately so tests can check each offset.
Keep authorization values out of every recorded argument.

Write failing tests for these cases:

1. Empty text and JSON results
2. Exact one-page text output
3. Exact one-page JSON output
4. Both valid `--json` positions
5. Null author, text, and updated values
6. Multiline comment text without normalization
7. Multiple nonempty pages followed by an empty page
8. Offsets based on returned item counts
9. A short nonempty page that does not stop pagination
10. Duplicate comments that stay in API order
11. An encoded issue ID and the complete projection
12. Missing identifiers, extra identifiers, repeated options, and unknown options
13. Missing and unknown comments operations
14. Invalid JSON, concatenated documents, and non-array pages
15. Missing projected keys and every malformed projected field
16. A malformed later page with no partial output
17. A later curl failure with no partial output
18. An unexpected extra page request that fails instead of looping
19. Safe authorization handling on every page
20. Existing `issues get` behavior
21. Existing flat `api` behavior
22. Existing flat `comment` behavior

Run targeted mutations against pagination, validation, and output separators.
Each mutation must make a relevant test fail.

## Implementation work

1. Add a comment projection constant.
2. Add the nested comments dispatcher.
3. Add argument parsing for `issues comments list`.
4. Add encoded paginated requests.
5. Add complete page validation.
6. Add buffered result assembly.
7. Add exact text and JSON renderers.
8. Update the script usage text.
9. Update the `SKILL.md` description and command-selection guidance.
10. Add the read command and examples to `SKILL.md`.
11. Run the complete shell test file.

## Files

- `scripts/youtrack.sh`
- `tests/youtrack_test.sh`
- `tests/fakes/curl`
- `SKILL.md`
- `docs/plans/issues-read-commands.md`

## Acceptance criteria

- `issues comments list` returns every accessible comment.
- Pagination does not omit, sort, or remove comments.
- Pagination stops only after an empty page.
- Every response page has the complete projected shape.
- A later failure does not print a partial list.
- Invalid input fails before an API request.
- Text and JSON output match their documented bytes.
- Existing commands keep their current behavior.
- Authorization values never enter curl arguments, logs, tests, or output.
