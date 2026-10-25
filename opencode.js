// omp-ub-mode — OpenCode plugin entry.
//
// Wire it up in opencode.json:
//   { "plugin": ["omp-ub-mode"] }                     // npm install
//   { "plugin": ["/abs/path/to/omp-ub-mode/opencode.js"] } // from a checkout
//
// `experimental.chat.system.transform` runs before every chat request, so the
// block re-applies each turn (fresh transform per request — no accumulation).

import { MARKER, buildBlock, loadSkillBody } from "./core.js";

export default async ({ client } = {}) => ({
	"experimental.chat.system.transform": async (_input, output) => {
		let block;
		try {
			block = buildBlock(loadSkillBody());
		} catch (err) {
			// No silent fallback: log loudly and put a visible error line in the
			// prompt so the missing install is obvious in-context. Uses its own
			// tag so a later successful load still injects the real block.
			const message = String((err && err.message) || err).split("\n")[0];
			try {
				client?.app?.log?.({
					body: { service: "omp-ub-mode", level: "error", message },
				});
			} catch {}
			if (!output.system.some((segment) => segment.includes("[omp-ub-mode]"))) {
				output.system.push(
					"[omp-ub-mode] ERROR: ub-mode skill file missing — " +
						message +
						" Fix the install (see the omp-ub-mode README).",
				);
			}
			return;
		}
		if (output.system.some((segment) => segment.includes(MARKER))) return;
		if (output.system.length > 0) {
			output.system[output.system.length - 1] += "\n\n" + block;
		} else {
			output.system.push(block);
		}
	},
});
