set shell := ["bash", "-c"]
set default-list
set minimum-version := "1.58.0"

# 변수 오버라이드는 명령 앞에 둔다: just APP=cnpg argo-sync.
# 줄별 셸·실패 시 중단은 기존 진입점과 같고, SKIP 종료코드 4는 보존한다.

KUBECONFIG_LIVE := justfile_directory() / "infra/k3s-bootstrap/kubeconfig"
SOPS_AGE_KEY_FILE := env("SOPS_AGE_KEY_FILE", home_directory() / ".config/sops/age/keys.txt")
ASSERT_IDENTITY := "KUBECONFIG=" + quote(KUBECONFIG_LIVE) + " bash infra/k3s-bootstrap/assert-cluster-identity.sh"
ASSERT_IDENTITY_WARN := ASSERT_IDENTITY + " --warn"
TF_ROOTS := "cloudflare tailscale github"
CI_UNEVAL := ".just-ci-uneval"
RUNBOOK_DIR := "docs/runbooks"
POSTURE_BATS := "tests/posture/test_*.bats"
KSOPS_BATS := "platform/cnpg/prod/test_creds_reference.bats platform/cnpg/prod/test_drill_alerting.bats platform/cnpg/prod/test_kustomize_build.bats platform/cache/prod/test_ksops_render.bats"
FILE := env("FILE", "")
ARGS := env("ARGS", "")
OUT := env("OUT", "")
APP := env("APP", "")
COMP := env("COMP", "")
RESOURCE := env("RESOURCE", "")
REFS_VERIFIED := env("REFS_VERIFIED", "")

# 라이브 클러스터 접근(읽기 전용 운영 타겟 전용). 변경 권위는 ArgoCD — 절대 kubectl apply 금지.

# 클러스터 정체성 대조(D-i). 컷오버 시기 두 클러스터의 kubeconfig가 경로·포트는 물론 노드명까지
# `k3s`로 같았다 — kubeconfig는 스스로를 구별해 주지 않으므로(낡은 사본·DR 재구축·다음 컷오버)
# KUBECONFIG를 잘못 잡으면 아무 경고 없이 의도하지 않은 클러스터를 때린다. context 이름·InternalIP·arch
# 셋을 라이브로 대조한다.
# ⚠️ **prerequisite로 달지 말 것.** prerequisite는 recipe보다 먼저 도는데,
#    tests/gates/test_guard-skip-signalling.bats가 `just verify-posture`를 `--dry-run` 없이 **실제로**
#    실행한다(CI 러너에는 클러스터가 없다). prerequisite로 달면 그 @test 2건이 죽는다.
#    ⇒ 반드시 **recipe 줄**로 넣는다.
# 변이/파괴 경로 = fail-closed · 읽기/관측 경로 = warn(새벽 3시에 관측 수단까지 잠그지 않는다).

# 사용 가능한 명령 목록 출력
help:
    @just --list --list-heading ""

# [runtime] 호스트 설정 드리프트 검사(sudo 불요). 적용은 host-config.sh --apply 직접 실행
host-config:
    @infra/k3s-bootstrap/host-config.sh --check

# [runtime] 호스트 전제 확인 + k3s + 스토리지 기동 (멱등, = host-up)
up:
    @infra/k3s-bootstrap/host-up.sh

# [runtime] `up`의 별칭 — 호스트 기반층 기동 (M1)
host-up:
    @infra/k3s-bootstrap/host-up.sh

# down·host-config는 파괴/설정 적용을 배선하지 않는다. 해당 스크립트를 직접 실행한다.
# [비배선] 클러스터 내리기 — 파괴 프리미티브는 scripts/destroy-node.sh(직접 실행)
down:
    @echo "down: just에 배선하지 않는다 — 파괴 프리미티브는 scripts/destroy-node.sh다(D-j 확정)." >&2
    @echo "      DR_DRILL_DESTROY_CONFIRM=1 scripts/destroy-node.sh   # 노드 전손(k3s-uninstall + /var/lib/rancher)" >&2
    @echo "      국면 A(versions.env의 BULK_MIGRATION_WINDOW_UNTIL)가 열려 있는 동안엔 그 스크립트도 거부한다." >&2
    @exit 1

