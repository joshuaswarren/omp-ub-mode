#!/usr/bin/env bash
# Regression check for bootstrap.sh (public). Bash + coreutils only.
#
#   bash test-bootstrap.sh
#
# Covers: flag handling, path validation, origin validation, fast-forward
# update, divergence safety (no reset/stash/force), helper-not-run on a
# failed check, truncation safety, and the absence of any other-host
# dispatch (ssh/scp/rsync/pct).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BOOTSTRAP="$HERE/bootstrap.sh"

pass=0
fail=0

ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$*"; }
no() { fail=$((fail + 1)); printf 'FAIL %s\n' "$*"; }

check() { # description expected_status command...
	desc="$1"; want="$2"; shift 2
	out="$("$@" 2>&1)"; got=$?
	if [ "$got" -eq "$want" ]; then
		ok "$desc (exit $got)"
	else
		no "$desc (exit $got, want $want)"
		printf '%s\n' "$out" | sed 's/^/     | /'
	fi
}

contains() { # description needle haystack
	case "$3" in
		*"$2"*) ok "$1" ;;
		*) no "$1 (missing: $2)"; printf '%s\n' "$3" | sed 's/^/     | /' ;;
	esac
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

export GIT_AUTHOR_NAME="bootstrap test"
export GIT_AUTHOR_EMAIL="bootstrap@test.invalid"
export GIT_COMMITTER_NAME="bootstrap test"
export GIT_COMMITTER_EMAIL="bootstrap@test.invalid"

# --- fixtures ---------------------------------------------------------------

HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR/src"
export HOME="$HOME_DIR"

ORIGIN="$TMP/origin.git"
git init --quiet --bare "$ORIGIN"
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main

WORK="$TMP/work"
mkdir -p "$WORK/scripts"
git init --quiet "$WORK"
git -C "$WORK" symbolic-ref HEAD refs/heads/main
# every dependency the helper executes must be tracked and clean
for dep in agent-workstation-refresh.pins install-ponytail.sh install-unclebob-tools.sh \
	unclebob-tools-fixture.sh install-uml-viewer.sh; do
	printf '# stub %s\n' "$dep" > "$WORK/scripts/$dep"
done
cat > "$WORK/scripts/agent-workstation-refresh.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
: "${BOOTSTRAP_TEST_MARKER:?}"
printf 'helper ran %s\n' "$*" >> "$BOOTSTRAP_TEST_MARKER"
printf 'stub helper ok\n'
EOF
chmod +x "$WORK/scripts/agent-workstation-refresh.sh"
git -C "$WORK" add -A
git -C "$WORK" commit --quiet -m "helper"
git -C "$WORK" remote add origin "$ORIGIN"
git -C "$WORK" push --quiet origin HEAD:refs/heads/main

OPS="$HOME_DIR/src/ops"
git clone --quiet "$ORIGIN" "$OPS"
export BOOTSTRAP_TEST_MARKER="$TMP/marker"
: > "$BOOTSTRAP_TEST_MARKER"

ORIGIN_URL="$ORIGIN"

# --- tests ------------------------------------------------------------------

check "help exits 0" 0 bash "$BOOTSTRAP" --help
out="$(bash "$BOOTSTRAP" --help 2>&1)"
contains "help prints usage" "--expect-origin" "$out"

check "unknown flag is a usage error" 2 bash "$BOOTSTRAP" --nope
check "missing --ops-dir is a usage error" 2 bash "$BOOTSTRAP" --expect-origin "$ORIGIN_URL"
check "missing --expect-origin is a usage error" 2 bash "$BOOTSTRAP" --ops-dir "$OPS"
check "absolute --helper is rejected" 2 bash "$BOOTSTRAP" --ops-dir "$OPS" --expect-origin "$ORIGIN_URL" --helper /etc/passwd

