// omp-ub-mode — OpenCode plugin entry.
//
// Wire it up in opencode.json:
//   { "plugin": ["omp-ub-mode"] }                     // npm install
//   { "plugin": ["/abs/path/to/omp-ub-mode/opencode.js"] } // from a checkout
//
// `experimental.chat.system.transform` runs before every chat request, so the
// block re-applies each turn (fresh transform per request — no accumulation).
//
// Both the injected block and the error diagnostic are appended INTO the
// existing last system segment (a new segment is added only when none
// exists) — some backends require exactly one system message.

import { DIAGNOSTIC_TAG, SENTINEL, buildBlock, loadSkillBody } from "./core.js";

export default async ({ client, env, home } = {}) => ({
	"experimental.chat.system.transform": async (_input, output) => {
		const appendOnce = (text, tag) => {
			if (output.system.some((segment) => segment.includes(tag))) return;
			if (output.system.length > 0) {
				output.system[output.system.length - 1] += "\n\n" + text;
			} else {
				output.system.push(text);
			}
		};
		let block;
		try {
			block = buildBlock(loadSkillBody(env, home));
		} catch (err) {
			// Visible diagnostics, not a hard gate: log the error and put a
			// clearly-tagged line in the prompt so a missing install is obvious
			// in-context; the turn proceeds. Uses its own tag (never the
			// injection sentinel) so a later successful load still injects.
			const message = String((err && err.message) || err).split("\n")[0];
			try {
				// Awaited so a rejecting log call is caught here instead of
				// surfacing as an unhandled rejection.
				await client?.app?.log?.({
					body: { service: "omp-ub-mode", level: "error", message },
				});
			} catch {}
			appendOnce(
				DIAGNOSTIC_TAG +
					" ERROR: ub-mode skill not injected — " +
					message +
					" Fix the install (see the omp-ub-mode README).",
				DIAGNOSTIC_TAG,
			);
			return;
		}
		appendOnce(block, SENTINEL);
	},
});
