# syntax=docker.io/docker/dockerfile:1

# Pinned by content digest (multi-arch index: linux/amd64 + linux/arm64).
# Bump deliberately: `make digest-check` prints the current tag digests.
ARG NODE_IMAGE=docker.io/library/node:24-slim@sha256:01d566e8d94d8c619591d78652babfccd3c6992a3dffa9ed5ab39e11cf6c70e9

# ---------------------------------------------------------------------------
# Stage 1: resolve dependencies from the lockfile only. No scripts run, so a
# compromised dependency cannot execute during the build. node-pty and koffi
# ship prebuilt binaries for every platform, so nothing needs to be compiled.
# ---------------------------------------------------------------------------
FROM ${NODE_IMAGE} AS deps

WORKDIR /build

COPY package.json package-lock.json ./

ENV NPM_CONFIG_UPDATE_NOTIFIER=false \
    NPM_CONFIG_FUND=false \
    NPM_CONFIG_AUDIT=false

RUN npm ci --omit=dev --ignore-scripts

# ---------------------------------------------------------------------------
# Stage 2: runtime. Only node_modules and the generated bin shim are copied,
# so build-time provenance (and any tampered copy) does not persist.
# ---------------------------------------------------------------------------
FROM ${NODE_IMAGE} AS runtime

ARG DSH_VERSION=0.2.2-rc.1
# Defaults are fallbacks only: `make build` passes VCS_REF from git and
# BUILD_DATE from the clock, and derives DSH_VERSION from package.json so the
# label cannot drift from what the lockfile installs.
ARG BUILD_DATE=1970-01-01T00:00:00Z
ARG VCS_REF=unknown

LABEL org.opencontainers.image.title="deepseek-harness-sandbox" \
      org.opencontainers.image.description="Rootless Podman sandbox for the DeepSeek Harness (dsh) agent" \
      org.opencontainers.image.version="${DSH_VERSION}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.source="https://github.com/deepseek-ai/dsh" \
      org.opencontainers.image.licenses="MIT"

ENV DSH_HOME=/home/dshuser/data/dsh \
    DSH_WEB_PORT=8080 \
    NPM_CONFIG_UPDATE_NOTIFIER=false \
    NPM_CONFIG_FUND=false \
    NPM_CONFIG_AUDIT=false

# --shell nologin: the sandbox account can never be used as a login target.
RUN useradd --create-home --uid 10001 --shell /usr/sbin/nologin dshuser \
    && mkdir -p /home/dshuser/data \
    && chown dshuser:dshuser /home/dshuser/data

# The last path element must stay "node_modules": dsh's bin shim is a relative
# symlink and its packages resolve siblings by that name.
COPY --from=deps --chown=root:root /build/node_modules /opt/dsh/node_modules
RUN ln -s /opt/dsh/node_modules/.bin/dsh /usr/local/bin/dsh
COPY --chmod=644 scripts/container-ip.mjs /usr/local/lib/container-ip.mjs
COPY --chmod=644 scripts/healthcheck.mjs /usr/local/lib/healthcheck.mjs
COPY --chmod=755 scripts/entrypoint.sh /usr/local/bin/entrypoint.sh

USER dshuser
WORKDIR /home/dshuser
EXPOSE 8080

ENTRYPOINT ["entrypoint.sh"]
CMD ["web"]
