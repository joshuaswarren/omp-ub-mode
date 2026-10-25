// omp-ub-mode behavior check. Run: node --test test.js
//
// Tests drive the ACTUAL hook surfaces — the omp/Pi extension factory
// (index.js) and the OpenCode transform hook (opencode.js) — not just the
// shared helpers. Coverage: canonical-mandate prompts (which contain the
// literal phrase "[ub-mode]") still receive the full skill body via the
// dedicated sentinel; existing prompts preserved; duplicate guard on repeat;
// loud failure when the skill is missing (env override is authoritative, no
// silent fallback); frontmatter stripped; compaction-like / subagent-like
// re-preparations.

import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { DIAGNOSTIC_TAG, SENTINEL, inject, loadSkillBody, resolveSkillPath, skillSearchPaths } from "./core.js";
import ubModeExtension from "./index.js";
import opencodePlugin from "./opencode.js";

const SKILL_BODY = "Write the test first. Refactor only with a green suite. Never fake a pass.";

// The canonical carrier mandates (CLAUDE.md / codex AGENTS.md / OpenCode
// global AGENTS.md) quote the generic phrase "[ub-mode]". A system prompt
// carrying that text must still get the injection — regression guard for the
// old generic-substring duplicate check that suppressed it.
const CARRIER_MANDATE =
	"## ub-mode — ALWAYS ON, applies to every code change\n\n" +
	'... when a "[ub-mode]" block is already present in your context, that block IS the loaded skill ...';

function tempHome() {
	return fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "omp-ub-mode-")));
}

function installSkill(home, dirName = ".agents") {
	const dir = path.join(home, dirName, "skills", "ub-mode");
	fs.mkdirSync(dir, { recursive: true });
	fs.writeFileSync(path.join(dir, "SKILL.md"), "---\nname: ub-mode\ndescription: tdd\n---\n\n" + SKILL_BODY);
	return path.join(dir, "SKILL.md");
}

/** Installs the omp/Pi extension factory's before_agent_start handler. */
function captureExtensionHandler() {
	let handler;
	ubModeExtension({
		on: (event, h) => {
			if (event === "before_agent_start") handler = h;
		},
	});
	assert.equal(typeof handler, "function", "extension factory did not register before_agent_start");
	return handler;
}

/** Installs the OpenCode transform hook. client.app.log records calls. */
async function captureOpenCodeTransform() {
	const logCalls = [];
	const client = { app: { log: (body) => logCalls.push(body) } };
	const plugin = await opencodePlugin({ client });
	const transform = plugin["experimental.chat.system.transform"];
	assert.equal(typeof transform, "function", "opencode plugin did not register the transform hook");
	return { transform, logCalls };
}

test("resolves the skill through the search paths", () => {
	const home = tempHome();
	const file = installSkill(home);
	assert.equal(resolveSkillPath({}, home), file);
});

test("env override wins, accepts file or directory, and is authoritative", () => {
	const home = tempHome();
	const file = installSkill(home);
	const other = tempHome();
	assert.equal(resolveSkillPath({ OMP_UB_MODE_SKILL: path.dirname(file) }, other), file);
	assert.equal(resolveSkillPath({ OMP_UB_MODE_SKILL: file }, other), file);
	// Authoritative: an env path that does not exist fails loud and never
	// silently substitutes the copy installed under the other home.
	assert.throws(
		() => loadSkillBody({ OMP_UB_MODE_SKILL: "/nonexistent/ub-mode/SKILL.md" }, other),
		(err) => {
			assert.match(err.message, /not found/);
			assert.match(err.message, /OMP_UB_MODE_SKILL override is set/);
			assert.ok(!err.message.includes(other), "must not silently fall back to installed copies");
			return true;
		},
	);
});

test("missing skill throws loudly and names every searched path", () => {
	const home = tempHome();
	assert.throws(
		() => loadSkillBody({}, home),
		(err) => {
			assert.match(err.message, /SKILL\.md not found/);
			for (const p of skillSearchPaths({}, home)) assert.ok(err.message.includes(p));
			return true;
		},
	);
});

test("unreadable skill file surfaces a read error naming the path", () => {
	const home = tempHome();
	const file = installSkill(home);
	const real = fs.readFileSync;
	fs.readFileSync = (p, ...rest) => {
		if (String(p) === file) {
			const e = new Error("EACCES: permission denied");
			throw e;
		}
		return real(p, ...rest);
	};
	try {
		assert.throws(() => loadSkillBody({}, home), /cannot read .*EACCES/);
	} finally {
		fs.readFileSync = real;
	}
});

test("frontmatter is stripped from the injected body", () => {
	const home = tempHome();
	installSkill(home);
	assert.equal(loadSkillBody({}, home), SKILL_BODY);
});

// --- omp / Pi extension hook (actual factory-registered handler) ---

