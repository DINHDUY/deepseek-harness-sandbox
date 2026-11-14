#!/bin/sh
set -eu

# Reconcile a podman network's static routes against the declared egress policy.
#
# podman only accepts --route at create time: routes are never updated in place.
# The Makefile targets used to guard creation with `network exists ||`, so a
# network created under an older BLOCKED_SUBNETS/ALLOWED_HOSTS list was reused
# forever and the declared policy silently stopped matching reality. This script
# compares the live routes to the declared ones and recreates the network when
# they differ, so a stale network can never be used by accident.
#
# Usage: net-reconcile.sh NAME SUBNET GATEWAY "BLOCKED SUBNETS" "ALLOWED HOSTS"
#   CHECK_ONLY=1  report drift and exit non-zero instead of recreating
#   PODMAN=...    podman binary to use

usage() {
    echo "usage: net-reconcile.sh NAME SUBNET GATEWAY BLOCKED ALLOWED" >&2
    exit 2
}

[ "$#" -eq 5 ] || usage

NAME=$1
SUBNET=$2
GATEWAY=$3
BLOCKED=$4
ALLOWED=$5
PODMAN=${PODMAN:-podman}
CHECK_ONLY=${CHECK_ONLY:-0}

# Everything below is word-split on purpose, so reject anything that could break
# out of the route syntax or the shell before it is ever expanded.
case "$NAME" in *[!0-9a-zA-Z._-]* | "" | .* | *. ) echo "invalid network name: $NAME" >&2; exit 2 ;; esac
for v in "$SUBNET" "$GATEWAY"; do
    case "$v" in *[!0-9./]* | "" | */*/*) echo "invalid subnet/gateway: $v" >&2; exit 2 ;; esac
done
for h in $ALLOWED; do
    case "$h" in *[!0-9a-zA-Z._-]*) echo "invalid host: $h" >&2; exit 2 ;; esac
done
for s in $BLOCKED; do
    case "$s" in *[!0-9./]* | "" | */*/*) echo "invalid blocked subnet: $s" >&2; exit 2 ;; esac
done

# Normalise both sides to the same sorted "dest:type[:gateway]" token list. The
# connected route for the network's own subnet is not part of .Routes, so it is
# correctly absent from both.
normalise() {
    printf '%s\n' "$1" | tr ' ' '\n' | sed '/^$/d' | LC_ALL=C sort | tr '\n' ' '
}

want=$(normalise "$(
    for s in $BLOCKED; do printf '%s:blackhole ' "$s"; done
    for h in $ALLOWED; do printf '%s/32:unicast:%s ' "$h" "$GATEWAY"; done
)")

create() {
    # Word splitting is intentional and safe: every token passed the charset
    # checks above, and podman needs repeated --route flags, not one quoted list.
    args=""
    for s in $BLOCKED; do args="$args --route $s,blackhole"; done
    for h in $ALLOWED; do args="$args --route $h/32,$GATEWAY"; done
    # shellcheck disable=SC2086
    "$PODMAN" network create --subnet "$SUBNET" --gateway "$GATEWAY" $args "$NAME" >/dev/null
    echo "$NAME: created with $(printf '%s' "$want" | wc -w | tr -d ' ') egress routes"
}

if ! "$PODMAN" network exists "$NAME"; then
    create
    exit 0
fi

live=$(normalise "$("$PODMAN" network inspect "$NAME" \
    --format '{{range .Routes}}{{.Destination}}:{{.RouteType}}{{if .Gateway}}:{{.Gateway}}{{end}} {{end}}' 2>/dev/null)")

if [ "$live" = "$want" ]; then
    echo "$NAME: egress routes match the declared policy"
    exit 0
fi

echo "$NAME: egress routes do NOT match the declared policy" >&2
echo "  declared: $want" >&2
echo "  live:     $live" >&2

if [ "$CHECK_ONLY" = 1 ]; then
    echo "  drift detected (CHECK_ONLY=1); run the network target to recreate it" >&2
    exit 1
fi

attached=$("$PODMAN" ps -aq --filter "network=$NAME")
if [ -n "$attached" ]; then
    echo "  containers are still attached: $attached" >&2
    echo "  stop them first (make sandbox-stop / make quadlet-stop / make down), then re-run" >&2
    exit 1
fi

echo "  recreating with the declared policy" >&2
"$PODMAN" network rm "$NAME" >/dev/null
create
