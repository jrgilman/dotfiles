import assert from "node:assert/strict";
import test from "node:test";

import modelIdentityExtension, { formatModelIdentitySection } from "./index.ts";

const model = {
  provider: "openai-codex",
  id: "gpt-5.6-sol",
  name: "GPT-5.6 Sol",
};

test("formats the runtime model identity", () => {
  assert.equal(
    formatModelIdentitySection(model),
    `## Runtime Model Identity

Pi selected the following model for this agent run:
- Provider: "openai-codex"
- Model ID: "gpt-5.6-sol"
- Display name: "GPT-5.6 Sol"

Treat these runtime values as authoritative when identifying the active model.`,
  );
});

test("adds the current model identity before an agent run", () => {
  let beforeAgentStart;

  modelIdentityExtension({
    on(eventName, handler) {
      if (eventName === "before_agent_start") {
        beforeAgentStart = handler;
      }
    },
  });

  assert.equal(typeof beforeAgentStart, "function");

  const result = beforeAgentStart(
    { systemPrompt: "Base system prompt" },
    { model },
  );

  assert.equal(
    result.systemPrompt,
    `Base system prompt

${formatModelIdentitySection(model)}`,
  );
});

test("leaves the system prompt unchanged when no model is selected", () => {
  let beforeAgentStart;

  modelIdentityExtension({
    on(eventName, handler) {
      if (eventName === "before_agent_start") {
        beforeAgentStart = handler;
      }
    },
  });

  assert.equal(beforeAgentStart({ systemPrompt: "Base" }, { model: undefined }), undefined);
});
