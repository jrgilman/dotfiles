import assert from "node:assert/strict";
import test from "node:test";

import {
  CLAUDE_MEMORY_MAX_BYTES,
  chooseRepositoryIdentity,
  encodeClaudeProjectKey,
  formatClaudeMemorySection,
  limitClaudeMemory,
  registerClaudeMemoryExtension,
} from "./index.ts";

test("a regular checkout uses its worktree root", () => {
  assert.equal(
    chooseRepositoryIdentity("/workspace/project/src", {
      topLevel: "/workspace/project",
      gitDir: "/workspace/project/.git",
      commonDir: "/workspace/project/.git",
      isBare: false,
    }),
    "/workspace/project",
  );
});

test("a worktree backed by a bare repository uses the common Git directory", () => {
  assert.equal(
    chooseRepositoryIdentity("/workspace/project.git/feature", {
      topLevel: "/workspace/project.git/feature",
      gitDir: "/workspace/project.git/worktrees/feature",
      commonDir: "/workspace/project.git",
      isBare: false,
    }),
    "/workspace/project.git",
  );
});

test("a worktree backed by a regular checkout uses the main worktree root", () => {
  assert.equal(
    chooseRepositoryIdentity("/workspace/project-feature", {
      topLevel: "/workspace/project-feature",
      gitDir: "/workspace/project/.git/worktrees/project-feature",
      commonDir: "/workspace/project/.git",
      isBare: false,
    }),
    "/workspace/project",
  );
});

test("a bare repository uses its common Git directory", () => {
  assert.equal(
    chooseRepositoryIdentity("/workspace/project.git", {
      topLevel: null,
      gitDir: "/workspace/project.git",
      commonDir: "/workspace/project.git",
      isBare: true,
    }),
    "/workspace/project.git",
  );
});

test("a directory outside Git uses the current directory", () => {
  assert.equal(chooseRepositoryIdentity("/workspace/notes", null), "/workspace/notes");
});

test("the Claude project key replaces each non-alphanumeric character", () => {
  assert.equal(
    encodeClaudeProjectKey("/home/jacob/Documents/artemis/cloud.git"),
    "-home-jacob-Documents-artemis-cloud-git",
  );
});

test("a long Claude project key uses Claude's stable hash suffix", () => {
  const projectPath = `/${"a".repeat(210)}!`;

  assert.equal(
    encodeClaudeProjectKey(projectPath),
    `${`-${"a".repeat(199)}`}-6kszg2`,
  );
});

test("Claude memory stops after the first 200 lines", () => {
  const source = Array.from({ length: 201 }, (_, index) => `line ${index + 1}`).join("\n");
  const memory = limitClaudeMemory(Buffer.from(source), Buffer.byteLength(source));

  assert.equal(memory.lineCount, 200);
  assert.equal(memory.content.includes("line 200"), true);
  assert.equal(memory.content.includes("line 201"), false);
  assert.equal(memory.truncated, true);
});

test("Claude memory stops at 25 KiB", () => {
  const source = Buffer.alloc(CLAUDE_MEMORY_MAX_BYTES + 10, "a");
  const memory = limitClaudeMemory(source.subarray(0, CLAUDE_MEMORY_MAX_BYTES), source.length);

  assert.equal(Buffer.byteLength(memory.content), CLAUDE_MEMORY_MAX_BYTES);
  assert.equal(memory.truncated, true);
});

test("the memory section identifies its source and read-only behavior", () => {
  const section = formatClaudeMemorySection({
    path: "/home/jacob/.claude/projects/example/memory/MEMORY.md",
    content: "# Memory Index\n\n- Prefer focused tests.",
    lineCount: 3,
    byteCount: 46,
    truncated: false,
  });

  assert.match(section, /Claude Code Auto Memory/);
  assert.match(section, /\/home\/jacob\/\.claude\/projects\/example\/memory\/MEMORY\.md/);
  assert.match(section, /read-only/i);
  assert.match(section, /Prefer focused tests/);
});

test("a truncated memory section directs the agent to search the full index", () => {
  const path = "/home/jacob/.claude/projects/example/memory/MEMORY.md";
  const section = formatClaudeMemorySection({
    path,
    content: "# Memory Index\n\n- Visible item",
    lineCount: 3,
    byteCount: 30,
    truncated: true,
  });

  const notice = "The injected MEMORY.md was truncated and does not show the full list of memory items.";

  assert.equal(section.includes(notice), true);
  assert.equal(section.includes(`Search the full file at ${JSON.stringify(path)}`), true);
  assert.equal(section.indexOf(notice) > section.indexOf("- Visible item"), true);
});

test("the extension adds fresh Claude memory before each agent run", async () => {
  const handlers = new Map();
  let content = "First memory";
  let reads = 0;

  registerClaudeMemoryExtension(
    {
      on(eventName, handler) {
        handlers.set(eventName, handler);
      },
      registerCommand() {},
    },
    {
      async resolveMemoryPath() {
        return "/memory/MEMORY.md";
      },
      async readMemory(path) {
        reads++;
        return {
          path,
          content,
          lineCount: 1,
          byteCount: Buffer.byteLength(content),
          truncated: false,
        };
      },
    },
  );

  await handlers.get("session_start")({}, { cwd: "/workspace/project" });

  const first = await handlers.get("before_agent_start")(
    { systemPrompt: "Base prompt" },
    { cwd: "/workspace/project" },
  );

  content = "Updated memory";

  const second = await handlers.get("before_agent_start")(
    { systemPrompt: "Base prompt" },
    { cwd: "/workspace/project" },
  );

  assert.match(first.systemPrompt, /First memory/);
  assert.match(second.systemPrompt, /Updated memory/);
  assert.equal(reads, 2);
});

test("the extension leaves the prompt unchanged when no memory exists", async () => {
  const handlers = new Map();

  registerClaudeMemoryExtension(
    {
      on(eventName, handler) {
        handlers.set(eventName, handler);
      },
      registerCommand() {},
    },
    {
      async resolveMemoryPath() {
        return "/memory/MEMORY.md";
      },
      async readMemory() {
        return null;
      },
    },
  );

  await handlers.get("session_start")({}, { cwd: "/workspace/project" });

  assert.equal(
    await handlers.get("before_agent_start")(
      { systemPrompt: "Base prompt" },
      { cwd: "/workspace/project" },
    ),
    undefined,
  );
});