test("omp hook: mandate-carrying prompt still gets the full skill body appended", async () => {
	const home = tempHome();
	installSkill(home);
	const handler = captureExtensionHandler();
	const result = await handler({ type: "before_agent_start", prompt: "hi", systemPrompt: ["base", CARRIER_MANDATE] });
	assert.ok(result && Array.isArray(result.systemPrompt));
	const out = result.systemPrompt;
	assert.equal(out.length, 3);
	assert.deepEqual(out.slice(0, 2), ["base", CARRIER_MANDATE]); // existing preserved
	assert.ok(out[2].startsWith(SENTINEL));
	assert.ok(out[2].includes(SKILL_BODY), "skill body must be present verbatim");
	assert.ok(out[2].includes("never authorizes unrelated commits"), "policy boundary present");
});

test("omp hook: empty base injects standalone block", async () => {
	installSkill(tempHome());
	const handler = captureExtensionHandler();
	const ok = await handler({ systemPrompt: [] });
	assert.equal(ok.systemPrompt.length, 1);
	assert.ok(ok.systemPrompt[0].startsWith(SENTINEL));
});

test("omp hook: missing skill throws loudly (env override authoritative)", async () => {
	const handler = captureExtensionHandler();
	const saved = process.env.OMP_UB_MODE_SKILL;
	process.env.OMP_UB_MODE_SKILL = "/nonexistent/ub-mode/SKILL.md";
	try {
		await assert.rejects(() => handler({ systemPrompt: ["base"] }), /SKILL\.md not found/);
	} finally {
		if (saved === undefined) delete process.env.OMP_UB_MODE_SKILL;
		else process.env.OMP_UB_MODE_SKILL = saved;
	}
});

test("omp hook: repeated calls never accumulate copies (fresh and re-entered bases)", async () => {
	const home = tempHome();
	installSkill(home);
	const handler = captureExtensionHandler();
	for (let turn = 0; turn < 4; turn++) {
		const fresh = await handler({ systemPrompt: [CARRIER_MANDATE] }); // real per-preparation rebuild
		assert.equal(fresh.systemPrompt.filter((s) => s.includes(SENTINEL)).length, 1);
		// Host re-entering the already-extended prompt must be a no-op too.
		const again = await handler({ systemPrompt: fresh.systemPrompt });
		assert.equal(again.systemPrompt.filter((s) => s.includes(SENTINEL)).length, 1);
	}
});

test("omp hook: compaction-like and subagent-like re-preparations re-apply", async () => {
	const home = tempHome();
	installSkill(home);
	const handler = captureExtensionHandler();
	for (const out of [
		await handler({ systemPrompt: ["post-compaction base"] }),
		await handler({ systemPrompt: ["post-compaction base"] }),
	]) {
		assert.deepEqual(out.systemPrompt[0], "post-compaction base");
		assert.match(out.systemPrompt[1], new RegExp("^" + SENTINEL.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
	}
});

// --- shared inject() string form (Pi) ---

test("pi string systemPrompt: preserved, extended once, guard idempotent", () => {
	const home = tempHome();
	installSkill(home);
	const out = inject(CARRIER_MANDATE, {}, home);
	assert.ok(out.startsWith(CARRIER_MANDATE + "\n\n" + SENTINEL));
	assert.equal(out.split(SENTINEL).length - 1, 1);
	assert.equal(inject(out, {}, home), out);
});

// --- OpenCode transform hook (actual plugin hook) ---

test("opencode hook: mandate-carrying prompt gets body appended; repeat guarded", async () => {
	const home = tempHome();
	installSkill(home);
	const { transform } = await captureOpenCodeTransform();
	const output = { system: [CARRIER_MANDATE] };
	await transform({}, output);
	assert.equal(output.system.length, 2);
	assert.equal(output.system[0], CARRIER_MANDATE);
	assert.ok(output.system[1].includes(SKILL_BODY));
	const before = output.system.join("\n");
	await transform({}, output);
	assert.equal(output.system.join("\n"), before, "repeat transform must not append a second copy");
});

test("opencode hook: missing install emits visible diagnostic, not silence", async () => {
	const saved = process.env.OMP_UB_MODE_SKILL;
	process.env.OMP_UB_MODE_SKILL = "/nonexistent/ub-mode/SKILL.md";
	try {
		const { transform, logCalls } = await captureOpenCodeTransform();
		const output = { system: ["base prompt"] };
		await transform({}, output);
		assert.equal(output.system.length, 2);
		assert.match(output.system[1], /\[omp-ub-mode\] ERROR: ub-mode skill not injected/);
		assert.ok(!output.system[1].includes(SENTINEL), "error line must not look like an injection");
		assert.equal(logCalls.length, 1);
		assert.equal(logCalls[0].body.level, "error");
		// Second turn: diagnostic not duplicated.
		await transform({}, output);
		assert.equal(output.system.filter((s) => s.includes(DIAGNOSTIC_TAG)).length, 1);
	} finally {
		if (saved === undefined) delete process.env.OMP_UB_MODE_SKILL;
		else process.env.OMP_UB_MODE_SKILL = saved;
	}
});
