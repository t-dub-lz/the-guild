# The Guild of Aberrant Computation
# ─────────────────────────────────
.DEFAULT_GOAL := help
SHELL := /bin/bash

# Pass extra args to conclave (e.g., make conclave ARGS="-o myorg -j 20")
ARGS ?=

# ═══════════════════════════════════════════════════════════════════════════════
# Help
# ═══════════════════════════════════════════════════════════════════════════════
.PHONY: help
help: ## Show this help
	@echo ""
	@echo "  The Guild of Aberrant Computation"
	@echo "  ─────────────────────────────────"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'
	@echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# Setup & Install
# ═══════════════════════════════════════════════════════════════════════════════
.PHONY: setup
setup: ## Check and install system dependencies for local development
	@echo "Checking system dependencies..."
	@ok=true; \
	for cmd in bun gh jq parallel bc; do \
		if command -v $$cmd >/dev/null 2>&1; then \
			printf "  \033[32m✓\033[0m %s (%s)\n" "$$cmd" "$$(command -v $$cmd)"; \
		else \
			printf "  \033[31m✗\033[0m %s (not found)\n" "$$cmd"; \
			ok=false; \
		fi; \
	done; \
	if [ "$$ok" = false ]; then \
		echo ""; \
		echo "Missing dependencies. Install with:"; \
		echo "  bun:      curl -fsSL https://bun.sh/install | bash"; \
		echo "  gh:       https://cli.github.com/"; \
		echo "  jq:       sudo apt install jq"; \
		echo "  parallel: sudo apt install parallel"; \
		echo "  bc:       sudo apt install bc"; \
		exit 1; \
	fi
	@echo ""
	@echo "All system dependencies present."

.PHONY: install
install: ## Install all project dependencies (lib + guild-hall)
	@echo "Installing lib dependencies..."
	cd lib && bun install
	@echo ""
	@echo "Installing guild-hall dependencies..."
	cd guild-hall && bun install
	@echo ""
	@echo "Done. Run 'make run' to start a scan."

# ═══════════════════════════════════════════════════════════════════════════════
# Run
# ═══════════════════════════════════════════════════════════════════════════════
.PHONY: run
run: conclave ## Default: run conclave scanner (alias for 'make conclave')

.PHONY: conclave
conclave: ## Run conclave scanner (pass ARGS="-o myorg" for options)
	./conclave.sh $(ARGS)

.PHONY: hall
hall: ## Launch the Guild Hall TUI
	cd guild-hall && bun run guild-hall.tsx

# ═══════════════════════════════════════════════════════════════════════════════
# Test & Check
# ═══════════════════════════════════════════════════════════════════════════════
.PHONY: test
test: ## Run guild-hall tests
	cd guild-hall && bun test

.PHONY: check
check: ## Typecheck guild-hall
	cd guild-hall && bun run typecheck
