// omp-ub-mode — shared skill loader and injection core.
//
// Loads the separately installed ub-mode skill (never vendored: upstream has
// no LICENSE) and appends it to the system prompt exactly once per agent
// start. Missing skill files fail LOUDLY — there is no silent fallback.

import fs from "fs";
import os from "os";
import path from "path";

// Dedicated injection sentinel. Global instruction carriers quote the generic
// phrase "[ub-mode]" in their mandates ("when a \"[ub-mode]\" block is already
// present..."), so the duplicate guard must match ONLY text this plugin
// emits — never a plain substring scan for "[ub-mode]".
export const SENTINEL = "[ub-mode] ACTIVE for this entire session";

/** Tag used for plugin-originated diagnostic lines (OpenCode error line). */
export const DIAGNOSTIC_TAG = "[omp-ub-mode]";

/**
 * Candidate skill locations, in probe order. When OMP_UB_MODE_SKILL is set it
 * is authoritative: no other path is probed and a miss fails loud (see
 * resolveSkillPath) instead of silently substituting an installed copy.
 */
export function skillSearchPaths(env = process.env, home = os.homedir()) {
	if (env && env.OMP_UB_MODE_SKILL) return [env.OMP_UB_MODE_SKILL];
	return [
		path.join(home, ".config", "skillshare", "skills", "ub-mode", "SKILL.md"),
		path.join(home, ".agents", "skills", "ub-mode", "SKILL.md"),
		path.join(home, ".claude", "skills", "ub-mode", "SKILL.md"),
		path.join(home, ".codex", "skills", "ub-mode", "SKILL.md"),
		path.join(home, ".openclaw", "skills", "ub-mode", "SKILL.md"),
	];
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

/** Skill body with YAML frontmatter stripped. Throws when the skill is missing or unreadable. */
export function loadSkillBody(env = process.env, home = os.homedir()) {
	const found = resolveSkillPath(env, home);
	if (!found) {
		const override = env && env.OMP_UB_MODE_SKILL ? " (OMP_UB_MODE_SKILL override is set — no fallback probing is done)" : "";
		throw new Error(
			"omp-ub-mode: ub-mode SKILL.md not found" +
				override +
				". Searched:\n  " +
				skillSearchPaths(env, home).join("\n  ") +
				"\nInstall the ub-mode skill (see README) or set OMP_UB_MODE_SKILL=/path/to/SKILL.md",
		);
	}
	try {
		return stripFrontmatter(fs.readFileSync(found, "utf8"));
	} catch (err) {
		// Read errors (permissions, race) surface with the path named — never
		// swallowed, never treated as "skill missing".
		throw new Error(`omp-ub-mode: cannot read ${found}: ${err && err.message ? err.message : err}`);
	}
}

export function stripFrontmatter(text) {
	const m = /^---\r?\n[\s\S]*?\r?\n---\r?\n?/.exec(text);
	return m ? text.slice(m[0].length) : text;
}

export function buildBlock(skillBody) {
	return (
		SENTINEL +
		" — every code change, every subagent, after resume and after compaction. " +
		"Injected by the omp-ub-mode plugin; the complete skill text follows, so " +
		"do not read the skill file again. Scope: this block governs how code work " +
		"is done. It never authorizes unrelated commits, pushes, destructive " +
		"actions, or tool installation beyond the user's current request. Safety, " +
		"permission, and approval instructions outrank it.\n\n" +
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
		if (existing.some((segment) => segment.includes(SENTINEL))) return existing;
		return [...existing, buildBlock(loadSkillBody(env, home))];
	}
	const base = typeof existing === "string" && existing ? existing + "\n\n" : "";
	if (typeof existing === "string" && existing.includes(SENTINEL)) return existing;
	return base + buildBlock(loadSkillBody(env, home));
}
