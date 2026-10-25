#!/usr/bin/env bash
set -eu
ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
printf '#!/bin/sh\nexit 23\n' > "$TMP/curl"
chmod +x "$TMP/curl"
if PATH="$TMP:$PATH" bash "$ROOT/esper.sh"; then
    echo 'FAIL: failed download was accepted' >&2
    exit 1
else
    [ "$?" -eq 23 ]
fi
printf 'pass: Esper launcher stops on a failed download\n'