out="$(bash "$BOOTSTRAP" --ops-dir "$TMP/does-not-exist" --expect-origin "$ORIGIN_URL" 2>&1)"
rc=$?
[ "$rc" -eq 3 ] && ok "missing ops dir fails validation" || no "missing ops dir fails validation (exit $rc)"
contains "missing ops dir message" "does not exist" "$out"

mkdir -p "$HOME_DIR/not-a-repo"
out="$(bash "$BOOTSTRAP" --ops-dir "$HOME_DIR/not-a-repo" --expect-origin "$ORIGIN_URL" 2>&1)"
rc=$?
[ "$rc" -eq 3 ] && ok "non-repo ops dir fails validation" || no "non-repo ops dir fails validation (exit $rc)"
contains "non-repo ops dir message" "not a git checkout" "$out"

mkdir -p "$TMP/not-a-repo"
out="$(bash "$BOOTSTRAP" --ops-dir "$TMP/not-a-repo" --expect-origin "$ORIGIN_URL" 2>&1)"
rc=$?
[ "$rc" -eq 3 ] && ok "ops dir outside HOME fails validation" || no "ops dir outside HOME fails validation (exit $rc)"
contains "outside-HOME message" "outside" "$out"

# origin mismatch: the helper must not run
: > "$BOOTSTRAP_TEST_MARKER"
out="$(bash "$BOOTSTRAP" --ops-dir "$OPS" --expect-origin "git@github.com:someone/else.git" 2>&1)"
rc=$?
[ "$rc" -eq 3 ] && ok "origin mismatch fails validation" || no "origin mismatch fails validation (exit $rc)"
contains "origin mismatch message" "origin mismatch" "$out"
[ ! -s "$BOOTSTRAP_TEST_MARKER" ] && ok "helper did not run after origin mismatch" \
	|| no "helper ran despite origin mismatch"

# helper not tracked by git
git -C "$OPS" rm --quiet --cached scripts/agent-workstation-refresh.sh
out="$(bash "$BOOTSTRAP" --ops-dir "$OPS" --expect-origin "$ORIGIN_URL" 2>&1)"
rc=$?
[ "$rc" -eq 3 ] && ok "untracked helper fails validation" || no "untracked helper fails validation (exit $rc)"
contains "untracked helper message" "not tracked by git" "$out"
git -C "$OPS" reset --quiet --hard origin/main

# happy path: upstream gains a commit, the checkout fast-forwards, helper runs
git -C "$WORK" commit --quiet --allow-empty -m "upstream change"
git -C "$WORK" push --quiet origin HEAD:refs/heads/main
: > "$BOOTSTRAP_TEST_MARKER"
out="$(bash "$BOOTSTRAP" --ops-dir "$OPS" --expect-origin "$ORIGIN_URL" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] && ok "fast-forward update and helper run succeed" || no "fast-forward update and helper run succeed (exit $rc)"
contains "success prints DONE" "DONE" "$out"
[ "$(cat "$BOOTSTRAP_TEST_MARKER")" = "helper ran " ] && ok "helper ran once" || no "helper ran once"
[ "$(git -C "$OPS" rev-parse HEAD)" = "$(git -C "$WORK" rev-parse HEAD)" ] \
	&& ok "checkout is at the upstream commit" || no "checkout is at the upstream commit"

# divergence: local commit + upstream commit must fail without losing local work
git -C "$OPS" commit --quiet --allow-empty -m "local work"
local_sha="$(git -C "$OPS" rev-parse HEAD)"
git -C "$WORK" commit --quiet --allow-empty -m "upstream change 2"
git -C "$WORK" push --quiet origin HEAD:refs/heads/main
out="$(bash "$BOOTSTRAP" --ops-dir "$OPS" --expect-origin "$ORIGIN_URL" 2>&1)"
rc=$?
[ "$rc" -eq 4 ] && ok "diverged checkout fails the update" || no "diverged checkout fails the update (exit $rc)"
contains "divergence message" "fast-forward" "$out"
[ "$(git -C "$OPS" rev-parse HEAD)" = "$local_sha" ] \
	&& ok "local commit survived the failed update" || no "local commit survived the failed update"