# 멱등 DR 진입점: ArgoCD + sops-age Secret + root app 설치
bootstrap: bootstrap-deadmanswitch
    @{{ ASSERT_IDENTITY }}
    @bash scripts/bootstrap.sh

# 레포 기반 점검 실행 (스켈레톤 + bats accounting + 배포계약 + 자원 limit + 원장 + sops 왕복)
verify:
    @./scripts/check-skeleton.sh
    @bash scripts/check-doc-index.sh
    @bash scripts/check-bats-accounting.sh
    @bash scripts/check-bats-style.sh
    @bash scripts/check-app-deploy.sh
    @bun tools/generate-result-schema.ts --check
    @bun tools/check-resource-limits.ts
    @bun tools/check-alert-rules.ts
    @bun tools/check-guard-authority.ts
    @bun tools/check-workflow-readiness.ts
    @bun tools/check-image-ownership.ts
    @bash scripts/check-app-netpol.sh
    @bash scripts/check-image-pins.sh
    @bash scripts/check-locale-collation.sh
    @bash scripts/check-gh-secret-coverage.sh
    @bash scripts/check-host-ports.sh
    @bash scripts/check-bats-fd0.sh
    @bash scripts/check-sigpipe-writers.sh
    @bash scripts/check-floor-vocab.sh
    @bash scripts/check-scan-producers.sh
    @bash scripts/check-skip-signalling.sh
    @scripts/verify-ledger.sh
    @bats tests/test_sops-roundtrip.bats </dev/null
    @bats tests/test_sops-guard.bats </dev/null

# 모든 infra 루트에 terraform fmt -check + validate 실행
tf-validate:
    @for r in {{ TF_ROOTS }}; do \
      terraform -chdir=infra/$r fmt -check -recursive >/dev/null || \
        { echo "$r: fmt FAILED (run 'terraform -chdir=infra/$r fmt -recursive')"; exit 1; }; \
      terraform -chdir=infra/$r validate >/dev/null || { echo "$r: validate FAILED"; exit 1; }; \
      echo "$r: validated"; \
    done

# [secret] terraform output + .env.secrets에서 SOPS 암호화 시드 시크릿 생성
seed-secrets:
    @[ -f .env.secrets ] || { echo "seed-secrets: .env.secrets 없음 (cp .env.secrets.example .env.secrets 후 채우기)"; exit 1; }
    @set -a; . ./.env.secrets; set +a; bash scripts/seed-secrets.sh

# [secret] FILE= SOPS 파일을 복호→편집→재암호화(sops 내장, 평문 디스크 미기록). 사람 전용(인터랙티브)
secret-edit:
    @test -n "{{ FILE }}" || { echo "FILE=<path>.enc.yaml 필요"; exit 1; }
    @case "{{ FILE }}" in *.enc.yaml) : ;; *) echo "secret-edit: {{ FILE }} 는 *.enc.yaml 아님"; exit 1 ;; esac
    @test -f "{{ FILE }}" || { echo "secret-edit: {{ FILE }} 없음"; exit 1; }
    @test -f "{{ SOPS_AGE_KEY_FILE }}" || { echo "secret-edit: age 키 없음: {{ SOPS_AGE_KEY_FILE }}"; exit 1; }
    SOPS_AGE_KEY_FILE={{ SOPS_AGE_KEY_FILE }} sops "{{ FILE }}"

# [secret] 추적 *.enc.yaml 무결성(암호화 + recipient 신원 canonical 일치 + 복호가능) 검사 — 값 미출력
verify-secrets:
    @bash scripts/verify-secrets.sh

# [secret] 봉인 전 preflight — 커밋된 cert가 라이브 컨트롤러 cert와 일치하는지(stale 방지). 라이브 kubeseal 필요
secret-cert-check:
    @bash scripts/secret-cert-check.sh

