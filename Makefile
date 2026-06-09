SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

.PHONY: help bootstrap up down verify host-up

help: ## List available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  %-12s %s\n", $$1, $$2}'

host-up: ## [TODO: M1] provision/start the OrbStack VM (cloud-init host substrate)
	@echo "host-up: not implemented yet (owned by M1 runtime foundation)" >&2
	@exit 1

up: ## [TODO: M1] bring the OrbStack VM + k3s up
	@echo "up: not implemented yet (owned by M1 runtime foundation)" >&2
	@exit 1

down: ## [TODO: M1] tear the OrbStack VM down
	@echo "down: not implemented yet (owned by M1 runtime foundation)" >&2
	@exit 1

bootstrap: ## [TODO: M2] idempotent cluster bootstrap = DR path (ArgoCD + age Secret + root app)
	@echo "bootstrap: not implemented yet (owned by M2 GitOps/bootstrap)" >&2
	@exit 1

verify: ## Run repo-foundation checks (skeleton + ledger + sops round-trip)
	@./scripts/check-skeleton.sh
	@scripts/ledger-to-json.sh docs/memory-ledger.md > /tmp/ledger.json
	@conftest test /tmp/ledger.json --policy policy/ledger.rego
	@bats test/sops-roundtrip.bats
