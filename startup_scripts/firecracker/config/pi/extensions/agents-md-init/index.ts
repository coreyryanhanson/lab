import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { readFileSync } from "node:fs";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

// Resolve the .txt file relative to this file's location on disk.
const __dirname = dirname(fileURLToPath(import.meta.url));
const PROMPT_INITIALIZE = readFileSync(
	resolve(__dirname, "initialize.txt"),
	"utf-8",
);

export default function agentsMdInitExtension(pi: ExtensionAPI) {
	pi.registerCommand("init", {
		description: "guided AGENTS.md setup",
		handler: (args, ctx) => {
			if (!ctx.isIdle()) {
				ctx.ui.notify("Please wait for the current task to finish.", "warning");
				return;
			}

			// Substitute placeholders:
			//   ${path}      → the project root (ctx.cwd)
			//   $ARGUMENTS   → the user-provided arguments
			const template = PROMPT_INITIALIZE.replace("${path}", ctx.cwd).replace(
				"$ARGUMENTS",
				args || "(none provided)",
			);

			ctx.ui.notify("Running /init — investigating repository...", "info");

			// Send as a user message to trigger an LLM turn.
			// The LLM receives the init prompt and follows its instructions
			// to read the repo and create/update AGENTS.md.
			pi.sendUserMessage(template);
		},
	});
}
