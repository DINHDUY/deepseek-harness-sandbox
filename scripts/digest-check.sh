#!/bin/sh
set -eu

# Verify the Containerfile base-image digest pin against the registry.
#
# Two earlier approaches were wrong:
#   - `image inspect` reads the local cache, so a long-lived local copy is
#     reported as current even when the tag has moved on.
#   - even after a fresh pull, `image inspect` reports the digest of the
#     *platform-specific child* manifest, while the Containerfile pins the
#     multi-arch *index* digest. Comparing the two always looks stale.
# So ask the registry for the manifest-list digest directly: no local state,
# no pull, and the same answer on every architecture.
#
# Usage: digest-check.sh [CONTAINERFILE]
#   BASE_IMAGE=...  image whose pin to check (default: docker.io/library/node:24-slim)

CONTAINERFILE=${1:-Containerfile}
BASE_IMAGE=${BASE_IMAGE:-docker.io/library/node:24-slim}

[ -f "$CONTAINERFILE" ] || { echo "no such Containerfile: $CONTAINERFILE" >&2; exit 2; }

# The pin is the "@sha256:..." suffix on the FROM/ARG default for this image.
# Fixed-string matching avoids escaping the image name inside a regex.
pin=$(grep -F "$BASE_IMAGE@" "$CONTAINERFILE" |
    sed -n 's|.*@\(sha256:[0-9a-f]\{64\}\).*|\1|p' | head -1)
if [ -z "$pin" ]; then
    echo "$BASE_IMAGE: $CONTAINERFILE has no digest pin for this image" >&2
    exit 1
fi

# docker.io/library/node:24-slim -> registry docker.io, repo library/node, tag 24-slim
case "$BASE_IMAGE" in
    */*/*) registry=${BASE_IMAGE%%/*}; rest=${BASE_IMAGE#*/} ;;
    *)     registry=docker.io;       rest=$BASE_IMAGE ;;
esac
repo=${rest%:*}
tag=${rest##*:}
[ "$tag" != "$rest" ] || { echo "BASE_IMAGE has no tag: $BASE_IMAGE" >&2; exit 2; }

api=https://$registry
[ "$registry" = docker.io ] && api=https://registry-1.docker.io

# Docker Hub needs a bearer token for the manifest endpoint; other registries
# used here accept an anonymous request.
auth=""
if [ "$registry" = docker.io ]; then
    token=$(curl -fsS "https://auth.docker.io/token?service=registry.docker.io&scope=repository:$repo:pull" |
        sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
    [ -n "$token" ] || { echo "$BASE_IMAGE: could not obtain a registry token" >&2; exit 1; }
    auth="Authorization: Bearer $token"
fi

# Ask for an index/manifest-list explicitly so the registry returns the digest we
# actually pin, then read it back from the Docker-Content-Digest header.
accept="application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json"
hdr=$(curl -fsS -D - -o /dev/null -H "$auth" -H "Accept: $accept" "$api/v2/$repo/manifests/$tag") || {
    echo "$BASE_IMAGE: registry request failed; cannot verify the pin" >&2
    exit 1
}
live=$(printf '%s' "$hdr" | tr -d '\r' | sed -n 's/^[Dd]ocker-[Cc]ontent-[Dd]igest: *\(sha256:[0-9a-f]\{64\}\).*/\1/p' | head -1)
if [ -z "$live" ]; then
    echo "$BASE_IMAGE: registry returned no manifest digest; cannot verify the pin" >&2
    exit 1
fi

echo "$BASE_IMAGE"
echo "  Containerfile pin: $pin"
echo "  live tag digest:   $live"
if [ "$pin" != "$live" ]; then
    echo "  STALE: update the pin in $CONTAINERFILE to $live" >&2
    exit 1
fi
echo "  current"
