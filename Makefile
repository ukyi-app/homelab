SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

.PHONY: help bootstrap up down verify host-up

help: ## List available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  %-12s %s\n", $$1, $$2}'

up: ## [runtime] bring the OrbStack VM + k3s + storage up (idempotent, = host-up)
	@infra/k3s-bootstrap/host-up.sh

host-up: ## [runtime] alias for `up` — host substrate bring-up (M1)
	@infra/k3s-bootstrap/host-up.sh

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

TF_ROOTS := cloudflare tailscale github

.PHONY: tf-validate
tf-validate: ## terraform fmt -check + validate across all infra roots
	@for r in $(TF_ROOTS); do \
	  terraform -chdir=infra/$$r fmt -check -recursive >/dev/null || \
	    { echo "$$r: fmt FAILED (run 'terraform -chdir=infra/$$r fmt -recursive')"; exit 1; }; \
	  terraform -chdir=infra/$$r validate >/dev/null || { echo "$$r: validate FAILED"; exit 1; }; \
	  echo "$$r: validated"; \
	done

.PHONY: seed-secrets
seed-secrets: ## generate SOPS-encrypted seed secrets from terraform outputs
	@bash scripts/seed-secrets.sh
