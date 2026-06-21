# cache

**역할** — 앱별 경량 Valkey 캐시 계층. 공유 백업 CronJob/RBAC/NetworkPolicy를 두고, 인스턴스 디렉토리(`<name>/`)는 `tools/provision-cache.ts`가 `resources:`에 멱등 등록한다. `cache` 네임스페이스.

**싱크 Application · sync-wave** — `platform-components` ApplicationSet이 `platform/cache/prod`을 `cache-prod` Application으로 자동 발견. sync-wave 미지정 → 기본 **0**. 대상 NS `cache`는 `platform/namespaces`가 소유.

**라이브 디버그** — `argo` 스킬(sync/health), `observability` 스킬(메트릭/알림).

**함정 SSOT** — docs/traps-detail.md: appset 템플릿에 `destination.namespace`가 없어 CreateNamespace가 무효 → 대상 NS는 `platform/namespaces`가 일괄 소유. NetworkPolicy ipBlock에 pod CIDR 금지(default-deny 무력화), kube-router 룰 설치 갭(`sleep 8` 후 연결).