# [M5] 노드 외부 dead-man's-switch ping URL 시드 여부 검증 (R8)
bootstrap-deadmanswitch:
    @echo ">> DEAD-MAN'S-SWITCH (R8): ensure healthchecks.io check 'homelab-watchdog' exists"
    @echo ">> and HEALTHCHECKS_URL is set in platform/victoria-stack/prod/alerting.enc.yaml (M2-seeded)"
    @echo ">> Full procedure: docs/runbooks/observability-bootstrap.md"
    @# ⚠️ sops 부재를 **비밀 부재로 오진하지 않는다.** 아래 `2>/dev/null`이 command-not-found까지
    @#    삼키므로, sops가 없으면 파이프가 빈 입력을 내고 grep이 실패해 "HEALTHCHECKS_URL missing"이
    @#    찍힌다 — 있지도 않은 시딩 사고를 쫓게 된다. D-i에서 NUC 툴체인을 just+sops 둘로 좁혔으므로
    @#    이 진단은 컷오버 후 NUC에서 실제로 마주칠 자리다.
    @command -v sops >/dev/null 2>&1 \
    	|| { echo "FAIL: sops 미설치 — HEALTHCHECKS_URL 시딩 여부를 확인할 수 없다(부재로 단정하지 않는다)"; exit 1; }
    @sops --decrypt platform/victoria-stack/prod/alerting.enc.yaml 2>/dev/null | grep -q 'HEALTHCHECKS_URL' \
    	|| { echo "FAIL: HEALTHCHECKS_URL missing from M2-seeded SOPS secret"; exit 1; }
    @echo "OK: dead-man's-switch ping URL present (armed once relay pod runs)"

# 마일스톤 6용 차트/CI 툴체인 검증
m6-tools:
    @just --version >/dev/null
    @helm version --short | grep -qE 'v(3\.(1[6-9]|[2-9][0-9])|[4-9])\.' || { echo "helm >=3.16 required"; exit 1; }
    @kubeconform -v | grep -qE 'v0\.(6\.[7-9]|[7-9]\.|[1-9][0-9]\.)' || { echo "kubeconform >=0.6.7 required"; exit 1; }
    @bats --version | grep -qE 'Bats 1\.(1[1-9]|[2-9][0-9])' || { echo "bats >=1.11 required"; exit 1; }
    @bun --version | grep -qF '1.4.2' || { echo "bun 1.4.2 required"; exit 1; }
    @yq --version | grep -qE 'v4\.' || { echo "yq v4 required"; exit 1; }
    @jq --version >/dev/null || { echo "jq required"; exit 1; }
    @echo "m6-tools OK"

# 모든 kind에 대해 app 차트 렌더+검증
chart-test:
    bats platform/charts/app/tests/ </dev/null
    bash platform/charts/app/tests/render.sh

ci-guard-tracked:
    @u="$(git ls-files --others --exclude-standard -- tools scripts tests platform apps policy infra .github docs justfile | head -20)"; if [ -n "$u" ]; then echo "SKIP: ci: 추적되지 않은 게이트 대상 파일이 있어 재현이 성립하지 않는다(게이트는 tracked 열거를 쓴다 — 이 파일들은 로컬에서 측정되지 않고 커밋 후 CI에서만 측정된다). \`git add\` 후 다시 실행하라: $(echo $u)" >&2; exit 4; fi

