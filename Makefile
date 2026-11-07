IMAGE         ?= localhost/deepseek-harness:latest
CONTAINERFILE ?= Containerfile
PODMAN        ?= podman
COMPOSE       ?= podman-compose
WEB_PORT      ?= 8080

# Upstream package version, read from package.json so the label can never drift
# from what is actually installed by the lockfile.
DSH_VERSION   ?= $(shell sed -n 's/.*"@deepseek-ai\/dsh": *"\([^"]*\)".*/\1/p' package.json | head -1)

# macOS sandbox settings. Set LAN_SUBNET to your Wi-Fi/Ethernet subnet.
SANDBOX_NAME  ?= dsh-sandbox
SANDBOX_NET   ?= dsh-mac-net
LAN_SUBNET    ?= 192.168.1.0/24
# 192.168.127.0/24 is the podman-machine gvproxy network; its .254 address forwards to the Mac's loopback.
# The RFC1918 ranges and Tailscale's CGNAT range are blocked so a compromised agent cannot pivot to
# other containers (the default `podman` bridge is 10.88.0.0/16) or a VPN mesh. Your own sandbox
# subnet stays reachable: its connected route is more specific than the blackhole.
BLOCKED_SUBNETS ?= $(LAN_SUBNET) \
	192.168.127.0/24 169.254.0.0/16 \
	10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10
# Single LAN hosts the sandbox may reach (all ports; routes can't filter by port).
# Needs a fixed subnet so the network's gateway address is known for the /32 routes.
ALLOWED_HOSTS ?= 192.168.1.219
SANDBOX_SUBNET  ?= 10.89.200.0/24
SANDBOX_GATEWAY ?= 10.89.200.1
DSH_WEB_SEARCH_PROVIDER ?= exa
export DSH_WEB_SEARCH_PROVIDER

# Each run path gets its own network and volume, so a dev container can never
# read (or corrupt) the production agent's state, and vice versa.
NET_NAME        ?= dsh-dev-net
DEV_VOLUME      ?= deepseek-harness-dev-data
COMPOSE_NET     ?= dsh-compose-net
COMPOSE_SUBNET  ?= 10.89.204.0/24
COMPOSE_GATEWAY ?= 10.89.204.1
PROD_NET        ?= deepseek-harness-net
PROD_SUBNET     ?= 10.89.201.0/24
PROD_GATEWAY    ?= 10.89.201.1
PROD_VOLUME     ?= deepseek-harness-prod-data
ENV_FILE        ?= $(HOME)/.config/deepseek-harness/env

# Container hardening shared by every run path. This podman has no
# --no-new-privileges flag; --security-opt= is the supported form.
HARDEN = --cap-drop=ALL \
	--security-opt=no-new-privileges \
	--no-hosts \
	--init \
	--read-only \
	--pids-limit=256 \
	--sysctl=net.ipv4.ip_forward=0 \
	--tmpfs /tmp:rw,size=512m,mode=1777 \
	--tmpfs /home/dshuser/.local:rw,size=512m,mode=1777 \
	--security-opt mask=/proc/kcore \
	--security-opt mask=/proc/sched_debug \
	--label io.deepseek.sandbox=true
# Healthcheck probes the interface address dsh binds (never loopback).
HC = --health-cmd "node /usr/local/lib/healthcheck.mjs" \
	--health-interval=30s \
	--health-timeout=5s \
	--health-start-period=30s \
	--health-retries=3

