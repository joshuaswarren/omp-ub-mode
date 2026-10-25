#!/usr/bin/env bash
# Esper preset: the pinned bootstrap still validates the checkout and every dependency.
(set -eu; f=$(mktemp); trap 'rm -f "$f"' EXIT; curl -fsSL https://raw.githubusercontent.com/joshuaswarren/omp-ub-mode/4279b2c28ccbf03ec76b4af465b87a4275604c4e/bootstrap.sh -o "$f"; printf '%s  %s\n' 007fa121ceb0f282c346fc2e2564f79faa463bcd10ed574cf414661696fa9fe5 "$f" | sha256sum -c -; bash "$f" --ops-dir "$HOME/src/homelab-infra" --expect-origin git@github.com:joshuaswarren/homelab-infra.git)
