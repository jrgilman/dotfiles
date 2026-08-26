import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

interface RuntimeModelIdentity {
  provider: string;
  id: string;
  name?: string;
}

export function formatModelIdentitySection(model: RuntimeModelIdentity): string {
  return [
    "## Runtime Model Identity",
    "",
    "Pi selected the following model for this agent run:",
    `- Provider: ${JSON.stringify(model.provider)}`,
    `- Model ID: ${JSON.stringify(model.id)}`,
    `- Display name: ${JSON.stringify(model.name ?? model.id)}`,
    "",
    "Treat these runtime values as authoritative when identifying the active model.",
  ].join("\n");
}

export default function modelIdentityExtension(pi: ExtensionAPI): void {
  pi.on("before_agent_start", (event, ctx) => {
    if (!ctx.model) {
      return;
    }

    return {
      systemPrompt: `${event.systemPrompt}\n\n${formatModelIdentitySection(ctx.model)}`,
    };
  });
}
