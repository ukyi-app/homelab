# Runbook — App onboarding (the deploy chain)

Onboarding a service is a `values.yaml` for the shared chart `platform/charts/app`.
Nothing else is hand-written.

## 외부 앱 레포 방식 (권장 — 멀티레포 앱 플랫폼)

앱 코드는 **별도 레포**(org `ukyi-app`)에 살고, homelab에는 배포 설정(`apps/<name>/deploy/prod/`)만 남는다.

```
[1회] gh repo create ukyi-app/<name> --template ukyi-app/homelab-app-template
      $EDITOR .homelab.yaml   # kind/resources/route/db/env/secrets — 계약: tools/homelab-app-schema.json
      git push                # 첫 push:
        → reusable-app-build@main: arm64 빌드 → ghcr.io/ukyi-app/<name>:sha-<sha>
        → homelab에 deploy 디렉토리 없음 → repository_dispatch(app-onboard, .homelab.yaml 동봉)
        → homelab onboard.yaml: tools/onboard-app.mjs 검증(스키마·host 유도·env 시크릿 패턴·원장 예산)
          → 스캐폴드(values.yaml + source-repo + KSOPS generator) + 원장 행 → 렌더/ledger 게이트 → 자동 PR
      PR 머지(= 첫 배포 승인; secrets 선언 시 enc 파일을 PR 브랜치에 먼저 커밋 — 체크리스트 참조)
        → ArgoCD appset이 발견 → wave0 config → wave1 migrate → wave2 deploy → 라이브

[반복] 앱 레포 main 머지
        → 빌드 → repository_dispatch(app-image)
        → homelab bump.yaml(직렬): app명 regex + source-repo 바인딩 + GHCR digest 검증 → 태그 bump commit
        → Telegram 알림 → ArgoCD sync (머지→라이브 약 4–7분)
```

전제(1회 설정): org secret `HOMELAB_DISPATCH_PAT`(fine-grained, homelab Contents:write),
homelab repo variable `HOMELAB_DOMAIN`(apex 도메인), 머지 게이트가 싫은 앱은 `.homelab.yaml`의
`deploy.autoDeploy: false` + 앱 레포 environment `production`에 required reviewer 등록.

## 내부(monorepo) 방식 — 기존 샘플 앱(api/worker/web/console)용

## The chain
```
pnpm gen:app <name> --kind api|worker|ssr|spa     # scaffolds apps/<name>/{src,Dockerfile,deploy/prod/values.yaml} + CI matrix entry
# add the app's own SOPS secret: apps/<name>/deploy/prod/<name>-secrets.enc.yaml
#   + a co-located secret-generator.yaml (KSOPS) + kustomization.yaml (M3 appset source #3)
pnpm gen:env <name>                               # regenerate apps/<name>/.env.example (CI drift-checks it)
git push origin main
#  → build.yaml: native arm64 buildx → ghcr.io/<owner>/<name>:sha-<gitsha>  (only changed apps)
#  → bump.yaml (serialized): verifies the :sha digest exists, write-backs apps/<name>/deploy/prod/values.yaml
#  → ArgoCD `apps` ApplicationSet (M3) renders the shared chart with the app values → syncs to ns prod
pnpm verify:app <name>                            # build→push→tag→sync→probe→route→secret; stops at the FIRST red link
```

## Wave ordering (canonical registry: platform/argocd/root/SYNC-WAVES.md)
```
CNPG-Ready gate  (cnpg-data Application Healthy; enforced per-app by the chart's wait-for-db initContainer)
  → wave 0   ConfigMap / Secret (app config)
  → wave 1   migration Job  (argocd.argoproj.io/hook: Sync — runs in the Sync phase, AFTER wave-0 config)
  → wave 2   Deployment / Service / HTTPRoute (attaches to the shared homelab Gateway)
```
ArgoCD sync-waves order resources WITHIN one Application; cross-Application DB readiness is
NOT a sync-wave — the migration Job's `wait-for-db` initContainer (`pg_isready`) is the gate.

## R6 staleness / failure path
- A push that builds but whose write-back fails → `bump.yaml`'s `if: always()` Telegram step pages.
- An app stuck OutOfSync >15m → M5's `ArgoCDOutOfSync` alert; running-digest != latest-GHCR-digest →
  M5's `ImageDigestDrift`. `pnpm verify:app` catches the placeholder-tag (`sha-0000000`) case locally.

## Memory gate
Per-runtime memory limit is a hard onboarding gate: the chart `values.schema.json` rejects an
empty `resources.*.memory` at render time, and `pnpm verify:ledger` (M0) fails if the summed
limits in `docs/memory-ledger.md` exceed the budget.
