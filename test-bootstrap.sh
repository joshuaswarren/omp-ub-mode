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
[ "$rc" -eq 4 ] && ok "modified helper fails the update" || no "modified helper fails the update (exit $rc)"
[ ! -s "$BOOTSTRAP_TEST_MARKER" ] && ok "modified helper was not executed" || no "modified helper was not executed"
git -C "$OPS" checkout --quiet -- scripts/agent-workstation-refresh.sh

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
for frac in 10 25 50 75 90; do
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

# the public entry must never reach another host
if grep -Eq '(^|[^[:alnum:]_])(ssh|scp|sftp|rsync|pct)([[:space:]]|$)' "$BOOTSTRAP"; then
	no "bootstrap.sh contains another-host dispatch"
else
	ok "bootstrap.sh contains no other-host dispatch"
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