[ -z "$(git -C "$OPS" stash list)" ] && ok "no stash was created" || no "no stash was created"

# a locally modified helper must not be executed
git -C "$OPS" reset --quiet --hard origin/main
printf '\n# local edit\n' >> "$OPS/scripts/agent-workstation-refresh.sh"
: > "$BOOTSTRAP_TEST_MARKER"
out="$(bash "$BOOTSTRAP" --ops-dir "$OPS" --expect-origin "$ORIGIN_URL" 2>&1)"
rc=$?
[ "$rc" -eq 3 ] && ok "modified helper is refused" || no "modified helper is refused (exit $rc)"
contains "modified helper message" "differs from HEAD" "$out"
[ ! -s "$BOOTSTRAP_TEST_MARKER" ] && ok "modified helper was not executed" || no "modified helper was not executed"
git -C "$OPS" checkout --quiet -- scripts/agent-workstation-refresh.sh

# only main is updated
git -C "$OPS" checkout --quiet -b side-branch
out="$(bash "$BOOTSTRAP" --ops-dir "$OPS" --expect-origin "$ORIGIN_URL" 2>&1)"
rc=$?
[ "$rc" -eq 4 ] && ok "a non-main checkout is refused" || no "a non-main checkout is refused (exit $rc)"
contains "a non-main checkout says why" "only updates main" "$out"
git -C "$OPS" checkout --quiet main

# every dependency the helper executes must be tracked and unmodified
printf '\n# local edit\n' >> "$OPS/scripts/install-ponytail.sh"
: > "$BOOTSTRAP_TEST_MARKER"
out="$(bash "$BOOTSTRAP" --ops-dir "$OPS" --expect-origin "$ORIGIN_URL" 2>&1)"
rc=$?
[ "$rc" -eq 4 ] && ok "a dirty dependency is refused" || no "a dirty dependency is refused (exit $rc)"
contains "a dirty dependency names the file" "install-ponytail.sh" "$out"
[ ! -s "$BOOTSTRAP_TEST_MARKER" ] && ok "the helper did not run with a dirty dependency" \
	|| no "the helper did not run with a dirty dependency"
git -C "$OPS" checkout --quiet -- scripts/install-ponytail.sh

# an untracked dependency is refused too
git -C "$OPS" rm --quiet --cached scripts/install-uml-viewer.sh
out="$(bash "$BOOTSTRAP" --ops-dir "$OPS" --expect-origin "$ORIGIN_URL" 2>&1)"
rc=$?
[ "$rc" -eq 4 ] && ok "an untracked dependency is refused" || no "an untracked dependency is refused (exit $rc)"
contains "an untracked dependency says why" "not tracked by git" "$out"
git -C "$OPS" reset --quiet --hard origin/main

# arguments after -- reach the helper unchanged
: > "$BOOTSTRAP_TEST_MARKER"
out="$(bash "$BOOTSTRAP" --ops-dir "$OPS" --expect-origin "$ORIGIN_URL" -- --dry-run --log /tmp/x.log 2>&1)"
rc=$?
[ "$rc" -eq 0 ] && ok "helper arguments are accepted" || no "helper arguments are accepted (exit $rc)"
if grep -q -- '--dry-run --log /tmp/x.log' "$BOOTSTRAP_TEST_MARKER"; then
	ok "the helper received the trailing arguments"
else
	no "the helper received the trailing arguments"
	printf '%s\n' "$(cat "$BOOTSTRAP_TEST_MARKER")" | sed 's/^/     | /'
fi

