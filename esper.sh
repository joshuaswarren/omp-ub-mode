#!/usr/bin/env bash
# Esper preset: the pinned bootstrap still validates the checkout and every dependency.
(set -eu; f=$(mktemp); trap 'rm -f "$f"' EXIT; curl -fsSL https://raw.githubusercontent.com/joshuaswarren/omp-ub-mode/96585fa9c902321c2e438dea85c0aac333ba2866/bootstrap.sh -o "$f"; printf '%s  %s\n' ef07982916446c094aee0126eca1cb93dc93180900a626e7b32f632bfd2902ae "$f" | sha256sum -c -; bash "$f" --ops-dir "$HOME/src/homelab-infra" --expect-origin git@github.com:joshuaswarren/homelab-infra.git)
