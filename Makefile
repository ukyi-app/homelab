SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

# 라이브 클러스터 접근(읽기 전용 운영 타겟 전용). 변경 권위는 ArgoCD — 절대 kubectl apply 금지.
KUBECONFIG_LIVE := $(PWD)/infra/k3s-bootstrap/kubeconfig
SOPS_AGE_KEY_FILE ?= $(HOME)/.config/sops/age/keys.txt

.PHONY: help bootstrap up down verify host-up

help: ## 사용 가능한 타겟 목록 출력
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  %-22s %s\n", $$1, $$2}' \
	  | sort

up: ## [runtime] OrbStack VM + k3s + 스토리지 기동 (멱등, = host-up)
	@infra/k3s-bootstrap/host-up.sh

host-up: ## [runtime] `up`의 별칭 — 호스트 기반층 기동 (M1)
	@infra/k3s-bootstrap/host-up.sh

down: ## [TODO: M1] OrbStack VM 내리기
	@echo "down: not implemented yet (owned by M1 runtime foundation)" >&2
	@exit 1

bootstrap: ## 멱등 DR 진입점: ArgoCD + sops-age Secret + root app 설치
	@bash scripts/bootstrap.sh

verify: ## 레포 기반 점검 실행 (스켈레톤 + bats accounting + 배포계약 + 자원 limit + 원장 + sops 왕복)
	@./scripts/check-skeleton.sh
	@bash scripts/check-bats-accounting.sh
	@bash scripts/check-app-deploy.sh
	@bash scripts/check-resource-limits.sh
	@bash scripts/check-app-netpol.sh
	@scripts/verify-ledger.sh
	@bats tests/test_sops-roundtrip.bats

TF_ROOTS := cloudflare tailscale github

.PHONY: tf-validate
tf-validate: ## 모든 infra 루트에 terraform fmt -check + validate 실행
	@for r in $(TF_ROOTS); do \
	  terraform -chdir=infra/$$r fmt -check -recursive >/dev/null || \
	    { echo "$$r: fmt FAILED (run 'terraform -chdir=infra/$$r fmt -recursive')"; exit 1; }; \
	  terraform -chdir=infra/$$r validate >/dev/null || { echo "$$r: validate FAILED"; exit 1; }; \
	  echo "$$r: validated"; \
	done

.PHONY: seed-secrets secret-edit verify-secrets secret-cert-check
seed-secrets: ## [secret] terraform output + .env.secrets에서 SOPS 암호화 시드 시크릿 생성
	@[ -f .env.secrets ] || { echo "seed-secrets: .env.secrets 없음 (cp .env.secrets.example .env.secrets 후 채우기)"; exit 1; }
	@set -a; . ./.env.secrets; set +a; bash scripts/seed-secrets.sh

secret-edit: ## [secret] FILE= SOPS 파일을 복호→편집→재암호화(sops 내장, 평문 디스크 미기록). 사람 전용(인터랙티브)
	@test -n "$(FILE)" || { echo "FILE=<path>.enc.yaml 필요"; exit 1; }
	@case "$(FILE)" in *.enc.yaml) : ;; *) echo "secret-edit: $(FILE) 는 *.enc.yaml 아님"; exit 1 ;; esac
	@test -f "$(FILE)" || { echo "secret-edit: $(FILE) 없음"; exit 1; }
	@test -f "$(SOPS_AGE_KEY_FILE)" || { echo "secret-edit: age 키 없음: $(SOPS_AGE_KEY_FILE)"; exit 1; }
	SOPS_AGE_KEY_FILE=$(SOPS_AGE_KEY_FILE) sops "$(FILE)"

verify-secrets: ## [secret] 추적 *.enc.yaml 무결성(암호화 + recipient 2개 + 복호가능) 검사 — 값 미출력
	@bash scripts/verify-secrets.sh

secret-cert-check: ## [secret] 봉인 전 preflight — 커밋된 cert가 라이브 컨트롤러 cert와 일치하는지(stale 방지). 라이브 kubeseal 필요
	@bash scripts/secret-cert-check.sh

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
	@bun --version | grep -qF '1.3.14' || { echo "bun 1.3.14 required"; exit 1; }
	@yq --version | grep -qE 'v4\.' || { echo "yq v4 required"; exit 1; }
	@jq --version >/dev/null || { echo "jq required"; exit 1; }
	@echo "m6-tools OK"

.PHONY: chart-test
chart-test: ## 모든 kind에 대해 app 차트 렌더+검증
	bats platform/charts/app/tests/
	bash platform/charts/app/tests/render.sh

.PHONY: ci
ci: m6-tools chart-test ## push 전 단일 진입점 — ci.yaml job 'gate'를 로컬에서 그대로 재현(bats 수집은 run-bats.sh SSOT)
	bun run typecheck
	bun run verify:ledger
	bun tools/audit-orphans.ts --ci
	@./scripts/check-skeleton.sh
	./scripts/run-bats.sh
	shellcheck $$(git ls-files '*.sh')
	@files=$$(git ls-files '*.enc.yaml'); if [ -n "$$files" ]; then scripts/sops-guard.sh $$files; fi
	@if command -v docker >/dev/null 2>&1; then bash tests/gates/alertmanager-render-e2e.sh; \
	  else echo "ci: docker 없음 → telegram-render-e2e 스킵(gate에선 실행됨)" >&2; fi

.PHONY: reset-pg-archive
reset-pg-archive: ## [DR ④] R2 serverName pg 아카이브 정리(재구축 후 아카이빙 재개). 기본 dry-run; 실제 정리는 ARGS=--purge
	@scripts/reset-pg-r2-archive.sh $(ARGS)

