#!/bin/sh
set -eu

# podman-compose.yml declares its egress blackholes in YAML while the Makefile
# declares BLOCKED_SUBNETS for the CLI paths. Two copies of one policy drift.
# This asserts the compose file's blackhole set is exactly the Makefile's, so a
# change to one cannot silently miss the other.
#
# Usage: compose-routes-check.sh "BLOCKED SUBNETS" [COMPOSE_FILE]

BLOCKED=${1:-}
COMPOSE_FILE=${2:-podman-compose.yml}
[ -f "$COMPOSE_FILE" ] || { echo "no such file: $COMPOSE_FILE" >&2; exit 2; }

normalise() { printf '%s\n' "$1" | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort | tr '\n' ' '; }

want=$(normalise "$BLOCKED")
# Only the blackhole entries: the compose file also carries its own gateway
# routes for ALLOWED_HOSTS, which the Makefile generates from its own variable.
live=$(normalise "$(sed -n 's/^ *- *\([0-9.]*\/[0-9]*\),blackhole *$/\1/p' "$COMPOSE_FILE")")

echo "  Makefile BLOCKED_SUBNETS: $want"
echo "  $COMPOSE_FILE blackholes: $live"
if [ "$want" != "$live" ]; then
    echo "  MISMATCH: keep the compose x-podman.routes list in sync with BLOCKED_SUBNETS" >&2
    exit 1
fi
echo "  in sync"
