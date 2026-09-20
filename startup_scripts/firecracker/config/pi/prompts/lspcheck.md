---
description: Filtered diagnostic sweep (warms cache via raw LSP, reports from filtered session view)
---

Produce the FILTERED, complete diagnostic picture${@:+ for: $@} (default: this workspace). Follow this exact sequence — lens filters only apply to the session cache, and the cache starts cold:

1. Read `.pi-lens.json` at the repo root so you know which rules are deliberately suppressed.

2. Warm the cache: call `lens_diagnostics` with `source: "lsp"`, `mode: "full"`, `scope: "paths"`, and explicit `paths` covering every `*.ts` file under the target (find them with `find . -name '*.ts' -not -path '*/node_modules/*'`). CRITICAL: this raw output BYPASSES the filter and arrives truncated — do NOT report findings from it. Its only purpose is populating the session cache.

3. Read the filtered view: `lens_diagnostics` with `source: "session"`, `mode: "all"`. Report ONLY from this result.

4. Triage, don't dump:
   - Errors (blocking) first with file:line and a one-line read of the actual problem.
   - Warnings grouped by rule with counts; file:line detail for anything not obviously intentional.
   - Hints as per-rule counts only.
   - Classify each group: REAL (worth fixing), INTENTIONAL (matches a documented design decision — name it), or NOISE (rule structurally conflicts with the file's purpose, e.g. boundary-decoder rules against a YAML parser).
   - Present and stop. Do not fix anything until asked.
   - Suppression only works via the producing tool's NATIVE inline comment: `nosemgrep: <rule-id>` for Semgrep, `ast-grep-ignore: <rule-id>` for ast-grep. `pi-lens-ignore` comments are ignored by both — don't suggest them.

If a step reports cold-cache/unavailable, wait and retry once before concluding anything.
