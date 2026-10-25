# omp-ub-mode

Always-on [ub-mode](https://github.com/unclebob/ub-mode) for **OMP (oh-my-pi)**, **Pi**, and **OpenCode**. The plugin appends the full ub-mode skill text to the system prompt before every agent start: first prompt, every later turn, after resume, after compaction, and in subagent sessions.

Prompt injection is guidance, not deterministic enforcement — it shapes model behavior; it cannot validate code quality.

## Prerequisite: install the ub-mode skill separately

This plugin never vendors or redistributes the skill text: upstream has no
LICENSE, so it may not be redistributed here. Install the skill at one of the
paths below (or point `OMP_UB_MODE_SKILL` at any `SKILL.md`):

1. `$OMP_UB_MODE_SKILL` (file or directory containing `SKILL.md`)
2. `~/.config/skillshare/skills/ub-mode/SKILL.md`
3. `~/.agents/skills/ub-mode/SKILL.md`
4. `~/.claude/skills/ub-mode/SKILL.md`
5. `~/.codex/skills/ub-mode/SKILL.md`
6. `~/.openclaw/skills/ub-mode/SKILL.md`

If the skill file is missing, the plugin **fails loudly** — OMP/Pi surface the
error through their extension error channel; OpenCode logs it and puts a
visible `[omp-ub-mode] ERROR` line in the prompt. It never silently injects
nothing.

## Install

### OMP (oh-my-pi)

```sh
omp plugin install github:joshuaswarren/omp-ub-mode
```

If your `omp plugin install` build does not accept `github:` specs, add the
dependency to `~/.omp/plugins/package.json` and install:

```sh
cd ~/.omp/plugins
# package.json: "dependencies": { "omp-ub-mode": "github:joshuaswarren/omp-ub-mode#main", ... }
bun install   # or: npm install
```

The package declares `pi.extensions` and OMP reads the `pi` manifest when no
`omp` field exists, so no OMP-specific manifest is needed.

### Pi

```sh
pi install git:github.com/joshuaswarren/omp-ub-mode
```

### OpenCode

`opencode.json`:

```json
{ "plugin": ["omp-ub-mode"] }
```

OpenCode resolves npm package names; from a checkout, point at the file:

```json
{ "plugin": ["/absolute/path/to/omp-ub-mode/opencode.js"] }
```

### Already-running sessions

Plugins load at session start. Already-running sessions keep their current
prompts until restarted; the injection applies to new sessions (and, inside a
session, to every preparation from the moment the plugin is loaded).

## Behavior check

```sh
node --test test.js
```

Covers: search-path resolution, env override (file and directory), loud
missing-skill failure, frontmatter stripping, OMP array-form injection
(preserve + append + duplicate guard), Pi string-form injection, repeat
preparations (no accumulation), and compaction-like / subagent-like
re-preparations.

## How injection works

- **OMP / Pi** (`index.js`): `before_agent_start` handler appends one
  `[ub-mode]` segment to the (freshly rebuilt) system prompt. Returning the
  array with existing segments intact preserves other extensions' content.
- **OpenCode** (`opencode.js`): `experimental.chat.system.transform` appends
  the block once per request.
- A duplicate guard (`[ub-mode]` marker scan) keeps the copy count at one even
  if a host re-enters an already-extended prompt.

## Design constraints

- The skill is loaded from disk at runtime; nothing upstream is copied into
  this repository.
- Missing skill = loud error, never a silent no-op.
- The plugin injects guidance only. It does not run checks or validate code.