# dry run updates the checkout but does not run the helper
: > "$BOOTSTRAP_TEST_MARKER"
out="$(bash "$BOOTSTRAP" --ops-dir "$OPS" --expect-origin "$ORIGIN_URL" --dry-run 2>&1)"
rc=$?
[ "$rc" -eq 0 ] && ok "dry run succeeds" || no "dry run succeeds (exit $rc)"
[ ! -s "$BOOTSTRAP_TEST_MARKER" ] && ok "dry run did not run the helper" || no "dry run did not run the helper"

# a truncated download must never execute the helper: cut the file at several
# points and check the helper never runs
total="$(wc -c < "$BOOTSTRAP")"
for frac in 10 25 50 75 90 99; do
	cut=$((total * frac / 100))
	head -c "$cut" "$BOOTSTRAP" > "$TMP/truncated.sh"
	: > "$BOOTSTRAP_TEST_MARKER"
	out="$(bash "$TMP/truncated.sh" --ops-dir "$OPS" --expect-origin "$ORIGIN_URL" 2>&1)"
	rc=$?
	if [ -s "$BOOTSTRAP_TEST_MARKER" ]; then
		no "truncated bootstrap (${frac}%) ran the helper"
	else
		ok "truncated bootstrap (${frac}%) did not run the helper (exit $rc)"
	fi
done

# a file that ends just before the final main invocation is a partial EOF:
# it must fail, not exit 0 and look successful
mainline="$(grep -n '^main "\$@"$' "$BOOTSTRAP" | tail -1 | cut -d: -f1)"
if [ -n "$mainline" ]; then
	head -n $((mainline - 1)) "$BOOTSTRAP" > "$TMP/partial-eof.sh"
	: > "$BOOTSTRAP_TEST_MARKER"
	out="$(bash "$TMP/partial-eof.sh" --ops-dir "$OPS" --expect-origin "$ORIGIN_URL" 2>&1)"
	rc=$?
	[ "$rc" -ne 0 ] && ok "a partial EOF fails instead of reporting success (exit $rc)" \
		|| no "a partial EOF fails instead of reporting success (exit $rc)"
	[ ! -s "$BOOTSTRAP_TEST_MARKER" ] && ok "a partial EOF did not run the helper" \
		|| no "a partial EOF did not run the helper"
	contains "a partial EOF says why" "did not complete" "$out"
fi

# origin forms: https and ssh for the same repo match, a documented ssh alias
# is accepted when it resolves to the expected host, a different repo or an
# unknown host never is
mkdir -p "$HOME/.ssh"
cat > "$HOME/.ssh/config" <<'EOF'
Host github-skillshare
  HostName github.com
  User git
EOF
chmod 600 "$HOME/.ssh/config"

git -C "$OPS" remote set-url origin "https://github.com/owner/repo.git"
out="$(bash "$BOOTSTRAP" --ops-dir "$OPS" --expect-origin "git@github.com:owner/repo.git" 2>&1)"
rc=$?
[ "$rc" -ne 3 ] && ok "https and ssh forms of one repo match" || no "https and ssh forms of one repo match (exit $rc)"

git -C "$OPS" remote set-url origin "github-skillshare:owner/repo.git"
out="$(bash "$BOOTSTRAP" --ops-dir "$OPS" --expect-origin "git@github.com:owner/repo.git" 2>&1)"
rc=$?
[ "$rc" -ne 3 ] && ok "a documented ssh alias host is accepted" || no "a documented ssh alias host is accepted (exit $rc)"
contains "an alias host is reported" "resolves to" "$out"

git -C "$OPS" remote set-url origin "unknown-alias:owner/repo.git"
out="$(bash "$BOOTSTRAP" --ops-dir "$OPS" --expect-origin "git@github.com:owner/repo.git" 2>&1)"
rc=$?
[ "$rc" -eq 3 ] && ok "an unknown dotless host is refused" || no "an unknown dotless host is refused (exit $rc)"

