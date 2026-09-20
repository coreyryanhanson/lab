import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { promises as fs } from "node:fs";
import * as path from "node:path";

export default function (pi: ExtensionAPI) {
	pi.registerCommand("init_plan", {
		description:
			"Load a plan document to begin implementation. Usage: /init_plan <file>",
		handler: async (args, _ctx) => {
			const filePath = args.trim();
			if (!filePath) {
				pi.sendUserMessage(
					"Usage: /init_plan <file>\n\nProvide the path to a plan document to load.",
				);
				return;
			}

			let content: string;
			try {
				const abs = path.resolve(process.cwd(), filePath);
				content = "```markdown\n" + (await fs.readFile(abs, "utf-8")) + "\n```";
			} catch {
				pi.sendUserMessage(`Cannot read file: ${filePath}`);
				return;
			}

			pi.sendUserMessage(
				`I have the following plan document I'd like to anchor our work on:\n\n"${filePath}":\n\n${content}\n\nFrom the plan (and any planning docs it links to), could you put together a small table of what will need to be done and await further instructions? This is just to orient us, so no todos or task-tracking yet. Let's stay with the plan as written for this first pass rather than cross-check it against the current code. We'll get to that once we start digging in.`,
			);
		},
	});
}
