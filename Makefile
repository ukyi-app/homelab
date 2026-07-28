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
	@bash scripts/check-doc-index.sh
	@bash scripts/check-bats-accounting.sh
	@bash scripts/check-app-deploy.sh
	@bun tools/check-resource-limits.ts
	@bun tools/check-alert-rules.ts
	@bun tools/check-guard-authority.ts
	@bun tools/check-workflow-readiness.ts
	@bun tools/check-image-ownership.ts
	@bash scripts/check-app-netpol.sh
	@bash scripts/check-image-pins.sh
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

verify-secrets: ## [secret] 추적 *.enc.yaml 무결성(암호화 + recipient 신원 canonical 일치 + 복호가능) 검사 — 값 미출력
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

# make ci가 도구 부재로 건너뛴 게이트 스텝을 모으는 원장(마지막 줄이 SKIP 마커 + exit 4로 낸다).
CI_UNEVAL := .make-ci-uneval


.PHONY: ci-guard-tracked
ci-guard-tracked:
# ⚠️ **추적되지 않은 게이트 대상 파일이 있으면 여기서 멈춘다**(ci의 첫 전제 — 1분짜리 chart-test 앞에서 끊는다).
#    이 레포의 게이트는 대부분 `git ls-files`로 열거한다(하드코딩 글롭이 리네임에 조용히 0매치되는 것을
#    피하려는 의도적 선택). 그 결과 untracked 파일은
#    **로컬에서 측정 대상 밖**인데 커밋되는 순간 CI에서는 측정된다 → `make ci` 초록이 gate 실패를 예고하지
#    못한다. 실측(2026-07-28): 새 tools/*.ts를 `git add` 전에 make ci로 검증해 1671건 전건 초록이었는데,
#    커밋 직후 CI에서 shebang 규약 위반으로 red가 났다. 로컬이 그 파일을 **아예 안 본** 것이다.
#    ⇒ 이건 "재현했는데 실패"가 아니라 **"재현하지 못했다"**이므로 skip 신호(마커 + exit 4)가 맞다.
	@u="$$(git ls-files --others --exclude-standard -- tools scripts tests platform apps policy infra .github docs Makefile | head -20)"; if [ -n "$$u" ]; then echo "SKIP: ci: 추적되지 않은 게이트 대상 파일이 있어 재현이 성립하지 않는다(게이트는 tracked 열거를 쓴다 — 이 파일들은 로컬에서 측정되지 않고 커밋 후 CI에서만 측정된다). \`git add\` 후 다시 실행하라: $$(echo $$u)" >&2; exit 4; fi

.PHONY: ci
ci: ci-guard-tracked m6-tools chart-test ## push 전 단일 진입점 — ci.yaml job 'gate' 재현(차이는 policy/ci-parity.json에 계상)
# ⚠️ "그대로 재현"이라고 쓰지 않는다 — 그건 오랫동안 거짓이었다(실측: gate run 스텝 19건 중 8건이 여기
#    없었는데 패리티 테스트는 초록이었다. 하드코딩된 5개 토큰만 대조했고 하필 그 5개가 전부 미러돼 있었다).
#    이제 **모든 차이는 policy/ci-parity.json에 계상**되고 tools/check-ci-parity.ts가 강제한다:
#    여기서 스텝이 빠지면 mirrored 대조가 red, gate에 스텝이 늘면 미계상으로 red다.
	@rm -f $(CI_UNEVAL)
	bun run typecheck
	bun run verify:ledger
	bun tools/audit-orphans.ts --ci
	@./scripts/check-skeleton.sh
	bun tools/check-guard-authority.ts
	bun tools/check-image-ownership.ts
	bun tools/check-workflow-readiness.ts
	bun tools/check-ci-parity.ts
	./scripts/run-bats.sh
	shellcheck $$(git ls-files '*.sh')
	@bash scripts/sops-guard.sh
