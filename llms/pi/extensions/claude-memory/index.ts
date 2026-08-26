import { execFile } from "node:child_process";
import { open, realpath } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, dirname, isAbsolute, join, resolve } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export const CLAUDE_MEMORY_MAX_LINES = 200;
export const CLAUDE_MEMORY_MAX_BYTES = 25 * 1024;

export interface GitLayout {
  topLevel: string | null;
  gitDir: string | null;
  commonDir: string | null;
  isBare: boolean;
}

export interface ClaudeMemoryDocument {
  path: string;
  content: string;
  lineCount: number;
  byteCount: number;
  truncated: boolean;
}

export interface ClaudeMemoryDependencies {
  resolveMemoryPath(cwd: string): Promise<string>;
  readMemory(path: string): Promise<ClaudeMemoryDocument | null>;
}

interface ClaudeMemoryPathOptions {
  claudeConfigDir?: string;
  projectDirectoryName?: string;
}

const GIT_ENVIRONMENT_KEYS = new Set([
  "GIT_ALTERNATE_OBJECT_DIRECTORIES",
  "GIT_CEILING_DIRECTORIES",
  "GIT_COMMON_DIR",
  "GIT_CONFIG_COUNT",
  "GIT_CONFIG_GLOBAL",
  "GIT_CONFIG_PARAMETERS",
  "GIT_CONFIG_SYSTEM",
  "GIT_DIR",
  "GIT_DISCOVERY_ACROSS_FILESYSTEM",
  "GIT_INDEX_FILE",
  "GIT_OBJECT_DIRECTORY",
  "GIT_SHALLOW_FILE",
  "GIT_WORK_TREE",
]);

function normalizedAbsolutePath(path: string): string {
  return resolve(path);
}

export function chooseRepositoryIdentity(cwd: string, layout: GitLayout | null): string {
  const fallback = normalizedAbsolutePath(cwd);

  if (layout === null) {
    return fallback;
  }

  const commonDir = layout.commonDir === null ? null : normalizedAbsolutePath(layout.commonDir);
  const gitDir = layout.gitDir === null ? null : normalizedAbsolutePath(layout.gitDir);

  if (layout.isBare) {
    return commonDir ?? gitDir ?? fallback;
  }

  if (layout.topLevel === null) {
    return fallback;
  }

  if (commonDir !== null && gitDir !== null) {
    const linkedWorktree = dirname(gitDir) === join(commonDir, "worktrees");

    if (linkedWorktree) {
      return basename(commonDir) === ".git" ? dirname(commonDir) : commonDir;
    }
  }

  return normalizedAbsolutePath(layout.topLevel);
}

function claudePathHash(value: string): string {
  let hash = 0;

  for (let index = 0; index < value.length; index++) {
    hash = ((hash << 5) - hash + value.charCodeAt(index)) | 0;
  }

  return Math.abs(hash).toString(36);
}

export function encodeClaudeProjectKey(projectIdentity: string): string {
  const encoded = projectIdentity.replace(/[^a-zA-Z0-9]/g, "-");

  if (encoded.length <= 200) {
    return encoded;
  }

  return `${encoded.slice(0, 200)}-${claudePathHash(projectIdentity)}`;
}

function gitEnvironment(): NodeJS.ProcessEnv {
  const environment = { ...process.env };

  for (const key of Object.keys(environment)) {
    if (
      GIT_ENVIRONMENT_KEYS.has(key.toUpperCase()) ||
      /^GIT_CONFIG_(?:KEY|VALUE)_\d+$/i.test(key)
    ) {
      delete environment[key];
    }
  }

  return environment;
}

function runGit(cwd: string, arguments_: string[]): Promise<string | null> {
  return new Promise((complete) => {
    execFile(
      "git",
      ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=", ...arguments_],
      {
        cwd,
        encoding: "utf8",
        env: gitEnvironment(),
        maxBuffer: 64 * 1024,
        timeout: 5000,
        windowsHide: true,
      },
      (error, stdout) => {
        if (error !== null) {
          complete(null);
          return;
        }

        const output = stdout.trim();
        complete(output.length === 0 ? null : output);
      },
    );
  });
}

async function canonicalPath(path: string): Promise<string> {
  try {
    return await realpath(path);
  } catch {
    return normalizedAbsolutePath(path);
  }
}