.PHONY: verify-runbooks
verify-runbooks: ## [DR] 로컬 런북 bats 실행(docs/runbooks/ — gitignored 로컬 전용, CI 미배선)
	@if [ -d docs/runbooks ] && ls docs/runbooks/*.bats >/dev/null 2>&1; then \
	  bats docs/runbooks/*.bats; \
	else echo "verify-runbooks: docs/runbooks/*.bats 없음(로컬 전용 — 러너/fresh checkout엔 부재)"; fi

.PHONY: verify-runbook-index
verify-runbook-index: ## [local] 런북 인덱스↔docs/runbooks 정합(gitignored라 CI skip — verify-runbooks와 별개)
	@bash scripts/verify-runbook-index.sh

.PHONY: verify-posture
verify-posture: ## [live] posture 라이브 스위트(internal-by-default·netpol·e2e) — KUBECONFIG 필요(없으면 skip)
	@if [ -f "$(KUBECONFIG_LIVE)" ]; then \
	  KUBECONFIG=$(KUBECONFIG_LIVE) bats tests/posture/test_*.bats; \
	else echo "verify-posture: $(KUBECONFIG_LIVE) 없음 — 라이브 클러스터 필요(skip). 먼저 make up"; fi

.PHONY: verify-traps
verify-traps: ## docs/traps.md 함정 원장의 guard 경로가 실재하는지(enforced 드리프트 차단)
	@bash scripts/verify-traps.sh

.PHONY: seal-adguard-auth
seal-adguard-auth: ## AdGuard UI 비밀번호(.env.secrets ADGUARD_PASSWORD)를 bcrypt 봉인 → adguard-auth SealedSecret
	@scripts/seal-adguard-auth.sh

.PHONY: seal-ghcr-pull
seal-ghcr-pull: ## GHCR read 토큰(.env.secrets GHCR_PULL_TOKEN)을 ghcr-pull SealedSecret로 봉인(prod NS, private pull)
	@scripts/seal-ghcr-pull.sh

.PHONY: seal-argocd-notify
seal-argocd-notify: ## telegram 봇 토큰/chatId(.env.secrets)를 argocd-notifications-secret SealedSecret로 봉인(argocd NS)
	@scripts/seal-argocd-notify.sh

.PHONY: seal-files-secrets
seal-files-secrets: ## files 컴포넌트 SealedSecret 2종(keys 레지스트리 + files-ns ghcr-pull) 봉인(owner-local)
	@scripts/seal-files-secrets.sh

## --- 운영 진입점 (라이브 read-only; 변경 권위는 ArgoCD) ---
.PHONY: argo-status argo-sync argo-terminate argo-wait render kubeconfig audit

argo-status: ## [ops] ArgoCD Application 목록 — sync/health/멈춘 operation phase
	@KUBECONFIG=$(KUBECONFIG_LIVE) kubectl -n argocd get applications \
	  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,OPERATION:.status.operationState.phase

argo-sync: ## [ops] APP= 명시 sync 트리거(retry 소진 후 재시도). 예: make argo-sync APP=cnpg
	@test -n "$(APP)" || { echo "APP=<application> 필요 (make argo-status로 이름 확인)"; exit 1; }
	KUBECONFIG=$(KUBECONFIG_LIVE) kubectl -n argocd patch app $(APP) --type merge -p '{"operation":{"sync":{}}}'

argo-terminate: ## [ops] APP= 멈춘 operation 종료(phase=Terminating). 예: make argo-terminate APP=cnpg
	@test -n "$(APP)" || { echo "APP=<application> 필요"; exit 1; }
	KUBECONFIG=$(KUBECONFIG_LIVE) kubectl -n argocd patch app $(APP) --subresource status --type merge -p '{"status":{"operationState":{"phase":"Terminating"}}}'

argo-wait: ## [ops] Application이 Healthy 될 때까지 대기(APP= 미지정 시 전체)
	KUBECONFIG=$(KUBECONFIG_LIVE) kubectl -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy application $(if $(APP),$(APP),--all) --timeout=300s

render: ## [ops] COMP= KSOPS 풀 렌더(복호 읽기, 라이브 무영향). 예: make render COMP=cnpg
	@test -n "$(COMP)" || { echo "COMP=<component> 필요 (platform/<COMP>/prod)"; exit 1; }
	SOPS_AGE_KEY_FILE=$(SOPS_AGE_KEY_FILE) kustomize build --enable-helm --enable-alpha-plugins --enable-exec platform/$(COMP)/prod

kubeconfig: ## [ops] 라이브 kubeconfig export 출력 — eval "$$(make kubeconfig)"로 셸에 적용
	@echo 'export KUBECONFIG=$(KUBECONFIG_LIVE)'

audit: ## [ops] 레포 정적 드리프트 감사(registry↔매니페스트↔바인딩↔원장, 읽기 전용)
	@bun tools/audit-orphans.ts

.PHONY: teardown-app teardown-resource
teardown-app: ## [teardown] APP= 앱 철거(owner-local — clean-worktree·fresh-main 전용브랜치·PR). 예: make teardown-app APP=foo
	@scripts/teardown.sh --app "$(APP)"
teardown-resource: ## [teardown] RESOURCE=<db|cache>:<name> REFS_VERIFIED=<id> 리소스 retain 철거(owner-local). 예: make teardown-resource RESOURCE=db:foo REFS_VERIFIED=manual-2026-06-25
	@REFS_VERIFIED="$(REFS_VERIFIED)" scripts/teardown.sh --resource "$(RESOURCE)"