# ⚠️⚠️ 아래 스텝들은 **서브-make로 묶지 않는다**. GNU make는 recipe 줄에 `$(MAKE)`가 있으면 `-n`에서도
#    그 줄을 **실제로 실행한다**(재귀 make에 플래그를 전파하려는 문서화된 동작). 그런데 이 레포는
#    `make -n ci` 출력을 **데이터로 읽는다** — tools/check-ci-parity.ts(미러 대조)와
#    tools/check-guard-authority.ts(venue 수집) 둘 다. 서브-make로 묶었더니 `make -n ci` 한 번에
#    docker e2e가 통째로 돌았다(실측). 즉 `$(MAKE)`는 여기서 드라이런을 부수효과로 바꾼다.
#    ⇒ 각 게이트 스텝은 **자기 줄에** 둔다. 장황하지만 (a) 드라이런이 안전하고 (b) 패리티 대조가
#      래퍼가 아니라 스텝 단위로 구체적이다.
#
# 아래 도구들(actionlint·docker·node)은 m6-tools 필수가 아니다(gate 러너엔 항상 있다). 부재 시 그 스텝은
# **미평가 원장에 이름을 남기고** 넘어가고, 마지막 줄이 규약대로 `SKIP:` 마커 + exit 4를 낸다.
# ⚠️ 여기서 개별적으로 `SKIP:`를 내면 안 된다 — 마커를 내면서 종료코드가 0이면 **호출자에겐 여전히 성공**이고,
#    그게 이 레포가 금지한 패턴이다(CONTRIBUTING '가드 skip 신호', scripts/check-skip-signalling.sh가 강제).
#    docker가 없으면 make ci는 gate를 재현하지 **못한** 것이고, 0으로 끝나는 것이 이 원장이 없애려는 거짓말이다.
	@if command -v actionlint >/dev/null 2>&1; then actionlint; \
	  else echo "actionlint(워크플로 정적 검사)" >> $(CI_UNEVAL); fi
	@if command -v docker >/dev/null 2>&1; then bash tests/gates/alertmanager-render-e2e.sh; \
	  else echo "telegram-render-e2e" >> $(CI_UNEVAL); fi
	@if command -v docker >/dev/null 2>&1; then bash tests/gates/vector-validate.sh; \
	  else echo "vector-validate" >> $(CI_UNEVAL); fi
	@if command -v docker >/dev/null 2>&1; then bash tests/gates/vmalert-rules-validate.sh; \
	  else echo "vmalert-rules-validate" >> $(CI_UNEVAL); fi
	@if command -v docker >/dev/null 2>&1; then bash tests/gates/skopeo-timeout-smoke.sh; \
	  else echo "skopeo-timeout-smoke" >> $(CI_UNEVAL); fi
	@if command -v node >/dev/null 2>&1; then bash tests/gates/app-shared-node-smoke.sh; \
	  else echo "app-shared-node-smoke" >> $(CI_UNEVAL); fi
# 발화 e2e는 전량 **병렬**이다(각 하네스가 자기 docker 네트워크·컨테이너를 쓰고, 시간의 대부분이 CPU가
# 아니라 replay 대기라 합계가 아니라 최댓값으로 수렴한다 — gate와 같은 이유·같은 방식).
# ⚠️ ci.yaml은 같은 하네스를 **리터럴 경로**로 적는다. 중복이 아니라 역할 분담이다 —
#    check-guard-authority는 venue(ci.yaml run 텍스트·`make -n` 출력)에서 가드 경로를 찾으므로 하네스의
#    "권위 경로"는 ci.yaml이 제공한다. 여기서 글롭을 써도 권위는 유지되고, ci.yaml 쪽 목록이 레포와
#    어긋나면 거기 있는 교차 대조가 red를 낸다.
	@if ! command -v docker >/dev/null 2>&1; then \
	  echo "vmalert-*-firing-e2e.sh 전량" >> $(CI_UNEVAL); \
	else \
	  hs="$$(git ls-files 'tests/gates/vmalert-*-firing-e2e.sh')"; \
	  n="$$(printf '%s\n' "$$hs" | grep -c . || true)"; \
	  if [ "$${n:-0}" -lt 3 ]; then echo "발화 e2e 하네스 $${n:-0}건 < 3 — 열거 붕괴(무측정 초록)" >&2; exit 1; fi; \
	  echo "발화 e2e $$n건 병렬 실행"; d="$$(mktemp -d)"; pids=""; \
	  for h in $$hs; do bash "$$h" > "$$d/$$(basename $$h).log" 2>&1 & pids="$$pids $$!:$$h"; done; \
	  fail=0; \
	  for p in $$pids; do pid="$${p%%:*}"; h="$${p#*:}"; \
	    if wait "$$pid"; then echo "PASS $$h"; else echo "FAIL $$h" >&2; fail=1; fi; done; \
	  for h in $$hs; do echo "----- $$h"; cat "$$d/$$(basename $$h).log"; done; \
	  rm -rf "$$d"; exit $$fail; \
	fi

	@if [ -s $(CI_UNEVAL) ]; then echo "SKIP: ci: 로컬에 도구가 없어 평가하지 못한 게이트 스텝이 있다 — $$(tr '\n' ' ' < $(CI_UNEVAL))(gate에선 전부 실행된다)" >&2; rm -f $(CI_UNEVAL); exit 4; fi
