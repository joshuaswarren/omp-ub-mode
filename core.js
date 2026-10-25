// omp-ub-mode — shared skill loader and injection core.
//
// Loads the separately installed ub-mode skill (never vendored: upstream has
// no LICENSE) and appends it to the system prompt exactly once per agent
// start. Missing skill files fail LOUDLY — there is no silent fallback.

import fs from "fs";
import os from "os";
import path from "path";

export const MARKER = "[ub-mode]";

/** Every candidate skill location, in probe order. */
export function skillSearchPaths(env = process.env, home = os.homedir()) {
	const paths = [];
	if (env && env.OMP_UB_MODE_SKILL) paths.push(env.OMP_UB_MODE_SKILL);
	for (const dir of [
		path.join(home, ".config", "skillshare", "skills", "ub-mode"),
		path.join(home, ".agents", "skills", "ub-mode"),
		path.join(home, ".claude", "skills", "ub-mode"),
		path.join(home, ".codex", "skills", "ub-mode"),
		path.join(home, ".openclaw", "skills", "ub-mode"),
	]) {
		paths.push(path.join(dir, "SKILL.md"));
	}
	return paths;
}

/** First existing SKILL.md (env var may point at a file or a directory). */
export function resolveSkillPath(env = process.env, home = os.homedir()) {
	for (const candidate of skillSearchPaths(env, home)) {
		try {
			const st = fs.statSync(candidate);
			if (st.isDirectory()) {
				const inner = path.join(candidate, "SKILL.md");
				if (fs.statSync(inner).isFile()) return inner;
				continue;
			}
			if (st.isFile()) return candidate;
		} catch {
			// keep probing
		}
	}
	return undefined;
}

/** Skill body with YAML frontmatter stripped. Throws when the skill is missing. */
export function loadSkillBody(env = process.env, home = os.homedir()) {
	const found = resolveSkillPath(env, home);
	if (!found) {
		throw new Error(
			"omp-ub-mode: ub-mode SKILL.md not found. Searched:\n  " +
				skillSearchPaths(env, home).join("\n  ") +
				"\nInstall the ub-mode skill (see README) or set OMP_UB_MODE_SKILL=/path/to/SKILL.md",
		);
	}
	return stripFrontmatter(fs.readFileSync(found, "utf8"));
}

export function stripFrontmatter(text) {
	const m = /^---\r?\n[\s\S]*?\r?\n---\r?\n?/.exec(text);
	return m ? text.slice(m[0].length) : text;
}

export function buildBlock(skillBody) {
	return (
		MARKER +
		" ACTIVE for this entire session — every code change, every subagent, " +
		"after resume and after compaction. Injected by the omp-ub-mode plugin; " +
		"the complete skill text follows, so do not read the skill file again.\n\n" +
		skillBody.trim()
	);
}

/**
 * Append the ub-mode block to a system prompt exactly once, preserving all
 * existing content. omp passes `string[]` (extensions chain by replacement, so
 * we return the array with one appended segment); Pi passes a plain string.
 */
export function inject(existing, env = process.env, home = os.homedir()) {
	if (Array.isArray(existing)) {
		if (existing.some((segment) => segment.includes(MARKER))) return existing;
		return [...existing, buildBlock(loadSkillBody(env, home))];
	}
	const base = typeof existing === "string" && existing ? existing + "\n\n" : "";
	if (existing && existing.includes && existing.includes(MARKER)) return existing;
	return base + buildBlock(loadSkillBody(env, home));
}