# Reject values that would break the shell or the route syntax.
define check_subnet
	case "$(1)" in *[!0-9./]*|*/*/*) echo "invalid subnet: $(1)" >&2; exit 1;; esac
endef
define check_host
	case "$(1)" in *[!0-9a-zA-Z._-]*) echo "invalid host: $(1)" >&2; exit 1;; esac
endef

QUADLET_DIR := $(HOME)/.config/containers/systemd
SYSTEMD_DIR := $(HOME)/.config/systemd/user

.DEFAULT_GOAL := help
.PHONY: help build run up down logs compose-net sandbox-net sandbox-run sandbox-url sandbox-open sandbox-logs sandbox-stop quadlet-net quadlet-install quadlet-start quadlet-stop quadlet-url quadlet-uninstall prune audit digest-check validate

##@ General
help: ## Show this help
	@echo "Usage: make <target> [VAR=value]"
	@awk 'BEGIN {FS = ":.*?## "} \
		/^##@/ {printf "\n%s\n", substr($$0, 5)} \
		/^[a-zA-Z_-]+:.*?## / {printf "  %-18s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo
	@echo "Variables (current values, override on the command line):"
	@printf "  %-16s %s\n" \
		IMAGE "$(IMAGE)" \
		WEB_PORT "$(WEB_PORT)" \
		SANDBOX_NAME "$(SANDBOX_NAME)" \
		SANDBOX_NET "$(SANDBOX_NET)" \
		NET_NAME "$(NET_NAME)" \
		COMPOSE_NET "$(COMPOSE_NET)" \
		PROD_NET "$(PROD_NET)" \
		LAN_SUBNET "$(LAN_SUBNET)" \
		SANDBOX_SUBNET "$(SANDBOX_SUBNET)" \
		ALLOWED_HOSTS "$(ALLOWED_HOSTS)" \
		DEV_VOLUME "$(DEV_VOLUME)" \
		PROD_VOLUME "$(PROD_VOLUME)" \
		PODMAN "$(PODMAN)" \
		COMPOSE "$(COMPOSE)"
	@echo
	@echo "Secrets are OPTIONAL. DEEPSEEK_API_KEY / EXA_API_KEY are passed through from your"
	@echo "shell only if set; otherwise start the app and enter them in the web Models page."

##@ Build and run
# VCS_REF uses --short and swallows stderr: on a repo with no commits yet,
# `git rev-parse HEAD` prints "HEAD" and then fails, which used to produce a
# two-line label value.
build: ## Build the OCI image
	$(PODMAN) build -t $(IMAGE) -f $(CONTAINERFILE) \
		--build-arg DSH_VERSION=$(DSH_VERSION) \
		--build-arg VCS_REF=$$(git rev-parse --short HEAD 2>/dev/null || echo unknown) \
		--build-arg BUILD_DATE=$$(date -u +%Y-%m-%dT%H:%M:%SZ) .

run: build ## Run `dsh web` in the foreground, hardened (keys optional; set in the web UI)
	$(PODMAN) run --rm -it -p 127.0.0.1:$(WEB_PORT):8080 \
		$(HARDEN) $(HC) \
		--memory=8g --cpus=4 \
		-v $(DEV_VOLUME):/home/dshuser/data \
		-e DEEPSEEK_API_KEY -e DSH_WEB_SEARCH_PROVIDER -e EXA_API_KEY \
		$(IMAGE)

##@ Compose (local development)
compose-net: ## Create the compose network with the same egress routes as sandbox-net
	@$(call check_subnet,$(COMPOSE_SUBNET))
	@$(call check_subnet,$(COMPOSE_GATEWAY))
	@$(foreach h,$(ALLOWED_HOSTS),$(call check_host,$(h));)
	@$(PODMAN) network exists $(COMPOSE_NET) || { \
		args=""; \
		for s in $(BLOCKED_SUBNETS); do args="$$args --route $$s,blackhole"; done; \
		for h in $(ALLOWED_HOSTS); do args="$$args --route $$h/32,$(COMPOSE_GATEWAY)"; done; \
		$(PODMAN) network create --subnet $(COMPOSE_SUBNET) --gateway $(COMPOSE_GATEWAY) $$args $(COMPOSE_NET); \
	}

up: compose-net ## Build and start the stack with podman-compose
	$(COMPOSE) up -d --build

down: ## Stop the podman-compose stack
	$(COMPOSE) down

logs: ## Tail compose logs (launch token is redacted)
	$(COMPOSE) logs -f 2>&1 | sed -E 's/(token=)[^&[:space:]]*/\1<redacted>/g'

##@ Hardened sandbox (macOS)
sandbox-net: ## Create the isolated network: blackhole LAN/private ranges, allow only ALLOWED_HOSTS
	@$(call check_subnet,$(SANDBOX_SUBNET))
	@$(call check_subnet,$(SANDBOX_GATEWAY))
	@$(foreach h,$(ALLOWED_HOSTS),$(call check_host,$(h));)
	@$(PODMAN) network exists $(SANDBOX_NET) || { \
		args=""; \
		for s in $(BLOCKED_SUBNETS); do args="$$args --route $$s,blackhole"; done; \
		for h in $(ALLOWED_HOSTS); do args="$$args --route $$h/32,$(SANDBOX_GATEWAY)"; done; \
		$(PODMAN) network create --subnet $(SANDBOX_SUBNET) --gateway $(SANDBOX_GATEWAY) $$args $(SANDBOX_NET); \
	}

