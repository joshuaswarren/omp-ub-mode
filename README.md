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

If the skill file is missing or unreadable, the plugin emits **visible
diagnostics — it is not a hard gate**. OMP/Pi surface the error through their
extension error channel and the turn proceeds without the block; OpenCode
logs the error and puts a visible `[omp-ub-mode] ERROR` line in the prompt.
It never silently injects nothing, and it never masks a broken install as a
working one.

`OMP_UB_MODE_SKILL` is authoritative when set: a missing or unreadable
override path fails with that path named; the plugin never silently
substitutes a copy from the default search paths.

The injected block carries a scope boundary: the skill governs how code work
is done and never authorizes unrelated commits, pushes, destructive actions,
or tool installation beyond the user's current request; safety, permission,
and approval instructions outrank it.

## Install

### OMP (oh-my-pi)

```sh
omp plugin install github:joshuaswarren/omp-ub-mode
```

This is the verified install path (installs to `~/.omp/plugins/node_modules/`,
registers in `~/.omp/plugins/package.json`).

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

## Bootstrap (public entry point)

`bootstrap.sh` updates an operator's own checkout of their ops repository and
runs that repository's refresh helper. It never clones, never carries a
credential, and never contacts another host: the checkout's existing git
authentication is used as-is.

```sh
bash bootstrap.sh --ops-dir ~/src/ops-repo --expect-origin git@github.com:owner/repo.git
```

- `--ops-dir` must be an existing checkout under the invoking user's home and
  the root of that checkout.
- `--expect-origin` must match that checkout's `origin`; a mismatch stops the
  run before the helper is executed, and any credentials in the URLs are
  redacted from the message.
- On `main` the update is `git fetch` + `git merge --ff-only` only. A diverged
  or conflicted checkout fails loudly and is left as it is: no stash, no
  reset, no force, no discarded local work.
- On any other branch, or a detached HEAD, the checkout is never switched,
  merged, stashed or reset: the fetched commit is materialized in a temporary
  isolated detached worktree under `$HOME`, verified to be exactly that
  commit and pristine, and the helper runs from there. The checkout keeps its
  HEAD, index and untracked files untouched. A worktree the helper left
  uncommitted files in is kept and its path printed, never force-removed.
- The helper is executed only after every check above passed, and only from
  the fetched commit's tree: `origin/main` is fetched by explicit refspec
  (`refs/heads/main` only, no tags), and every file the helper executes (the
  helper, its pins, the ponytail installer, the analysis installer and its
  fixture library, the viewer installer) must be tracked by git and identical
  to the fetched commit. A local edit is never executed.
- Anything after `--` is passed to the helper unchanged, e.g.
  `-- --dry-run`. A dry run still updates (fast-forward on `main`, fetch plus
  verified worktree anywhere else) but does not run the helper.

Download it into a private temporary file and verify its checksum before it is
executed. Use `mktemp`, never a fixed name: a predictable path in a shared
`/tmp` can be pre-created or replaced by another user between the download
and the run.

```sh
tmp="$(mktemp "${TMPDIR:-/tmp}/omp-ub-mode-bootstrap.XXXXXX")" \
  && curl -fsSL https://raw.githubusercontent.com/joshuaswarren/omp-ub-mode/<commit>/bootstrap.sh -o "$tmp" \
  && echo "<sha256>  $tmp" | sha256sum -c - \
  && bash "$tmp" --ops-dir ~/src/ops-repo --expect-origin git@github.com:owner/repo.git; \
  rc=$?; rm -f "$tmp"; echo "exit=$rc"; [ "$rc" -eq 0 ]
```

The last test carries the exit status: a failed run leaves a non-zero status
for the caller instead of being masked by the final echo.

All of `bootstrap.sh`'s definitions come first and its single `main` call is
last, so a truncated download can only stop the helper from running — it can
never run a half-written helper. A file that ends before `main` ran exits
nonzero instead of reporting success.

Check it with `bash test-bootstrap.sh` (Bash and coreutils only).

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
- A duplicate guard keyed on the dedicated injected sentinel
  (`[ub-mode] ACTIVE for this entire session`) keeps the copy count at one
  even if a host re-enters an already-extended prompt. Global instruction
  carriers quote the generic phrase `[ub-mode]` in their mandates, so the
  guard never matches on that alone.

## Design constraints

- The skill is loaded from disk at runtime; nothing upstream is copied into
  this repository.
- Missing skill = loud error, never a silent no-op.
- The plugin injects guidance only. It does not run checks or validate code.