async function absoluteCommonGitDirectory(cwd: string): Promise<string | null> {
  const absolute = await runGit(cwd, [
    "rev-parse",
    "--path-format=absolute",
    "--git-common-dir",
  ]);

  if (absolute !== null) {
    return canonicalPath(absolute);
  }

  const common = await runGit(cwd, ["rev-parse", "--git-common-dir"]);

  if (common === null) {
    return null;
  }

  return canonicalPath(isAbsolute(common) ? common : resolve(cwd, common));
}

export async function inspectGitLayout(cwd: string): Promise<GitLayout | null> {
  const [topLevel, gitDir, commonDir, bare] = await Promise.all([
    runGit(cwd, ["rev-parse", "--show-toplevel"]),
    runGit(cwd, ["rev-parse", "--absolute-git-dir"]),
    absoluteCommonGitDirectory(cwd),
    runGit(cwd, ["rev-parse", "--is-bare-repository"]),
  ]);

  if (topLevel === null && gitDir === null && commonDir === null) {
    return null;
  }

  return {
    topLevel: topLevel === null ? null : await canonicalPath(topLevel),
    gitDir: gitDir === null ? null : await canonicalPath(gitDir),
    commonDir,
    isBare: bare === "true",
  };
}

function expandedPath(path: string): string {
  if (path === "~") {
    return homedir();
  }

  if (path.startsWith("~/")) {
    return join(homedir(), path.slice(2));
  }

  return normalizedAbsolutePath(path);
}

function validProjectDirectoryName(name: string | undefined): string | null {
  const candidate = name?.trim();

  if (
    candidate === undefined ||
    candidate.length === 0 ||
    candidate === "." ||
    candidate === ".." ||
    !/^[a-zA-Z0-9._-]+$/.test(candidate)
  ) {
    return null;
  }

  return candidate;
}

export async function resolveClaudeMemoryPath(
  cwd: string,
  options: ClaudeMemoryPathOptions = {},
): Promise<string> {
  const canonicalCwd = await canonicalPath(cwd);
  const layout = await inspectGitLayout(canonicalCwd);
  const identity = await canonicalPath(chooseRepositoryIdentity(canonicalCwd, layout));
  const configuredName = validProjectDirectoryName(
    options.projectDirectoryName ?? process.env.CLAUDE_CODE_PROJECT_DIR_NAME,
  );
  const projectKey = configuredName ?? encodeClaudeProjectKey(identity);
  const configDir = expandedPath(
    options.claudeConfigDir ?? process.env.CLAUDE_CONFIG_DIR ?? join(homedir(), ".claude"),
  );

  return join(configDir, "projects", projectKey, "memory", "MEMORY.md");
}

function decodeUtf8Prefix(buffer: Buffer): string {
  for (let trim = 0; trim <= Math.min(3, buffer.length); trim++) {
    try {
      return new TextDecoder("utf-8", { fatal: true }).decode(
        trim === 0 ? buffer : buffer.subarray(0, buffer.length - trim),
      );
    } catch {
      continue;
    }
  }

  return buffer.toString("utf8");
}

function countLines(content: string): number {
  if (content.length === 0) {
    return 0;
  }

  let newlines = 0;

  for (const character of content) {
    if (character === "\n") {
      newlines++;
    }
  }

  return content.endsWith("\n") ? newlines : newlines + 1;
}

export function limitClaudeMemory(prefix: Buffer, totalByteCount: number) {
  const byteLimited = prefix.subarray(0, CLAUDE_MEMORY_MAX_BYTES);
  const decoded = decodeUtf8Prefix(byteLimited);
  let content = decoded;
  let lineBreaks = 0;
  let lineTruncated = false;

  for (let index = 0; index < decoded.length; index++) {
    if (decoded[index] !== "\n") {
      continue;
    }

    lineBreaks++;

    if (lineBreaks === CLAUDE_MEMORY_MAX_LINES && index + 1 < decoded.length) {
      content = decoded.slice(0, index + 1);
      lineTruncated = true;
      break;
    }
  }

  return {
    content,
    lineCount: countLines(content),
    byteCount: Buffer.byteLength(content),
    truncated:
      lineTruncated ||
      totalByteCount > byteLimited.length ||
      prefix.length > CLAUDE_MEMORY_MAX_BYTES,
  };
}