# API keys are OPTIONAL. If DEEPSEEK_API_KEY / EXA_API_KEY are set in your shell they are
# passed through (never put them in this file); if not, the container still starts and you
# enter them in the web Models page, which stores them in the data volume's credentials file.
sandbox-run: sandbox-net ## Run the hardened `dsh web` sandbox on 127.0.0.1:WEB_PORT (keys optional)
	$(PODMAN) run -d \
		--name $(SANDBOX_NAME) \
		--network=$(SANDBOX_NET) \
		--publish 127.0.0.1:$(WEB_PORT):8080 \
		$(HARDEN) $(HC) \
		--memory=4g --cpus=2 \
		--volume $(DEV_VOLUME):/home/dshuser/data \
		-e DEEPSEEK_API_KEY \
		-e DSH_WEB_SEARCH_PROVIDER \
		-e EXA_API_KEY \
		$(IMAGE)
	@$(MAKE) --no-print-directory sandbox-url

sandbox-url: ## Print the browser URL (with the current launch token) for the running sandbox
	@for i in $$(seq 1 30); do \
		t=$$($(PODMAN) logs $(SANDBOX_NAME) 2>&1 | grep -o 'token=[^[:space:]]*' | tail -1); \
		if [ -n "$$t" ]; then echo "http://localhost:$(WEB_PORT)/?$$t"; exit 0; fi; \
		sleep 1; \
	done; \
	echo "No token found; is $(SANDBOX_NAME) running? (make sandbox-run)" >&2; exit 1

sandbox-open: ## Open the sandbox web UI in your browser (macOS)
	@open "$$($(MAKE) --no-print-directory sandbox-url)"

sandbox-logs: ## Tail sandbox logs (launch token is redacted)
	$(PODMAN) logs -f $(SANDBOX_NAME) 2>&1 | sed -E 's/(token=)[^&[:space:]]*/\1<redacted>/g'

sandbox-stop: ## Remove the sandbox container and its network
	-$(PODMAN) rm -f $(SANDBOX_NAME)
	-$(PODMAN) network rm $(SANDBOX_NET)

##@ Production (rootless Quadlet)
# Quadlet has no Route= key, so the isolated network is created here and only
# referenced by name from the .container unit.
quadlet-net: ## Create the Quadlet network with the same egress routes as sandbox-net
	@$(call check_subnet,$(PROD_SUBNET))
	@$(call check_subnet,$(PROD_GATEWAY))
	@$(foreach h,$(ALLOWED_HOSTS),$(call check_host,$(h));)
	@$(PODMAN) network exists $(PROD_NET) || { \
		args=""; \
		for s in $(BLOCKED_SUBNETS); do args="$$args --route $$s,blackhole"; done; \
		for h in $(ALLOWED_HOSTS); do args="$$args --route $$h/32,$(PROD_GATEWAY)"; done; \
		$(PODMAN) network create --subnet $(PROD_SUBNET) --gateway $(PROD_GATEWAY) $$args $(PROD_NET); \
	}