.PHONY: reset-pg-archive
reset-pg-archive: ## [DR ④] R2 serverName pg 아카이브 정리(재구축 후 아카이빙 재개). 기본 dry-run; 실제 정리는 ARGS=--purge
	@scripts/reset-pg-r2-archive.sh $(ARGS)

# --- 도메인 부재 시 SKIP 신호를 내는 가드 진입점 ---
# 규약(CONTRIBUTING '가드 skip 신호'): 도메인이 없으면 `SKIP: <타깃>: <이유>` 마커 + recipe exit 4.
# ⚠️ GNU make는 recipe 종료코드를 자기 Error 2로 뭉갠다 — make 계층에서 관측 가능한 신호는 **마커 + 비-0**이다.
#
# 아래 3쌍(전제 · 대상 스위트)은 **테스트 시임**이다 — 게이트가 skip 갈래와 평가 갈래를 둘 다 실증하려면
# 도메인을 주입할 수 있어야 한다. 시임 없이 skip 갈래만 단언하면 "무조건 skip"인 죽은 타깃이 통과한다
# (실측: `@if false; then`으로 바꿔도 전 테스트가 초록이었다 — 이 티켓이 잡으려던 바로 그 병).
# ⚠️ `?=`가 아니라 `:=` — `?=`면 환경변수가 새어 들어와 스위트가 환경 의존이 된다(실측: RUNBOOK_DIR을
#   export한 셸에서 test_make-runbooks가 red). `:=`도 명령행 오버라이드(`make X=…`)는 그대로 받는다.
RUNBOOK_DIR   := docs/runbooks
POSTURE_BATS  := tests/posture/test_*.bats
KSOPS_BATS    := platform/cnpg/prod/test_creds_reference.bats \
                 platform/cnpg/prod/test_drill_alerting.bats \
                 platform/cnpg/prod/test_kustomize_build.bats \
                 platform/cache/prod/test_ksops_render.bats

