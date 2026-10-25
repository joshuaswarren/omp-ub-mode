#!/usr/bin/env bash
# omp-ub-mode bootstrap — public entry point for an operator workstation.
#
# What it does, in order:
#   1. validate the operator's own checkout of the ops repository
#      (exists, is the root of a git checkout, lives under the invoking
#       user's home, its origin matches --expect-origin)
#   2. update to current origin/main, fetched by explicit refspec and
#      executed only from the fetched commit:
#        - on main: fast-forward in place (fetch + merge --ff-only only:
#          no stash, no reset, no force, no discard of local work)
#        - on any other branch or a detached HEAD: leave that checkout
#          untouched and run from a temporary isolated detached worktree
#          at the fetched commit, under the invoking user's home
#   3. run the repository's refresh helper, and report its exit status
#
# What it never does: clone anything, authenticate as anyone, carry a
# credential, touch another host, run a helper from a repository that
# does not match the expected origin, or modify a non-main checkout's
# HEAD, index, or untracked files. The checkout's own git credentials
# are used as-is; this file contains none.
#
# Exit codes: 0 ok | 2 usage | 3 validation | 4 update | 5 helper failed
#
# All definitions come first and the single main invocation comes last, so
# a truncated download can only ever stop the helper from running — it can
# never run a half-written helper.
set -uo pipefail

# A truncated download must never look like a success. If this entry point
# exits 0 without having finished its work, that is a partial file, not a
# completed run: fail loudly instead. The EXIT trap also removes the
# isolated worktree and never changes the run's exit status.
__bootstrap_done=0
__bootstrap_finish() {
	rc=$?
	type -t cleanup_worktree >/dev/null 2>&1 && cleanup_worktree
	if [ "$rc" -eq 0 ] && [ "$__bootstrap_done" -ne 1 ]; then
		printf 'bootstrap: entry point did not complete (truncated download?)\n' >&2
		rc=3
	fi
	exit "$rc"
}
trap __bootstrap_finish EXIT

OPS_DIR=""
EXPECT_ORIGIN=""
HELPER_REL="scripts/agent-workstation-refresh.sh"
DRY_RUN=0
EXTRA_ARGS=()
USER_OPS_DIR=""
WORKTREE_DIR=""
WORKTREE_PARENT=""
UP_TARGET=""
HOME_REAL=""

usage() {
	__bootstrap_done=1
	cat <<'EOF'
Usage: bootstrap.sh --ops-dir PATH --expect-origin URL [--helper RELPATH] [--dry-run]

  --ops-dir PATH       existing checkout of the operator's ops repository
                       (must exist already; this script never clones)
  --expect-origin URL  git origin that checkout is required to have
                       (e.g. git@github.com:owner/repo.git)
  --helper RELPATH     refresh helper inside the checkout
                       (default: scripts/agent-workstation-refresh.sh)
  --dry-run            update, do not run the helper
  -h, --help           show this help

Anything after -- is passed to the helper unchanged:
  bootstrap.sh --ops-dir ... --expect-origin ... -- --dry-run
EOF
}

log() { printf 'bootstrap: %s\n' "$*"; }
err() { printf 'bootstrap: %s\n' "$*" >&2; }

fail_usage() { err "$*"; usage >&2; exit 2; }
fail_check() { err "$*"; exit 3; }
fail_update() { err "$*"; exit 4; }

# --- argument parsing -------------------------------------------------------

