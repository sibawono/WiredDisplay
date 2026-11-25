#!/bin/bash
# Prints the next free CHANGELOG ID. Run it right before adding an entry: sessions in parallel collided before.
set -euo pipefail
cd "$(dirname "$0")/.."
last="$(grep -oE '^## CHANGE ID: P1-[0-9]+' docs/CHANGELOG.md | grep -oE '[0-9]+$' | sort -n | tail -1)"
printf 'P1-%03d\n' $((10#$last + 1))