git -C "$OPS" remote set-url origin "git@github.com:owner/other.git"
out="$(bash "$BOOTSTRAP" --ops-dir "$OPS" --expect-origin "git@github.com:owner/repo.git" 2>&1)"
rc=$?
[ "$rc" -eq 3 ] && ok "a different repo is refused" || no "a different repo is refused (exit $rc)"

git -C "$OPS" remote set-url origin "git@evil.example.com:owner/repo.git"
out="$(bash "$BOOTSTRAP" --ops-dir "$OPS" --expect-origin "git@github.com:owner/repo.git" 2>&1)"
rc=$?
[ "$rc" -eq 3 ] && ok "a different real host is refused" || no "a different real host is refused (exit $rc)"

git -C "$OPS" remote set-url origin "$ORIGIN_URL"

# a checkout that predates the helper must still be able to pull it: the
# helper check happens after the fast-forward, never before
git init --quiet --bare "$TMP/origin2.git"
git -C "$TMP/origin2.git" symbolic-ref HEAD refs/heads/main
git init --quiet "$TMP/work2"
git -C "$TMP/work2" symbolic-ref HEAD refs/heads/main
printf 'old checkout\n' > "$TMP/work2/README.md"
git -C "$TMP/work2" add -A
git -C "$TMP/work2" commit --quiet -m "before the helper existed"
old_sha="$(git -C "$TMP/work2" rev-parse HEAD)"
git -C "$TMP/work2" remote add origin "$TMP/origin2.git"
git -C "$TMP/work2" push --quiet origin HEAD:refs/heads/main
git clone --quiet "$TMP/origin2.git" "$HOME_DIR/src/ops2"
mkdir -p "$TMP/work2/scripts"
cp "$WORK/scripts/agent-workstation-refresh.sh" "$TMP/work2/scripts/agent-workstation-refresh.sh"
# the upstream commit must add every dependency the helper executes
for dep in agent-workstation-refresh.pins install-ponytail.sh install-unclebob-tools.sh \
	unclebob-tools-fixture.sh install-uml-viewer.sh; do
	printf '# stub %s\n' "$dep" > "$TMP/work2/scripts/$dep"
done
git -C "$TMP/work2" add -A
git -C "$TMP/work2" commit --quiet -m "add the helper and its dependencies"
git -C "$TMP/work2" push --quiet origin HEAD:refs/heads/main
# put the checkout back to the commit that has no helper
git -C "$HOME_DIR/src/ops2" reset --quiet --hard "$old_sha"
[ -f "$HOME_DIR/src/ops2/scripts/agent-workstation-refresh.sh" ] \
	&& no "the stale checkout has no helper yet" || ok "the stale checkout has no helper yet"
: > "$BOOTSTRAP_TEST_MARKER"
out="$(bash "$BOOTSTRAP" --ops-dir "$HOME_DIR/src/ops2" --expect-origin "$TMP/origin2.git" 2>&1)"
rc=$?
[ "$rc" -eq 0 ] && ok "a checkout without the helper pulls it and runs" || no "a checkout without the helper pulls it and runs (exit $rc)"
contains "the pulled helper reports DONE" "DONE" "$out"
if [ -s "$BOOTSTRAP_TEST_MARKER" ]; then
	ok "the helper pulled by the update ran"
else
	no "the helper pulled by the update ran"
fi

# The public entry must never reach another host. `ssh -G` only reads the
# local ssh config to resolve an alias (it connects to nothing); every other
# ssh/scp/rsync/pct use is a dispatch and is refused.
suspects="$(sed 's/#.*//' "$BOOTSTRAP" \
	| grep -nE '(^|[[:space:];|&(`])(ssh|scp|sftp|rsync|pct)([[:space:]]|$)' \
	| grep -v 'ssh[[:space:]]\+-G[[:space:]]')"
if [ -n "$suspects" ]; then
	no "bootstrap.sh contains another-host dispatch"
	printf '%s\n' "$suspects" | sed 's/^/     | /'
else
	ok "bootstrap.sh contains no other-host dispatch"
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
