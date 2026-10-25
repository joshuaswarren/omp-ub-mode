// omp-ub-mode behavior check. Run: node --test test.js
//
// Covers the actual hooks' shared logic: skill resolution (search paths + env
// override), loud failure when the skill is missing, frontmatter stripping,
// omp array-form injection (preserve + append + duplicate guard), Pi string
// form, repeat preparations (no accumulation), and compaction-like /
// subagent-like re-preparations (block re-applies on every fresh base).

import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { inject, loadSkillBody, resolveSkillPath, skillSearchPaths, MARKER } from "./core.js";

const SKILL_BODY = "Write the test first. Refactor only with a green suite. Never fake a pass.";

function tempHome() {
	return fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "omp-ub-mode-")));
}

function installSkill(home, dirName = ".agents") {
	const dir = path.join(home, dirName, "skills", "ub-mode");
	fs.mkdirSync(dir, { recursive: true });
	fs.writeFileSync(path.join(dir, "SKILL.md"), "---\nname: ub-mode\ndescription: tdd\n---\n\n" + SKILL_BODY);
	return path.join(dir, "SKILL.md");
}

test("resolves the skill through the search paths", () => {
	const home = tempHome();
	const file = installSkill(home);
	assert.equal(resolveSkillPath({}, home), file);
});

test("env override wins and accepts a directory or a file", () => {
	const home = tempHome();
	const file = installSkill(home);
	const other = tempHome();
	assert.equal(resolveSkillPath({ OMP_UB_MODE_SKILL: path.dirname(file) }, other), file);
	assert.equal(resolveSkillPath({ OMP_UB_MODE_SKILL: file }, other), file);
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

test("frontmatter is stripped from the injected body", () => {
	const home = tempHome();
	installSkill(home);
	const body = loadSkillBody({}, home);
	assert.equal(body, SKILL_BODY);
});

test("omp: appends exactly one block, preserving existing segments", () => {
	const home = tempHome();
	installSkill(home);
	const out = inject(["base policy", "tool policy"], {}, home);
	assert.equal(out.length, 3);
	assert.deepEqual(out.slice(0, 2), ["base policy", "tool policy"]);
	assert.match(out[2], /^\[ub-mode\] ACTIVE/);
	assert.ok(out[2].includes(SKILL_BODY));
});

test("omp: duplicate guard returns the base untouched when already injected", () => {
	const home = tempHome();
	installSkill(home);
	const withBlock = ["base", MARKER + " ACTIVE ..."];
	assert.deepEqual(inject(withBlock, {}, home), withBlock);
});

test("pi: string systemPrompt is preserved and extended once", () => {
	const home = tempHome();
	installSkill(home);
	const out = inject("base prompt", {}, home);
	assert.ok(out.startsWith("base prompt\n\n[ub-mode] ACTIVE"));
	assert.equal(out.split(MARKER).length - 1, 1);
	assert.equal(inject(out, {}, home), out); // duplicate guard, string form
});

test("omp: empty/missing base still injects a standalone block", () => {
	const home = tempHome();
	installSkill(home);
	const out = inject([], {}, home);
	assert.equal(out.length, 1);
	assert.match(out[0], /^\[ub-mode\] ACTIVE/);
});

test("repeat preparations never accumulate copies", () => {
	const home = tempHome();
	installSkill(home);
	let prompt = ["base"];
	for (let turn = 0; turn < 5; turn++) {
		// Each turn the runtime rebuilds the base from scratch; the handler sees
		// the fresh base. Simulate a host that (incorrectly) reuses the extended
		// array too — the duplicate guard must keep the copy count at one.
		const rebuilt = inject(["base"], {}, home);
		assert.equal(rebuilt.filter((segment) => segment.includes(MARKER)).length, 1);
		assert.equal(inject(rebuilt, {}, home).filter((segment) => segment.includes(MARKER)).length, 1);
		prompt = rebuilt;
	}
	assert.equal(prompt.length, 2);
});

test("compaction-like and subagent-like re-preparations re-apply the block", () => {
	const home = tempHome();
	installSkill(home);
	const prepare = () => inject(["post-compaction base"], {}, home);
	for (const out of [prepare(), prepare(), prepare()]) {
		assert.equal(out.length, 2);
		assert.equal(out[0], "post-compaction base");
		assert.match(out[1], /^\[ub-mode\] ACTIVE/);
	}
});
