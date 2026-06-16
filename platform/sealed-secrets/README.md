# sealed-secrets

**역할** — Bitnami Sealed Secrets 컨트롤러(SealedSecret CRD + 복호화). 앱/플랫폼이 봉인한 시크릿을 클러스터에서 Secret으로 푼다. sealing key는 out-of-band 백업(복구 드릴 게이트).

**싱크 Application · sync-wave** — `platform/argocd/root/apps/sealed-secrets.yaml`의 **수동 Application**(appset에서 `platform/sealed-secrets/*` 제외 — wave 제어 필요, 이중 소유 금지). **sync-wave -8**(gateway 계층): CRD+컨트롤러가 앱 시크릿 소비보다 먼저 healthy여야 한다.

**라이브 디버그** — `argo` 스킬(sync/health, 컨트롤러 복호화 실패 진단). 봉인 절차는 런북 `docs/runbooks/app-platform.md`, 키 모델은 `docs/runbooks/age-keys.md`.

**함정 SSOT** — AGENTS.md "라이브에서 검증된 함정": helm 차트 CRD가 `crds/`에 있으면 kustomize HelmChartInflationGenerator 기본 렌더에서 빠짐 → `includeCRDs: true` 필수(sealed-secrets에서 검증). SealedSecret strict-scope는 봉인 시점 namespace 일치 필요(data-conn 참조).
