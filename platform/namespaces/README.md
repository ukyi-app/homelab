# namespaces

**역할** — appset이 발견하는 컴포넌트들의 대상 네임스페이스(gateway/edge/prod/sealed-secrets/cache 등) + PSA(Pod Security Admission) 라벨 소유. `database`는 cnpg가, `observability`는 victoria가 자체 담당.

**싱크 Application · sync-wave** — `platform/argocd/root/apps/namespaces.yaml`의 **수동 Application `namespaces`**(appset에서 `platform/namespaces/*` 제외 — wave 제어 필요, 이중 소유 금지). 값은 그 매니페스트가 소유한다: **sync-wave -9** — 규칙은 **bare ns + PSA 라벨이 그것을 소비하는 컴포넌트보다 먼저** 선다는 것이라 sealed-secrets/traefik(-8)보다 앞이다. resources-finalizer 없음 — Namespace cascade 삭제 금지(삭제/롤백 시 orphan-retain).

**라이브 디버그** — `argo` 스킬(sync/health, PSA enforce 위반). PSA 검증은 `platform/namespaces/prod/test_psa.bats`.

**함정 SSOT** — docs/traps-detail.md: appset 템플릿에 `destination.namespace`가 없어 CreateNamespace=true가 무효("namespaces gateway not found") → 여기서 일괄 소유. PSA `baseline`도 hostPath/hostPID 금지(privileged 전용) — node-exporter/Vector류 DS는 enforce=privileged NS 필요. adguard setcap·sealed-secrets는 restricted 불가(baseline 강제).
