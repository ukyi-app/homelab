SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

.PHONY: help bootstrap up down verify host-up

help: ## 사용 가능한 타겟 목록 출력
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  %-12s %s\n", $$1, $$2}'

up: ## [runtime] OrbStack VM + k3s + 스토리지 기동 (멱등, = host-up)
	@infra/k3s-bootstrap/host-up.sh

host-up: ## [runtime] `up`의 별칭 — 호스트 기반층 기동 (M1)
	@infra/k3s-bootstrap/host-up.sh

down: ## [TODO: M1] OrbStack VM 내리기
	@echo "down: not implemented yet (owned by M1 runtime foundation)" >&2
	@exit 1

bootstrap: ## 멱등 DR 진입점: ArgoCD + sops-age Secret + root app 설치
	@bash scripts/bootstrap.sh

verify: ## 레포 기반 점검 실행 (스켈레톤 + 원장 + sops 왕복)
	@./scripts/check-skeleton.sh
	@scripts/ledger-to-json.sh docs/memory-ledger.md > /tmp/ledger.json
	@conftest test /tmp/ledger.json --policy policy/ledger.rego
	@bats tests/sops-roundtrip.bats

TF_ROOTS := cloudflare tailscale github

.PHONY: tf-validate
tf-validate: ## 모든 infra 루트에 terraform fmt -check + validate 실행
	@for r in $(TF_ROOTS); do \
	  terraform -chdir=infra/$$r fmt -check -recursive >/dev/null || \
	    { echo "$$r: fmt FAILED (run 'terraform -chdir=infra/$$r fmt -recursive')"; exit 1; }; \
	  terraform -chdir=infra/$$r validate >/dev/null || { echo "$$r: validate FAILED"; exit 1; }; \
	  echo "$$r: validated"; \
	done

.PHONY: seed-secrets
seed-secrets: ## terraform output에서 SOPS 암호화 시드 시크릿 생성
	@bash scripts/seed-secrets.sh

.PHONY: bootstrap-deadmanswitch
bootstrap-deadmanswitch: ## [M5] 노드 외부 dead-man's-switch ping URL 시드 여부 검증 (R8)
	@echo ">> DEAD-MAN'S-SWITCH (R8): ensure healthchecks.io check 'homelab-watchdog' exists"
	@echo ">> and HEALTHCHECKS_URL is set in platform/victoria-stack/prod/alerting.enc.yaml (M2-seeded)"
	@echo ">> Full procedure: docs/runbooks/observability-bootstrap.md"
	@sops --decrypt platform/victoria-stack/prod/alerting.enc.yaml 2>/dev/null | grep -q 'HEALTHCHECKS_URL' \
		|| { echo "FAIL: HEALTHCHECKS_URL missing from M2-seeded SOPS secret"; exit 1; }
	@echo "OK: dead-man's-switch ping URL present (armed once relay pod runs)"

# 재선언이 아니라 EDIT: M0 소유의 기존 bootstrap 선행 조건에 bootstrap-deadmanswitch를 추가한다.
bootstrap: bootstrap-deadmanswitch

## --- 마일스톤 6 툴링 ---
.PHONY: m6-tools
m6-tools: ## 마일스톤 6용 차트/CI 툴체인 검증
	@helm version --short | grep -qE 'v(3\.(1[6-9]|[2-9][0-9])|[4-9])\.' || { echo "helm >=3.16 required"; exit 1; }
	@kubeconform -v | grep -qE 'v0\.(6\.[7-9]|[7-9]\.|[1-9][0-9]\.)' || { echo "kubeconform >=0.6.7 required"; exit 1; }
	@bats --version | grep -qE 'Bats 1\.(1[1-9]|[2-9][0-9])' || { echo "bats >=1.11 required"; exit 1; }
	@node --version | grep -qE 'v2[2-9]\.' || { echo "node >=22 required"; exit 1; }
	@pnpm --version | grep -qE '^11\.' || { echo "pnpm 11 required"; exit 1; }
	@yq --version | grep -qE 'v4\.' || { echo "yq v4 required"; exit 1; }
	@jq --version >/dev/null || { echo "jq required"; exit 1; }
	@echo "m6-tools OK"

.PHONY: chart-test
chart-test: ## 모든 kind에 대해 app 차트 렌더+검증
	bats platform/charts/app/tests/
	bash platform/charts/app/tests/render.sh

.PHONY: reset-pg-archive
reset-pg-archive: ## [DR ④] R2 serverName pg 아카이브 정리(재구축 후 아카이빙 재개). 기본 dry-run; 실제 정리는 ARGS=--purge
	@scripts/reset-pg-r2-archive.sh $(ARGS)

.PHONY: seal-adguard-auth
seal-adguard-auth: ## AdGuard UI 비밀번호(.env.secrets ADGUARD_PASSWORD)를 bcrypt 봉인 → adguard-auth SealedSecret
	@scripts/seal-adguard-auth.sh
