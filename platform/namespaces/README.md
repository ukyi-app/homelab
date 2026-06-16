# namespaces

**역할** — appset이 발견하는 컴포넌트들의 대상 네임스페이스(gateway/edge/prod/sealed-secrets/cache 등) + PSA(Pod Security Admission) 라벨 소유. `database`는 cnpg가, `observability`는 victoria가 자체 담당.

**싱크 Application · sync-wave** — `platform-components` ApplicationSet이 `platform/namespaces/prod`을 `namespaces-prod` Application으로 자동 발견. sync-wave 미지정 → 기본 **0**.

**라이브 디버그** — `argo` 스킬(sync/health, PSA enforce 위반). PSA 검증은 `platform/namespaces/prod/test_psa.bats`.

**함정 SSOT** — AGENTS.md "라이브에서 검증된 함정": appset 템플릿에 `destination.namespace`가 없어 CreateNamespace=true가 무효("namespaces gateway not found") → 여기서 일괄 소유. PSA `baseline`도 hostPath/hostPID 금지(privileged 전용) — node-exporter/Vector류 DS는 enforce=privileged NS 필요. adguard setcap·sealed-secrets는 restricted 불가(baseline 강제).
