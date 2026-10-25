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

// Shared by the success and diagnostic paths; two real call sites, kept at
// module scope so the transform hook stays small.
function appendOnce(output, text, tag) {
	if (output.system.some((segment) => segment.includes(tag))) return;
	if (output.system.length > 0) {
		output.system[output.system.length - 1] += "\n\n" + text;
	} else {
		output.system.push(text);
	}
}

// Named export so stack traces and mutation/detection tools attribute
// failures to this plugin instead of an anonymous arrow.
export default async function ubModeOpenCodePlugin({ client, env, home } = {}) {
	async function experimentalChatSystemTransform(_input, output) {
		let block;
		try {
			block = buildBlock(loadSkillBody(env, home));
		} catch (err) {
			// Visible diagnostics, not a hard gate: log the error and put a
			// clearly-tagged line in the prompt so a missing install is obvious
			// in-context; the turn proceeds. Uses its own tag (never the
			// injection sentinel) so a later successful load still injects.
			// loadSkillBody always throws Error instances, so err.message is
			// guaranteed; keep the first line only for the single-line prompt.
			const message = err.message.split("\n")[0];
			try {
				// Not optional-chained: the surrounding catch already handles an
				// absent client, absent method, or a rejected log sink. Awaited
				// so none of those surface as unhandled rejections.
				await client.app.log({
					body: { service: "omp-ub-mode", level: "error", message },
				});
			} catch {}
			appendOnce(
				output,
				DIAGNOSTIC_TAG +
					" ERROR: ub-mode skill not injected — " +
					message +
					" Fix the install (see the omp-ub-mode README).",
				DIAGNOSTIC_TAG,
			);
			return;
		}
		appendOnce(output, block, SENTINEL);
	}

	return { "experimental.chat.system.transform": experimentalChatSystemTransform };
}
