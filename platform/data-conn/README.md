# data-conn

**역할** — 앱 소비용 DB/캐시 conn SealedSecret 컴포넌트(`prod` 네임스페이스). `create-database`/`create-cache` 산출물 전용. `resources`는 `tools/provision-db.mjs`(이후 `provision-cache.mjs`)가 멱등 등록 — 빈 resources여도 kustomize build는 성공해야 한다.

**싱크 Application · sync-wave** — `platform-components` ApplicationSet이 `platform/data-conn/prod`을 `data-conn-prod` Application으로 자동 발견. sync-wave 미지정 → 기본 **0**. 대상 NS는 kustomization이 `prod` 지정.

**라이브 디버그** — `argo` 스킬(SealedSecret 복호화/sync 상태). 봉인 절차는 런북 `docs/runbooks/app-platform.md` 참고.

**함정 SSOT** — AGENTS.md "라이브에서 검증된 함정": SealedSecret strict-scope는 봉인 시점 namespace와 일치해야 복호화 → conn 핸들은 `database`가 아닌 `prod` NS로 분리(cnpg 쪽에 두면 영구 복호화 실패). `*.enc.yaml`/봉인 시크릿은 직접 수정 금지.
