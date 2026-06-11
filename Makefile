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

bootstrap: ## idempotent DR entry-point: install ArgoCD + sops-age Secret + root app
	@bash scripts/bootstrap.sh

verify: ## Run repo-foundation checks (skeleton + ledger + sops round-trip)
	@./scripts/check-skeleton.sh
	@scripts/ledger-to-json.sh docs/memory-ledger.md > /tmp/ledger.json
	@conftest test /tmp/ledger.json --policy policy/ledger.rego
	@bats tests/sops-roundtrip.bats

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

.PHONY: bootstrap-deadmanswitch
bootstrap-deadmanswitch: ## [M5] verify the off-node dead-man's-switch ping URL is seeded (R8)
	@echo ">> DEAD-MAN'S-SWITCH (R8): ensure healthchecks.io check 'homelab-watchdog' exists"
	@echo ">> and HEALTHCHECKS_URL is set in platform/victoria-stack/prod/alerting.enc.yaml (M2-seeded)"
	@echo ">> Full procedure: docs/runbooks/observability-bootstrap.md"
	@sops --decrypt platform/victoria-stack/prod/alerting.enc.yaml 2>/dev/null | grep -q 'HEALTHCHECKS_URL' \
		|| { echo "FAIL: HEALTHCHECKS_URL missing from M2-seeded SOPS secret"; exit 1; }
	@echo "OK: dead-man's-switch ping URL present (armed once relay pod runs)"

# EDIT (not re-declare): append bootstrap-deadmanswitch to the existing M0-owned bootstrap prereqs.
bootstrap: bootstrap-deadmanswitch

## --- Milestone 6 tooling ---
.PHONY: m6-tools
m6-tools: ## verify chart/CI toolchain for milestone 6
	@helm version --short | grep -qE 'v(3\.(1[6-9]|[2-9][0-9])|[4-9])\.' || { echo "helm >=3.16 required"; exit 1; }
	@kubeconform -v | grep -qE 'v0\.(6\.[7-9]|[7-9]\.|[1-9][0-9]\.)' || { echo "kubeconform >=0.6.7 required"; exit 1; }
	@bats --version | grep -qE 'Bats 1\.(1[1-9]|[2-9][0-9])' || { echo "bats >=1.11 required"; exit 1; }
	@node --version | grep -qE 'v2[2-9]\.' || { echo "node >=22 required"; exit 1; }
	@pnpm --version | grep -qE '^10\.' || { echo "pnpm 10 required (M0 pins pnpm@10)"; exit 1; }
	@yq --version | grep -qE 'v4\.' || { echo "yq v4 required"; exit 1; }
	@jq --version >/dev/null || { echo "jq required"; exit 1; }
	@echo "m6-tools OK"

.PHONY: chart-test
chart-test: ## render+validate the app chart for all kinds
	bats platform/charts/app/tests/
	bash platform/charts/app/tests/render.sh
