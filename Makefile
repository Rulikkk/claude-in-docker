SHELL := /bin/bash
COMPOSE := docker compose

.PHONY: help build verify mcp shell auth clean

help:
	@grep -E '^[a-z-]+:.*?##' $(MAKEFILE_LIST) | sed 's/:.*##/\t/'

build: ## Build the image
	$(COMPOSE) build

auth: ## How to obtain the long-lived token
	@echo "On a machine WITH A BROWSER (not this server):"
	@echo "  npm install -g @anthropic-ai/claude-code && claude setup-token"
	@echo "Paste sk-ant-oat01-... into .env as CLAUDE_CODE_OAUTH_TOKEN, then chmod 600 .env"

verify: ## Smoke test auth + tools
	$(COMPOSE) run --rm -T console claude -p "Reply with the single word: ok" --output-format json

mcp: ## Apply config/mcp-servers.txt
	$(COMPOSE) run --rm console install-mcp-servers.sh

shell: ## Root-less shell inside the container
	$(COMPOSE) run --rm --entrypoint /usr/local/bin/entrypoint.sh console bash

clean: ## Stop and remove containers (bind-mounted data is kept)
	$(COMPOSE) down