.PHONY: verify-runbooks
verify-runbooks: ## [DR] 로컬 런북 bats 실행(docs/runbooks/ — gitignored 로컬 전용, CI 미배선). 부재=SKIP
	@if [ -d "$(RUNBOOK_DIR)" ] && ls $(RUNBOOK_DIR)/*.bats >/dev/null 2>&1; then \
	  bats $(RUNBOOK_DIR)/*.bats; \
	else echo "SKIP: verify-runbooks: $(RUNBOOK_DIR)/*.bats 0건(gitignored 로컬 전용) — 런북 회귀 미평가"; exit 4; fi

.PHONY: verify-runbook-index
verify-runbook-index: ## [local] 런북 인덱스↔docs/runbooks 정합(런북 부재=SKIP — verify-runbooks와 별개)
	@bash scripts/verify-runbook-index.sh

.PHONY: verify-posture
verify-posture: ## [live] posture 라이브 스위트(internal-by-default·netpol·e2e) — KUBECONFIG 부재=SKIP
	@if [ -f "$(KUBECONFIG_LIVE)" ]; then \
	  KUBECONFIG=$(KUBECONFIG_LIVE) bats $(POSTURE_BATS); \
	else echo "SKIP: verify-posture: $(KUBECONFIG_LIVE) 부재 — 라이브 posture 미평가. 먼저 make up"; exit 4; fi

.PHONY: verify-ksops
verify-ksops: ## [local] KSOPS 렌더 bats(cnpg×3·cache×1) — 실 age 키 있으면 실행/부재=SKIP(.ci-exclude 그룹)
	@if [ -f "$(SOPS_AGE_KEY_FILE)" ]; then \
	  SOPS_AGE_KEY_FILE=$(SOPS_AGE_KEY_FILE) bats $(KSOPS_BATS); \
	else echo "SKIP: verify-ksops: $(SOPS_AGE_KEY_FILE) 부재 — KSOPS 렌더 미평가. SOPS_AGE_KEY_FILE 지정 후 재실행"; exit 4; fi

.PHONY: verify-traps
verify-traps: ## docs/traps.md 함정 원장의 guard 경로가 실재하는지(enforced 드리프트 차단)
	@bash scripts/verify-traps.sh

# seal-* 타깃은 seal-batch(선언 테이블·preflight fail-closed) 위임 별칭 — 타깃명은 외부 참조 보존.
.PHONY: seal-adguard-auth
seal-adguard-auth: ## AdGuard UI 비밀번호를 bcrypt 봉인 → adguard-auth SealedSecret (seal-batch 위임)
	@bun tools/seal-batch.ts --only adguard-auth

.PHONY: seal-adguard-api
seal-adguard-api: ## AdGuard API 평문 비밀번호를 adguard-api-creds SealedSecret로 봉인 — rewrite 리컨실러 basic auth (seal-batch 위임)
	@bun tools/seal-batch.ts --only adguard-api

.PHONY: seal-argocd-notify
seal-argocd-notify: ## telegram 봇 토큰을 argocd-notifications-secret SealedSecret로 봉인 (seal-batch 위임)
	@bun tools/seal-batch.ts --only argocd-notify

.PHONY: seal-files-secrets
seal-files-secrets: ## files SealedSecret 2종(keys 레지스트리 + files-ns ghcr-pull) 봉인 (seal-batch 위임)
	@bun tools/seal-batch.ts --group files-secrets

.PHONY: seal-ghcr-pull
seal-ghcr-pull: ## GHCR read 토큰을 ghcr-pull SealedSecret 3평면(prod·files·observability) 봉인(단일 회전 타깃, seal-batch 위임)
	@bun tools/seal-batch.ts --group ghcr-pull

.PHONY: seal-ghcr-read
seal-ghcr-read: ## GHCR read 토큰을 observability NS ghcr-read 봉인 (seal-batch 위임 — 회전은 seal-ghcr-pull이 3평면 일괄)
	@bun tools/seal-batch.ts --only ghcr-read

.PHONY: seal-all
seal-all: ## [DR] 선언 테이블 전 봉인본 일괄 재봉인 — sealing key 회전 드릴(owner-local 5+ 봉인본)
	@bun tools/seal-batch.ts --all

.PHONY: backup-local-asset
backup-local-asset: ## [DR] 런북 tarball을 age 백업(OUT=<git 밖 경로>). --verify는 ARGS=--verify
	@test -n "$(OUT)" || { echo "OUT=<git 밖 outdir> 필요"; exit 1; }
	@bash scripts/backup-local-asset.sh $(ARGS) "$(OUT)"

## --- 운영 진입점 (라이브 read-only; 변경 권위는 ArgoCD) ---
.PHONY: argo-status argo-sync argo-terminate argo-wait render kubeconfig audit audit-orphan-pv

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

audit-orphan-pv: ## [ops][live] 고아 Released PV 감사(PVC 삭제+Retain hostPath 누수 나열, 파괴 없음)
	@KUBECONFIG=$(KUBECONFIG_LIVE) bash scripts/audit-orphan-pv.sh

.PHONY: teardown-app teardown-resource
teardown-app: ## [teardown] APP= 앱 철거(owner-local — clean-worktree·fresh-main 전용브랜치·PR). 예: make teardown-app APP=foo
	@scripts/teardown.sh --app "$(APP)"
teardown-resource: ## [teardown] RESOURCE=<db|cache>:<name> REFS_VERIFIED=<id> 리소스 retain 철거(owner-local). 예: make teardown-resource RESOURCE=db:foo REFS_VERIFIED=manual-2026-06-25
	@REFS_VERIFIED="$(REFS_VERIFIED)" scripts/teardown.sh --resource "$(RESOURCE)"
