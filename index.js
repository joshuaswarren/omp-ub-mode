// omp-ub-mode — extension entry for OMP (oh-my-pi) and Pi.
//
// OMP reads package.json `pi.extensions` (it falls back to the pi manifest
// when no `omp` field exists), so this single entry loads in both runtimes.
//
// `before_agent_start` fires on every agent start: the first prompt, every
// later prompt preparation, after resume, after compaction, and in subagent
// sessions (the runner creates extension instances per session). The base
// system prompt is rebuilt fresh per preparation, so appending here yields
// exactly one copy per request — never accumulation.

import { inject } from "./core.js";

/**
 * `options.env` / `options.home` are injection points for tests; production
 * callers (omp, Pi) pass only the API and the defaults apply.
 */
export default function ubModeExtension(pi, options = {}) {
	pi.on("before_agent_start", async (event) => ({
		// Full replacement of the prompt, carrying every existing segment plus
		// the ub-mode block. A missing skill file throws here and the runtime
		// surfaces the error (OMP emitError) — no silent no-injection fallback.
		systemPrompt: inject(event?.systemPrompt, options.env, options.home),
	}));
}
