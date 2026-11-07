#!/bin/sh
set -eu

# `dsh web` rejects wildcard bind addresses, so bind to the container's own interface IP.
# The IP comes from scripts/container-ip.mjs, which exits non-zero when no usable address
# exists. We verify the value too, so an empty or wildcard IP can never reach --host.
DSH_IP_HELPER="${DSH_IP_HELPER:-/usr/local/lib/container-ip.mjs}"

valid_ip() {
    # Structural guard only (the helper does the authoritative validation). The
    # image's awk is mawk, which lacks interval regexes, so stick to POSIX case
    # patterns: reject empty, wildcard, loopback, and anything not made of
    # digits and dots forming exactly four fields.
    case "$1" in
        ""|0.0.0.0|127.*|*[!0-9.]*|.*|*.|*..*) return 1 ;;
    esac
    dots=$(printf '%s' "$1" | tr -cd . | wc -c)
    [ "$dots" -eq 3 ]
}

mkdir -p "${DSH_HOME}"

if [ "${1:-}" = "web" ]; then
    shift
    ip="$(node "${DSH_IP_HELPER}")" || {
        echo "entrypoint: could not determine container IP; refusing to start" >&2
        exit 1
    }
    if ! valid_ip "$ip"; then
        echo "entrypoint: refusing to bind invalid host '${ip}'" >&2
        exit 1
    fi
    exec dsh web --no-open --host "$ip" --port "${DSH_WEB_PORT:-8080}" "$@"
fi

exec dsh "$@"