export async function readClaudeMemory(path: string): Promise<ClaudeMemoryDocument | null> {
  let file;

  try {
    file = await open(path, "r");
    const metadata = await file.stat();

    if (!metadata.isFile()) {
      return null;
    }

    const length = Math.min(metadata.size, CLAUDE_MEMORY_MAX_BYTES);
    const buffer = Buffer.alloc(length);
    let offset = 0;

    while (offset < length) {
      const { bytesRead } = await file.read(buffer, offset, length - offset, offset);

      if (bytesRead === 0) {
        break;
      }

      offset += bytesRead;
    }

    return {
      path,
      ...limitClaudeMemory(buffer.subarray(0, offset), metadata.size),
    };
  } catch {
    return null;
  } finally {
    await file?.close().catch(() => undefined);
  }
}

export function formatClaudeMemorySection(document: ClaudeMemoryDocument): string {
  const memoryDirectory = dirname(document.path);
  const loadDescription = document.truncated
    ? `Only the Claude startup prefix was loaded (${document.lineCount} lines, ${document.byteCount} bytes).`
    : `Loaded ${document.lineCount} lines and ${document.byteCount} bytes.`;
  const truncationNotice = document.truncated
    ? [
        "",
        "The injected MEMORY.md was truncated and does not show the full list of memory items.",
        `Search the full file at ${JSON.stringify(document.path)} before concluding that no relevant memory exists.`,
      ]
    : [];

  return [
    "## Claude Code Auto Memory",
    "",
    `Source: ${JSON.stringify(document.path)}`,
    loadDescription,
    `Topic files linked from MEMORY.md are relative to ${JSON.stringify(memoryDirectory)}.`,
    "Use the read tool to load a linked topic file when it is relevant.",
    "Treat this content as remembered context, not enforced configuration. Current user requests and higher-priority instructions override it.",
    "This integration is read-only. Do not create, edit, or delete files in this memory directory.",
    "",
    "<claude-code-auto-memory>",
    document.content,
    ...truncationNotice,
    "</claude-code-auto-memory>",
  ].join("\n");
}

const defaultDependencies: ClaudeMemoryDependencies = {
  resolveMemoryPath: resolveClaudeMemoryPath,
  readMemory: readClaudeMemory,
};

export function registerClaudeMemoryExtension(
  pi: ExtensionAPI,
  dependencies: ClaudeMemoryDependencies = defaultDependencies,
): void {
  let cachedCwd: string | null = null;
  let cachedMemoryPath: string | null = null;

  async function memoryPathFor(cwd: string): Promise<string | null> {
    if (cachedCwd === cwd && cachedMemoryPath !== null) {
      return cachedMemoryPath;
    }

    try {
      cachedMemoryPath = await dependencies.resolveMemoryPath(cwd);
      cachedCwd = cwd;
      return cachedMemoryPath;
    } catch {
      cachedCwd = cwd;
      cachedMemoryPath = null;
      return null;
    }
  }

  async function memoryFor(cwd: string): Promise<ClaudeMemoryDocument | null> {
    const path = await memoryPathFor(cwd);

    if (path === null) {
      return null;
    }

    try {
      return await dependencies.readMemory(path);
    } catch {
      return null;
    }
  }

  pi.on("session_start", async (_event, ctx) => {
    cachedCwd = null;
    cachedMemoryPath = null;
    await memoryPathFor(ctx.cwd);
  });

  pi.on("before_agent_start", async (event, ctx) => {
    const memory = await memoryFor(ctx.cwd);

    if (memory === null || memory.content.length === 0) {
      return;
    }

    return {
      systemPrompt: `${event.systemPrompt}\n\n${formatClaudeMemorySection(memory)}`,
    };
  });

  pi.registerCommand("claude-memory", {
    description: "Show the Claude Code auto-memory file loaded for this project",
    handler: async (_arguments, ctx) => {
      const path = await memoryPathFor(ctx.cwd);

      if (path === null) {
        ctx.ui.notify("Could not resolve the Claude Code auto-memory path.", "warning");
        return;
      }

      const memory = await memoryFor(ctx.cwd);

      if (memory === null) {
        ctx.ui.notify(`No Claude Code auto memory found at ${path}`, "warning");
        return;
      }

      const suffix = memory.truncated ? " (startup prefix)" : "";
      ctx.ui.notify(
        `Claude memory: ${path}\nLoaded ${memory.lineCount} lines and ${memory.byteCount} bytes${suffix}.`,
        "info",
      );
    },
  });
}

export default function claudeMemoryExtension(pi: ExtensionAPI): void {
  registerClaudeMemoryExtension(pi);
}
