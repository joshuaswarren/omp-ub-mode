// omp-ub-mode — OpenCode plugin entry.
//
// Wire it up in opencode.json:
//   { "plugin": ["omp-ub-mode"] }                     // npm install
//   { "plugin": ["/abs/path/to/omp-ub-mode/opencode.js"] } // from a checkout
//
// `experimental.chat.system.transform` runs before every chat request, so the
// block re-applies each turn (fresh transform per request — no accumulation).

import { DIAGNOSTIC_TAG, SENTINEL, buildBlock, loadSkillBody } from "./core.js";

export default async ({ client } = {}) => ({
	"experimental.chat.system.transform": async (_input, output) => {
		let block;
		try {
			block = buildBlock(loadSkillBody());
		} catch (err) {
			// Visible diagnostics, not a hard gate: log the error and put a
			// clearly-tagged line in the prompt so a missing install is obvious
			// in-context; the turn proceeds. Uses its own tag (never the
			// injection sentinel) so a later successful load still injects.
			const message = String((err && err.message) || err).split("\n")[0];
			try {
				client?.app?.log?.({
					body: { service: "omp-ub-mode", level: "error", message },
				});
			} catch {}
			if (!output.system.some((segment) => segment.includes(DIAGNOSTIC_TAG))) {
				output.system.push(
					DIAGNOSTIC_TAG +
						" ERROR: ub-mode skill not injected — " +
						message +
						" Fix the install (see the omp-ub-mode README).",
				);
			}
			return;
		}
		if (output.system.some((segment) => segment.includes(SENTINEL))) return;
		if (output.system.length > 0) {
			output.system[output.system.length - 1] += "\n\n" + block;
		} else {
			output.system.push(block);
		}
	},
});
