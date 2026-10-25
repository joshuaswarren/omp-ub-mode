#!/usr/bin/env bash
# omp-ub-mode bootstrap — public entry point for an operator workstation.
#
# What it does, in order:
#   1. validate the operator's own checkout of the ops repository
#      (exists, is a git checkout, lives under the invoking user's home,
#       its origin matches --expect-origin, the helper is tracked and clean)
#   2. fast-forward that checkout (fetch + merge --ff-only only:
#      no stash, no reset, no force, no discard of local work)
#   3. run the repository's refresh helper, and report its exit status
#
# What it never does: clone anything, authenticate as anyone, carry a
# credential, touch another host, or run a helper from a repository that
# does not match the expected origin. The checkout's own git credentials
# are used as-is; this file contains none.
#
# Exit codes: 0 ok | 2 usage | 3 validation | 4 update | 5 helper failed
#
# All definitions come first and the single main invocation comes last, so
# a truncated download can only ever stop the helper from running — it can
# never run a half-written helper.
set -uo pipefail

OPS_DIR=""
EXPECT_ORIGIN=""
HELPER_REL="scripts/agent-workstation-refresh.sh"
DRY_RUN=0
EXTRA_ARGS=""

usage() {
	cat <<'EOF'
Usage: bootstrap.sh --ops-dir PATH --expect-origin URL [--helper RELPATH] [--dry-run]

  --ops-dir PATH       existing checkout of the operator's ops repository
                       (must exist already; this script never clones)
  --expect-origin URL  git origin that checkout is required to have
                       (e.g. git@github.com:owner/repo.git)
  --helper RELPATH     refresh helper inside the checkout
                       (default: scripts/agent-workstation-refresh.sh)
  --dry-run            update the checkout, do not run the helper
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
				EXTRA_ARGS="$*"
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

# git@github.com:owner/repo.git | https://github.com/owner/repo -> github.com/owner/repo
normalize_origin() {
	printf '%s' "$1" \
	| sed -e 's#\.git$##' -e 's#^git@##' -e 's#^ssh://##' -e 's#^https\?://##' \
	      -e 's#^git://##' -e 's#:#/#' \
	| tr '[:upper:]' '[:lower:]'
}

git_in() { git -C "$OPS_DIR" "$@"; }

# --- validation -------------------------------------------------------------

validate_ops_dir() {
	[ -n "$OPS_DIR" ] || fail_check "--ops-dir is empty"
	[ -d "$OPS_DIR" ] || fail_check "ops dir does not exist: $OPS_DIR"
	OPS_DIR="$(cd "$OPS_DIR" 2>/dev/null && pwd -P)" \
		|| fail_check "ops dir is not reachable: $OPS_DIR"

	# user path: the checkout must belong to the invoking user and live
	# under their home directory, not somewhere else on the machine.
	home_real="$(cd "$HOME" 2>/dev/null && pwd -P)" || fail_check "HOME is not set"
	case "$OPS_DIR" in
		"$home_real"/*) : ;;
		*) fail_check "ops dir is outside \$HOME ($home_real): $OPS_DIR" ;;
	esac
	owner="$(stat -c '%u' "$OPS_DIR" 2>/dev/null || stat -f '%u' "$OPS_DIR" 2>/dev/null || echo "")"
	if [ -n "$owner" ] && [ "$owner" != "$(id -u)" ]; then
		fail_check "ops dir is owned by uid $owner, not by the invoking user: $OPS_DIR"
	fi

	git_in rev-parse --is-inside-work-tree >/dev/null 2>&1 \
		|| fail_check "ops dir is not a git checkout: $OPS_DIR"

	[ -f "$OPS_DIR/$HELPER_REL" ] \
		|| fail_check "helper not found in checkout: $HELPER_REL"
	git_in ls-files --error-unmatch -- "$HELPER_REL" >/dev/null 2>&1 \
		|| fail_check "helper is not tracked by git in the checkout: $HELPER_REL"
}

validate_origin() {
	origin="$(git_in remote get-url origin 2>/dev/null || true)"
	[ -n "$origin" ] || fail_check "checkout has no 'origin' remote: $OPS_DIR"
	want="$(normalize_origin "$EXPECT_ORIGIN")"
	got="$(normalize_origin "$origin")"
	if [ "$got" != "$want" ]; then
		fail_check "origin mismatch: checkout has '$origin' (normalized '$got'), expected '$EXPECT_ORIGIN' (normalized '$want')"
	fi
	log "origin verified: $origin"
}

# --- update -----------------------------------------------------------------

# Fast-forward only. A diverged or conflicted checkout is reported and left
# exactly as it was: no stash, no reset, no force, no discarding local work.
update_checkout() {
	branch="$(git_in symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
	if [ -z "$branch" ]; then
		fail_update "checkout is in a detached HEAD state; check it out on a branch first"
	fi
	log "updating checkout on branch $branch"
	if ! git_in fetch --quiet origin "$branch"; then
		fail_update "git fetch origin $branch failed (no changes were made)"
	fi
	if ! git_in merge --ff-only "origin/$branch"; then
		fail_update "fast-forward to origin/$branch failed: the checkout has local commits or conflicts; resolve it by hand (nothing was reset, stashed or discarded)"
	fi
	if ! git_in diff --quiet HEAD -- "$HELPER_REL"; then
		fail_update "helper differs from HEAD after the update (locally modified): $HELPER_REL"
	fi
	log "checkout updated to $(git_in rev-parse --short HEAD)"
}

# --- helper -----------------------------------------------------------------

run_helper() {
	log "running helper: $HELPER_REL"
	if [ -n "$EXTRA_ARGS" ]; then
		log "helper arguments: $EXTRA_ARGS"
		# shellcheck disable=SC2086
		bash "$OPS_DIR/$HELPER_REL" $EXTRA_ARGS
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
	validate_ops_dir
	validate_origin
	update_checkout
	if [ "$DRY_RUN" -eq 1 ]; then
		log "dry run: helper not executed"
	else
		run_helper
	fi
	log "DONE"
}

main "$@"
