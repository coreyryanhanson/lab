import { fileURLToPath } from "node:url";
import { dirname, resolve, join, relative } from "node:path";
import {
	readFileSync,
	existsSync,
	readdirSync,
	statSync,
	realpathSync,
} from "node:fs";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

// Resolve the .txt file relative to this file's location on disk.
const __dirname = dirname(fileURLToPath(import.meta.url));
const PROMPT_INITIALIZE = readFileSync(
	resolve(__dirname, "initialize.txt"),
	"utf-8",
);

// Per-directory precedence, mirroring Pi's own context-file discovery.
const AGENTS_FILES = ["AGENTS.override.md", "AGENTS.md", "AGENTS.MD"];

// Directories to skip when walking down for children. Keeps the walk cheap
// and avoids surfacing build/vendor noise.
// ponytail: fixed skip-set; add entries here if a repo's generated tree is huge.
const SKIP_DIRS = new Set([
	"node_modules",
	"dist",
	"build",
	"target",
	"out",
	"coverage",
]);

// Split the template into named blocks delimited by `---NAME---` lines, so
// the handler can compose only the blocks relevant to this invocation
// (e.g. layering guidance is conditional on children being present).
function parseBlocks(text: string): Record<string, string> {
	const blocks: Record<string, string> = {};
	let name = "";
	let buf: string[] = [];
	for (const line of text.split("\n")) {
		const m = /^---([A-Z_]+)---$/.exec(line);
		if (m) {
			if (name) blocks[name] = buf.join("\n").trim();
			name = m[1];
			buf = [];
		} else {
			buf.push(line);
		}
	}
	if (name) blocks[name] = buf.join("\n").trim();
	return blocks;
}

const BLOCKS = parseBlocks(PROMPT_INITIALIZE);

function firstAgentsFile(dir: string): string | null {
	for (const name of AGENTS_FILES) {
		const p = join(dir, name);
		if (existsSync(p)) return p;
	}
	return null;
}

// Recursive walk down from cwd, collecting children's AGENTS.md files.
// The cwd's own file is excluded (it is the file being authored). Dot-dirs
// and SKIP_DIRS are pruned.
//
// Parents are intentionally NOT walked: Pi already loads ancestor AGENTS.md
// into the model's context, so listing them would be redundant metadata.
function findChildren(root: string): string[] {
	const found: string[] = [];
	const visited = new Set<string>(); // realpath-keyed, breaks symlink loops
	const stack: string[] = [root];
	while (stack.length) {
		const dir = stack.pop() as string;
		let real: string;
		try {
			real = realpathSync(dir);
		} catch {
			continue;
		}
		if (visited.has(real)) continue;
		visited.add(real);
		if (dir !== root) {
			const chosen = firstAgentsFile(dir);
			if (chosen) found.push(chosen);
		}
		let entries: string[];
		try {
			entries = readdirSync(dir);
		} catch {
			continue;
		}
		for (const name of entries) {
			const p = join(dir, name);
			let st: ReturnType<typeof statSync>;
			try {
				st = statSync(p);
			} catch {
				continue;
			}
			if (st.isDirectory() && !SKIP_DIRS.has(name) && !name.startsWith(".")) {
				stack.push(p);
			}
		}
	}
	found.sort((a, b) => a.localeCompare(b));
	return found;
}

export default function agentsMdInitExtension(pi: ExtensionAPI) {
	pi.registerCommand("init", {
		description: "guided AGENTS.md setup",
		handler: (args, ctx) => {
			if (!ctx.isIdle()) {
				ctx.ui.notify("Please wait for the current task to finish.", "warning");
				return;
			}

			const cwd = ctx.cwd;
			const children = findChildren(cwd);
			const hasChildren = children.length > 0;
			// Detect an existing AGENTS.md at this level so the prompt is
			// either create-flavored or update-flavored — the agent no longer
			// has to branch on this itself.
			const existing = firstAgentsFile(cwd);
			const isUpdate = existing !== null;

			// Layering section only appears when children exist — otherwise
			// the stacking/dedup complexity isn't warranted and is omitted
			// entirely. The descendant clause in the Exclude bullet tracks
			// the same condition so it stays consistent with the section.
			const sections = [BLOCKS.BASE];
			if (hasChildren) {
				sections.push(
					BLOCKS.LAYERING_CHILDREN.replaceAll(
						"${CHILD_LIST}",
						children.map((p) => `- ${relative(cwd, p)}`).join("\n"),
					),
				);
			}
			sections.push(BLOCKS.BODY);
			sections.push(isUpdate ? BLOCKS.UPDATE_NOTE : BLOCKS.CREATE_NOTE);

			const template = sections
				.join("\n\n")
				.replaceAll("${path}", cwd)
				.replaceAll("$ARGUMENTS", args || "(none provided)")
				.replaceAll("${VERB}", isUpdate ? "Update" : "Create")
				.replaceAll(
					"${DESCENDANT_CLAUSE}",
					hasChildren
						? "- details that belong in a descendant's own `AGENTS.md`\n"
						: "",
				);

			ctx.ui.notify(
				`Running /init — ${isUpdate ? "updating existing" : "creating new"} AGENTS.md (child AGENTS.md: ${children.length})...`,
				"info",
			);

			// Send as a user message to trigger an LLM turn.
			// The LLM receives the init prompt and follows its instructions
			// to read the repo and create/update AGENTS.md.
			pi.sendUserMessage(template);
		},
	});
}