# push 전 단일 진입점 — ci.yaml job 'gate' 재현(차이는 policy/ci-parity.json에 계상)
ci: ci-guard-tracked m6-tools chart-test
    @rm -f {{ CI_UNEVAL }}
    bun run typecheck
    bun run verify:ledger
    bun tools/audit-orphans.ts --ci
    @./scripts/check-skeleton.sh
    bun tools/check-guard-authority.ts
    bun tools/check-image-ownership.ts
    bun tools/check-workflow-readiness.ts
    bun tools/check-ci-parity.ts
    bash scripts/check-doc-index.sh
    bash scripts/check-bats-accounting.sh
    bash scripts/check-bats-style.sh
    bash scripts/check-app-deploy.sh
    bash scripts/check-app-netpol.sh
    bash scripts/check-image-pins.sh
    bash scripts/check-locale-collation.sh
    bash scripts/check-gh-secret-coverage.sh
    bash scripts/check-host-ports.sh
    bash scripts/check-sigpipe-writers.sh
    bash scripts/check-bats-fd0.sh
    bash scripts/check-floor-vocab.sh
    bash scripts/check-scan-producers.sh
    bash scripts/check-skip-signalling.sh
    bun tools/check-resource-limits.ts
    bun tools/check-alert-rules.ts
    bun tools/check-disk-caps.ts
    bash scripts/check-argocd-revision.sh
    bash scripts/check-pg-servername.sh
    ./scripts/run-bats.sh
    shellcheck $(git ls-files '*.sh')
    @bash scripts/sops-guard.sh
    @bash scripts/sealed-guard.sh
    @ver="$(yq '.repos[] | select(.repo == "https://github.com/gitleaks/gitleaks") | .rev' .pre-commit-config.yaml | sed 's/^v//')"; \
      [ -n "$ver" ] || { echo "gitleaks 핀(rev)을 .pre-commit-config.yaml에서 못 찾았다 — 핀 SSOT 파손" >&2; exit 1; }; \
      if ! command -v gitleaks >/dev/null 2>&1; then echo "gitleaks(누출 스캔 — 로컬 미설치)" >> {{ CI_UNEVAL }}; \
      elif [ "$(gitleaks version 2>/dev/null | tr -d 'v ')" != "$ver" ]; then \
        echo "gitleaks(로컬 판이 핀과 다르다 — 다른 룰셋의 초록은 재현이 아니다)" >> {{ CI_UNEVAL }}; \
      else gitleaks detect --no-git --source . --redact --no-banner --exit-code 1; fi
    @if command -v actionlint >/dev/null 2>&1; then actionlint; \
      else echo "actionlint(워크플로 정적 검사)" >> {{ CI_UNEVAL }}; fi
    @if command -v docker >/dev/null 2>&1; then bash tests/gates/alertmanager-render-e2e.sh; \
      else echo "telegram-render-e2e" >> {{ CI_UNEVAL }}; fi
    @if command -v docker >/dev/null 2>&1; then bash tests/gates/vector-validate.sh; \
      else echo "vector-validate" >> {{ CI_UNEVAL }}; fi
    @if command -v docker >/dev/null 2>&1; then bash tests/gates/vmalert-rules-validate.sh; \
      else echo "vmalert-rules-validate" >> {{ CI_UNEVAL }}; fi
    @if command -v docker >/dev/null 2>&1; then bash tests/gates/skopeo-timeout-smoke.sh; \
      else echo "skopeo-timeout-smoke" >> {{ CI_UNEVAL }}; fi
    @if command -v node >/dev/null 2>&1; then bash tests/gates/app-shared-node-smoke.sh; \
      else echo "app-shared-node-smoke" >> {{ CI_UNEVAL }}; fi
    @if command -v curl >/dev/null 2>&1; then bash tests/gates/image-pin-liveness.sh; \
      else echo "image-pin-liveness" >> {{ CI_UNEVAL }}; fi
    @if ! command -v docker >/dev/null 2>&1; then \
      echo "vmalert-*-firing-e2e.sh 전량" >> {{ CI_UNEVAL }}; \
    else \
      hs="$(git ls-files 'tests/gates/vmalert-*-firing-e2e.sh')"; \
      n="$(printf '%s\n' "$hs" | grep -c . || true)"; \
      if [ "${n:-0}" -lt 3 ]; then echo "발화 e2e 하네스 ${n:-0}건 < 3 — 열거 붕괴(무측정 초록)" >&2; exit 1; fi; \
      echo "발화 e2e $n건 병렬 실행"; d="$(mktemp -d)"; pids=""; \
      for h in $hs; do bash "$h" > "$d/$(basename $h).log" 2>&1 & pids="$pids $!:$h"; done; \
      fail=0; \
      for p in $pids; do pid="${p%%:*}"; h="${p#*:}"; \
        if wait "$pid"; then echo "PASS $h"; else echo "FAIL $h" >&2; fail=1; fi; done; \
      for h in $hs; do echo "----- $h"; cat "$d/$(basename $h).log"; done; \
      rm -rf "$d"; exit $fail; \
    fi

    @if [ -s {{ CI_UNEVAL }} ]; then echo "SKIP: ci: 로컬에 도구가 없어 평가하지 못한 게이트 스텝이 있다 — $(tr '\n' ' ' < {{ CI_UNEVAL }})(gate에선 전부 실행된다)" >&2; rm -f {{ CI_UNEVAL }}; exit 4; fi