parse_args() {
	while [ $# -gt 0 ]; do
		case "$1" in
			--ops-dir)
				[ $# -ge 2 ] || fail_usage "--ops-dir needs a path"
				OPS_DIR="$2"; shift 2 ;;
			--ops-dir=*)
				OPS_DIR="${1#--ops-dir=}"; shift ;;
			--expect-origin)
				[ $# -ge 2 ] || fail_usage "--expect-origin needs a url"
				EXPECT_ORIGIN="$2"; shift 2 ;;
			--expect-origin=*)
				EXPECT_ORIGIN="${1#--expect-origin=}"; shift ;;
			--helper)
				[ $# -ge 2 ] || fail_usage "--helper needs a path"
				HELPER_REL="$2"; shift 2 ;;
			--helper=*)
				HELPER_REL="${1#--helper=}"; shift ;;
			--dry-run)
				DRY_RUN=1; shift ;;
			-h|--help)
				usage; exit 0 ;;
			--)
				shift
				EXTRA_ARGS=("$@")
				break ;;
			*)
				fail_usage "unknown argument: $1" ;;
		esac
	done
	[ -n "$OPS_DIR" ] || fail_usage "--ops-dir is required"
	[ -n "$EXPECT_ORIGIN" ] || fail_usage "--expect-origin is required"
	case "$HELPER_REL" in
		/*|*..*) fail_usage "--helper must be a relative path inside the checkout" ;;
	esac
}

# --- helpers ----------------------------------------------------------------

# git@github.com:owner/repo.git | https://github.com/owner/repo
# | https://user:token@github.com/owner/repo | ssh://git@github.com/owner/repo
# | github-skillshare:owner/repo -> host/path; any userinfo in the URL is
# stripped first so host and path can never carry credentials.
normalize_origin() {
	printf '%s' "$1" \
	| sed -e 's#^[a-zA-Z+]*://##' -e 's#^[^/@]*@##' -e 's#\.git$##' -e 's#/*$##' -e 's#:#/#' \
	| tr '[:upper:]' '[:lower:]'
}

# Never print credentials that may live in a remote URL.
redact_origin() {
	printf '%s' "$1" | sed -e 's#^[^@/]*@##' -e 's#://[^@/]*@#://#'
}

origin_host() { printf '%s' "$1" | cut -d/ -f1; }
origin_path() { printf '%s' "$1" | cut -d/ -f2-; }

# The effective hostname of a host or ssh alias, resolved from the local ssh
# config WITHOUT connecting. A dotless name is never trusted on its own: it
# only counts when it resolves to the expected host.
resolve_host() {
	h="$1"
	if command -v ssh >/dev/null 2>&1; then
		r="$(ssh -G "$h" 2>/dev/null | awk '$1 == "hostname" { print $2; exit }')"
		if [ -n "$r" ]; then
			printf '%s\n' "$r" | tr '[:upper:]' '[:lower:]'
			return 0
		fi
	fi
	printf '%s\n' "$h" | tr '[:upper:]' '[:lower:]'
}

git_in() { git -C "$OPS_DIR" "$@"; }

# --- validation -------------------------------------------------------------

validate_repo() {
	[ -n "$OPS_DIR" ] || fail_check "--ops-dir is empty"
	[ -d "$OPS_DIR" ] || fail_check "ops dir does not exist: $OPS_DIR"
	OPS_DIR="$(cd "$OPS_DIR" 2>/dev/null && pwd -P)" \
		|| fail_check "ops dir is not reachable: $OPS_DIR"

	# user path: the checkout must belong to the invoking user and live
	# under their home directory, not somewhere else on the machine.
	HOME_REAL="$(cd "$HOME" 2>/dev/null && pwd -P)" || fail_check "HOME is not set"
	case "$OPS_DIR" in
		"$HOME_REAL"/*) : ;;
		*) fail_check "ops dir is outside \$HOME ($HOME_REAL): $OPS_DIR" ;;
	esac
	owner="$(stat -c '%u' "$OPS_DIR" 2>/dev/null || stat -f '%u' "$OPS_DIR" 2>/dev/null || echo "")"
	if [ -n "$owner" ] && [ "$owner" != "$(id -u)" ]; then
		fail_check "ops dir is owned by uid $owner, not by the invoking user: $OPS_DIR"
	fi

	# the ops dir must be the root of its own checkout: git commands run
	# against a nested path would silently operate on the parent repository.
	toplevel="$(git_in rev-parse --show-toplevel 2>/dev/null || true)"
	[ -n "$toplevel" ] \
		|| fail_check "ops dir is not a git checkout: $OPS_DIR"
	[ "$toplevel" = "$OPS_DIR" ] \
		|| fail_check "ops dir is inside another git checkout ($toplevel), not a checkout root: $OPS_DIR"
}

# The helper may only exist in the commit this bootstrap is about to fetch,
# so it is checked after the update, not before.
validate_helper() {
	[ -f "$OPS_DIR/$HELPER_REL" ] \
		|| fail_check "helper not found in the updated checkout: $HELPER_REL"
	git_in ls-files --error-unmatch -- "$HELPER_REL" >/dev/null 2>&1 \
		|| fail_check "helper is not tracked by git in the checkout: $HELPER_REL"
	git_in diff --quiet HEAD -- "$HELPER_REL" \
		|| fail_check "helper differs from HEAD (locally modified): $HELPER_REL"
}

validate_origin() {
	origin="$(git_in remote get-url origin 2>/dev/null || true)"
	[ -n "$origin" ] || fail_check "checkout has no 'origin' remote: $OPS_DIR"
	want="$(normalize_origin "$EXPECT_ORIGIN")"
	got="$(normalize_origin "$origin")"
	want_host="$(origin_host "$want")"
	want_path="$(origin_path "$want")"
	got_host="$(origin_host "$got")"
	got_path="$(origin_path "$got")"

	[ -n "$got_path" ] && [ "$got_path" = "$want_path" ] \
		|| fail_check "origin mismatch: checkout has '$(redact_origin "$origin")' (repo '$got_path'), expected '$(redact_origin "$EXPECT_ORIGIN")' (repo '$want_path')"

	if [ "$got_host" != "$want_host" ]; then
		got_resolved="$(resolve_host "$got_host")"
		want_resolved="$(resolve_host "$want_host")"
		if [ "$got_resolved" = "$want_resolved" ]; then
			log "origin host '$got_host' resolves to '$got_resolved' (same as '$want_host'): repo path '$got_path' verified"
		else
			fail_check "origin mismatch: checkout points at host '$got_host' (resolves to '$got_resolved'), expected '$want_host' (resolves to '$want_resolved')"
		fi
	fi
	log "origin verified: $(redact_origin "$origin") (repo $got_path)"
}

# --- update -----------------------------------------------------------------

# Every file the helper will execute has to come from the reviewed tree:
# tracked by git and identical to HEAD. A local edit anywhere in that set is
# refused before the helper runs.
DEPENDENCIES="scripts/agent-workstation-refresh.pins
scripts/install-ponytail.sh
scripts/install-unclebob-tools.sh
scripts/unclebob-tools-fixture.sh
scripts/install-uml-viewer.sh"

validate_dependencies() {
	for dep in "$HELPER_REL" $DEPENDENCIES; do
		git_in ls-files --error-unmatch -- "$dep" >/dev/null 2>&1 \
			|| fail_update "dependency is not tracked by git in the checkout: $dep"
		git_in diff --quiet HEAD -- "$dep" \
			|| fail_update "dependency differs from HEAD (locally modified): $dep"
	done
	log "dependencies verified: tracked and unmodified"
}

# Fetch exactly refs/heads/main by explicit refspec (local remote.fetch
# settings cannot leave a stale tracking ref in play) and resolve the
# fetched commit from FETCH_HEAD: the immutable SHA this run just verified,
# never an assumed tracking ref.
fetch_main() {
	git_in fetch --quiet --no-tags origin '+refs/heads/main:refs/remotes/origin/main' || return 1
	UP_TARGET="$(git_in rev-parse --verify 'FETCH_HEAD^{commit}' 2>/dev/null)" || return 1
}

# Fast-forward only, on main only. A diverged or conflicted checkout is
# reported and left exactly as it was: no stash, no reset, no force, no
# discarding local work.
update_checkout() {
	log "updating checkout on branch main"
	fetch_main || fail_update "git fetch origin main failed (no changes were made)"
	if ! git_in merge --ff-only "$UP_TARGET"; then
		fail_update "fast-forward to origin/main failed: the checkout has local commits or conflicts; resolve it by hand (nothing was reset, stashed or discarded)"
	fi
	log "checkout updated to $(git_in rev-parse --short HEAD)"
}

# Anywhere but main — a feature branch ahead of main, staged, unstaged or
# untracked work, or a detached HEAD — the checkout is never switched,
# merged, stashed or reset. The fetched origin/main commit is materialized
# in a temporary detached worktree under $HOME instead; the helper runs from
# there and the checkout keeps every byte of its state. A dirty helper in
# the source branch cannot be executed and cannot block: only the pristine
# worktree tree is validated and run.
update_worktree() {
	if [ -n "$1" ]; then
		log "checkout is on branch '$1'; leaving it untouched and running from origin/main in an isolated worktree"
	else
		log "checkout is in a detached HEAD state; leaving it untouched and running from origin/main in an isolated worktree"
	fi
	USER_OPS_DIR="$OPS_DIR"
	fetch_main || fail_update "git fetch origin main failed (no changes were made)"
	WORKTREE_PARENT="$(mktemp -d "$HOME_REAL/.bootstrap-worktree.XXXXXX")" \
		|| fail_update "cannot create an isolated worktree directory under \$HOME ($HOME_REAL)"
	WORKTREE_DIR="$WORKTREE_PARENT/worktree"
	if ! git_in worktree add --quiet --detach "$WORKTREE_DIR" "$UP_TARGET" >/dev/null 2>&1; then
		rmdir "$WORKTREE_PARENT" 2>/dev/null
		if [ -d "$WORKTREE_PARENT" ]; then
			fail_update "git worktree add failed for the fetched commit; leftover directory kept for inspection: $WORKTREE_PARENT"
		fi
		WORKTREE_PARENT=""
		WORKTREE_DIR=""
		fail_update "git worktree add failed for the fetched commit"
	fi
	OPS_DIR="$WORKTREE_DIR"
	# Trust checks after the switch: the executed tree must be a checkout
	# root in its own right, exactly the fetched commit, and pristine.
	[ "$(git_in rev-parse --show-toplevel 2>/dev/null)" = "$WORKTREE_DIR" ] \
		|| fail_update "isolated worktree is not a checkout root: $WORKTREE_DIR"
	[ "$(git_in rev-parse --verify 'HEAD^{commit}' 2>/dev/null)" = "$UP_TARGET" ] \
		|| fail_update "isolated worktree is not at the fetched commit"
	[ -z "$(git_in status --porcelain 2>/dev/null)" ] \
		|| fail_update "isolated worktree is not pristine"
	validate_helper
	validate_dependencies
	log "isolated worktree verified at $(git_in rev-parse --short HEAD)"
}

# Remove the isolated worktree. Plain removal deletes ignored files too, so
# it happens only when the worktree holds nothing outside the fetched tree
# at all — uncommitted or ignored — and its status can be read. Anything
# else is kept and its path reported instead of destroying it. Runs from
# the EXIT trap and must never change the run's exit status or mask the
# original failure.
cleanup_worktree() {
	[ -n "$WORKTREE_DIR" ] || return 0
	wt_dirty=1
	if wt_out="$(git -C "$WORKTREE_DIR" status --porcelain --ignored 2>/dev/null)"; then
		[ -z "$wt_out" ] && wt_dirty=0
	fi
	if [ "$wt_dirty" -eq 0 ] \
		&& git -C "$USER_OPS_DIR" worktree remove "$WORKTREE_DIR" >/dev/null 2>&1; then
		rmdir "$WORKTREE_PARENT" 2>/dev/null
	else
		err "bootstrap: the isolated worktree at $WORKTREE_DIR was kept for inspection (uncommitted, ignored, or unreadable status): commit or move anything worth keeping inside it, then remove it"
	fi
	WORKTREE_DIR=""
	WORKTREE_PARENT=""
}

# --- helper -----------------------------------------------------------------

run_helper() {
	log "running helper: $HELPER_REL"
	if [ "${#EXTRA_ARGS[@]}" -gt 0 ]; then
		# the count only: arguments can carry secrets
		log "passing ${#EXTRA_ARGS[@]} argument(s) to the helper"
		bash "$OPS_DIR/$HELPER_REL" "${EXTRA_ARGS[@]}"
	else
		bash "$OPS_DIR/$HELPER_REL"
	fi
	rc=$?
	if [ "$rc" -ne 0 ]; then
		err "helper failed with exit status $rc"
		exit 5
	fi
}

main() {
	parse_args "$@"
	validate_repo
	validate_origin
	branch="$(git_in symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
	if [ "$branch" = "main" ]; then
		update_checkout
		validate_helper
		validate_dependencies
	else
		update_worktree "$branch"
	fi
	if [ "$DRY_RUN" -eq 1 ]; then
		log "dry run: helper not executed"
	else
		run_helper
	fi
	__bootstrap_done=1
	log "DONE"
}

main "$@"