quadlet-install: build quadlet-net ## Install Quadlet units and prune timer (rootless)
	mkdir -p $(QUADLET_DIR) $(SYSTEMD_DIR)
	# The unit references this env file via --env-file, which podman treats as a hard
	# error if the file is missing. Keys are OPTIONAL, so create an empty template when
	# absent; add keys here later, or just enter them in the web Models page.
	@mkdir -p $$(dirname $(ENV_FILE)); chmod 700 $$(dirname $(ENV_FILE)) 2>/dev/null || true
	@test -f $(ENV_FILE) || { \
		printf '# Optional secrets. Leave blank to configure keys in the web Models page.\n# DEEPSEEK_API_KEY=\n# EXA_API_KEY=\n# DSH_WEB_SEARCH_PROVIDER=exa\n' > $(ENV_FILE); \
		chmod 600 $(ENV_FILE); \
		echo "created empty $(ENV_FILE) (chmod 600); add keys here or set them in the web UI"; \
	}
	cp quadlet/*.container quadlet/*.volume $(QUADLET_DIR)/
	# The units hardcode /usr/bin/podman; point it at this host's podman so the
	# timer still works where podman lives elsewhere (e.g. /usr/local/bin).
	sed "s|/usr/bin/podman|$(shell command -v podman)|" quadlet/podman-prune.service > $(SYSTEMD_DIR)/podman-prune.service
	cp quadlet/podman-prune.timer $(SYSTEMD_DIR)/
	systemctl --user daemon-reload
	systemctl --user enable --now podman-prune.timer

quadlet-start: ## Start the harness service via systemd
	systemctl --user start deepseek-harness.service

quadlet-stop: ## Stop the harness service
	systemctl --user stop deepseek-harness.service

# The token is not in the journal by default (dsh writes it to stdout, which
# journald captures); redact on the way out so it never lands in your terminal
# history or a paste.
quadlet-url: ## Print the browser URL (with the current launch token) for the Quadlet service
	@for i in $$(seq 1 30); do \
		t=$$(journalctl --user -u deepseek-harness.service -n 200 --no-pager 2>/dev/null | grep -o 'token=[^[:space:]]*' | tail -1); \
		if [ -n "$$t" ]; then echo "http://localhost:8080/?$$t"; exit 0; fi; \
		sleep 1; \
	done; \
	echo "No token found; is deepseek-harness.service running? (make quadlet-start)" >&2; exit 1

quadlet-uninstall: ## Remove installed Quadlet units
	-systemctl --user disable --now podman-prune.timer
	rm -f $(QUADLET_DIR)/deepseek-harness.container $(QUADLET_DIR)/deepseek-harness-prod-data.volume
	rm -f $(SYSTEMD_DIR)/podman-prune.service $(SYSTEMD_DIR)/podman-prune.timer
	systemctl --user daemon-reload

# Installs the units into a throwaway quadlet directory inside the VM and runs the
# real generator over them, so an unsupported key fails here instead of at boot.
validate: ## Check Quadlet units against this podman's generator (in the VM)
	@$(PODMAN) machine ssh 'rm -rf /tmp/qv && mkdir -p /tmp/qv'
	@for f in quadlet/*.container quadlet/*.volume; do \
		$(PODMAN) machine ssh "cat > /tmp/qv/$$(basename $$f)" < "$$f"; \
	done
	@$(PODMAN) machine ssh 'D=$$HOME/.config/containers/systemd; mkdir -p $$D; \
		saved=$$(mktemp -d); mv $$D/*.container $$D/*.volume $$saved/ 2>/dev/null || true; \
		cp /tmp/qv/* $$D/; \
		out=$$(/usr/libexec/podman/quadlet --user --dryrun 2>&1 | grep -iE "unsupported|error" || true); \
		rm -f $$D/*.container $$D/*.volume; mv $$saved/* $$D/ 2>/dev/null || true; rmdir $$saved 2>/dev/null || true; \
		rm -rf /tmp/qv; \
		if [ -n "$$out" ]; then echo "$$out"; exit 1; fi; echo "quadlet units OK"'

##@ Maintenance
audit: ## Audit the pinned dependency tree (dev dependencies excluded)
	npm audit --omit=dev --audit-level=high

digest-check: ## Print current base-image digests for the Containerfile pin
	@for img in docker.io/library/node:24-slim; do \
		d=$$($(PODMAN) image inspect $$img --format '{{join .RepoDigests "\n"}}' 2>/dev/null | head -1); \
		echo "$$img -> $${d:-not pulled; run: $(PODMAN) pull $$img}"; \
	done

prune: ## Remove dangling images and build cache (keeps tagged images)
	$(PODMAN) image prune -f
	$(PODMAN) builder prune -f

prune-all: ## Remove ALL unused images (destructive: also untagged base images)
	@printf 'This deletes every unused image, including the node base image.\nRebuild afterwards with `make build`. Continue? [y/N] '
	@read ans; case "$$ans" in [yY]*) $(PODMAN) image prune -a -f; $(PODMAN) builder prune -f;; *) echo "aborted";; esac