# [DR ④] R2 serverName pg 아카이브 정리(재구축 후 아카이빙 재개). 기본 dry-run; 실제 정리는 ARGS=--purge
reset-pg-archive:
    @scripts/reset-pg-r2-archive.sh {{ ARGS }}

# [DR] 로컬 런북 bats 실행(docs/runbooks/ — gitignored 로컬 전용, CI 미배선). 부재=SKIP
verify-runbooks:
    @if [ -d "{{ RUNBOOK_DIR }}" ] && ls {{ RUNBOOK_DIR }}/*.bats >/dev/null 2>&1; then \
      bats {{ RUNBOOK_DIR }}/*.bats </dev/null; \
    else echo "SKIP: verify-runbooks: {{ RUNBOOK_DIR }}/*.bats 0건(gitignored 로컬 전용) — 런북 회귀 미평가"; exit 4; fi

# [local] 런북 인덱스↔docs/runbooks 정합(런북 부재=SKIP — verify-runbooks와 별개)
verify-runbook-index:
    @bash scripts/verify-runbook-index.sh

# [local] 런북 token-inventory §A ↔ policy/credential-expiry.json 정합(런북 부재=SKIP)
verify-credential-inventory:
    @bash scripts/verify-credential-inventory.sh

# [live] posture 라이브 스위트(internal-by-default·netpol·e2e·DR 자산 신선도) — KUBECONFIG 부재=SKIP · 백업 경로는 SEALED_KEY_BACKUP_DIR/LOCAL_ASSET_BACKUP_DIR env(미설정=red)
verify-posture:
    @if [ -f "{{ KUBECONFIG_LIVE }}" ]; then \
      {{ ASSERT_IDENTITY_WARN }}; \
      KUBECONFIG={{ KUBECONFIG_LIVE }} bats {{ POSTURE_BATS }} </dev/null; \
    else echo "SKIP: verify-posture: {{ KUBECONFIG_LIVE }} 부재 — 라이브 posture 미평가. 먼저 just up"; exit 4; fi

# [local] KSOPS 렌더 bats(cnpg×3·cache×1) — 실 age 키 있으면 실행/부재=SKIP(.ci-exclude 그룹)
verify-ksops:
    @if [ -f "{{ SOPS_AGE_KEY_FILE }}" ]; then \
      SOPS_AGE_KEY_FILE={{ SOPS_AGE_KEY_FILE }} bats {{ KSOPS_BATS }} </dev/null; \
    else echo "SKIP: verify-ksops: {{ SOPS_AGE_KEY_FILE }} 부재 — KSOPS 렌더 미평가. SOPS_AGE_KEY_FILE 지정 후 재실행"; exit 4; fi

# 함정 원장 3종(traps.md·traps-detail.md·AGENTS 인덱스) 4방향 드리프트 가드 — guard 실재 + 원장↔SSOT 양방향 + 헤드라인 등식
verify-traps:
    @bash scripts/verify-traps.sh

# AdGuard UI 비밀번호를 bcrypt 봉인 → adguard-auth SealedSecret (seal-batch 위임)
seal-adguard-auth:
    @bun tools/seal-batch.ts --only adguard-auth

# AdGuard API 평문 비밀번호를 adguard-api-creds SealedSecret로 봉인 — rewrite 리컨실러 basic auth (seal-batch 위임)
seal-adguard-api:
    @bun tools/seal-batch.ts --only adguard-api

# telegram 봇 토큰을 argocd-notifications-secret SealedSecret로 봉인 (seal-batch 위임)
seal-argocd-notify:
    @bun tools/seal-batch.ts --only argocd-notify

# files SealedSecret 2종(keys 레지스트리 + files-ns ghcr-pull) 봉인 (seal-batch 위임)
seal-files-secrets:
    @bun tools/seal-batch.ts --group files-secrets

# GHCR read 토큰을 ghcr-pull SealedSecret 3평면(prod·files·observability) 봉인(단일 회전 타깃, seal-batch 위임)
seal-ghcr-pull:
    @bun tools/seal-batch.ts --group ghcr-pull

# GHCR read 토큰을 observability NS ghcr-read 봉인 (seal-batch 위임 — 회전은 seal-ghcr-pull이 3평면 일괄)
seal-ghcr-read:
    @bun tools/seal-batch.ts --only ghcr-read

# [DR] 선언 테이블 전 봉인본 일괄 재봉인 — sealing key 회전 드릴(owner-local 5+ 봉인본)
seal-all:
    @bun tools/seal-batch.ts --all

# [DR] 런북 tarball을 age 백업(OUT=<git 밖 경로>). --verify는 ARGS=--verify
backup-local-asset:
    @test -n "{{ OUT }}" || { echo "OUT=<git 밖 outdir> 필요"; exit 1; }
    @bash scripts/backup-local-asset.sh {{ ARGS }} "{{ OUT }}"

# [ops] ArgoCD Application 목록 — sync/health/멈춘 operation phase
argo-status:
    @{{ ASSERT_IDENTITY_WARN }}
    @KUBECONFIG={{ KUBECONFIG_LIVE }} kubectl -n argocd get applications \
      -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,OPERATION:.status.operationState.phase

# [ops] APP= 명시 sync 트리거(retry 소진 후 재시도). 예: just APP=cnpg argo-sync
argo-sync:
    @test -n "{{ APP }}" || { echo "APP=<application> 필요 (just argo-status로 이름 확인)"; exit 1; }
    @{{ ASSERT_IDENTITY }}
    KUBECONFIG={{ KUBECONFIG_LIVE }} kubectl -n argocd patch app {{ APP }} --type merge -p '{"operation":{"sync":{}}}'

# [ops] APP= 멈춘 operation 종료(phase=Terminating). 예: just APP=cnpg argo-terminate
argo-terminate:
    @test -n "{{ APP }}" || { echo "APP=<application> 필요"; exit 1; }
    @{{ ASSERT_IDENTITY }}
    KUBECONFIG={{ KUBECONFIG_LIVE }} kubectl -n argocd patch app {{ APP }} --type merge -p '{"status":{"operationState":{"phase":"Terminating"}}}'

# [ops] Application이 Healthy 될 때까지 대기(APP= 미지정 시 전체)
argo-wait:
    @{{ ASSERT_IDENTITY_WARN }}
    KUBECONFIG={{ KUBECONFIG_LIVE }} kubectl -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy application {{ if APP != "" { APP } else { "--all" } }} --timeout=300s

# [ops] COMP= KSOPS 풀 렌더(복호 읽기, 라이브 무영향). 예: just COMP=cnpg render
render:
    @test -n "{{ COMP }}" || { echo "COMP=<component> 필요 (platform/<COMP>/prod)"; exit 1; }
    SOPS_AGE_KEY_FILE={{ SOPS_AGE_KEY_FILE }} kustomize build --enable-helm --enable-alpha-plugins --enable-exec platform/{{ COMP }}/prod

# [ops] 라이브 kubeconfig export 출력 — eval "$(just kubeconfig)"로 셸에 적용
kubeconfig:
    @echo 'export KUBECONFIG={{ KUBECONFIG_LIVE }}'

# [ops] 레포 정적 드리프트 감사(registry↔매니페스트↔바인딩↔원장, 읽기 전용)
audit:
    @bun tools/audit-orphans.ts

# [ops][live] 고아 스토리지 감사(Released PV + 소비자 없는 PVC, 나열만·파괴 없음)
audit-orphan-pv:
    @{{ ASSERT_IDENTITY_WARN }}
    @KUBECONFIG={{ KUBECONFIG_LIVE }} bash scripts/audit-orphan-pv.sh

# [teardown] APP= 앱 철거(owner-local — clean-worktree·fresh-main 전용브랜치·PR). 예: just APP=foo teardown-app
teardown-app:
    @scripts/teardown.sh --app "{{ APP }}"
# [teardown] RESOURCE=<db|cache>:<name> REFS_VERIFIED=<id> 리소스 retain 철거(owner-local). 예: just RESOURCE=db:foo REFS_VERIFIED=manual-2026-06-25 teardown-resource
teardown-resource:
    @REFS_VERIFIED="{{ REFS_VERIFIED }}" scripts/teardown.sh --resource "{{ RESOURCE }}"
