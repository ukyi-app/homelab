# 데이터 연결 = secret — 앱 플랫폼 계약 미니멀화 설계 (최종)

- **날짜**: 2026-06-25
- **상태**: 설계 확정(A.5 리뷰 반영 + 잔여 위험 informed 감수) → hardened-planning Phase B/C
- **선행**: `env` 평문 메커니즘 제거 (PR #113 homelab / #3 template, 진행 중)

> **결정 요지**: owner가 `.app-config.yml`에서 `db`/`redis`/`migrate`(+선행 `env`)를 **전면 제거**하고
> 연결을 일반 SealedSecret(URL)으로 다루기로 **명시적·반복적으로** 선택했다. codex A.5 설계 리뷰가
> HIGH 2건(teardown 안전망 상실·최소권한 강제 불가)+MED 1건(self-migration skew)을 제기했고, owner는
> 이를 **확인한 뒤** "필드 제거 + 최대 완화 + 잔여 위험 감수"를 선택했다(§7 informed 감수 기록).
> 구조적 사실: F1/F2가 요구하는 "비밀 아닌 리소스 선언"은 곧 제거 대상 필드라 **양립 불가** →
> 완화는 enforce가 아니라 best-effort까지만 가능하다.

## 1. 배경 & 동기

- **계약 미니멀리즘** — 모든 설정/비밀을 `.env`→`secret:seal`(SealedSecret) 한 경로로(env 제거와 동일 철학).
- **로컬 서버에서 DB 연결** + **GUI(TablePlus) 열람/편집** — tailscale 망 직결. ← owner의 진짜 목표.

핵심: 목표(로컬/GUI)는 `db:` 필드가 아니라 **접속 계층(tailscale+db:url+admin)**이 제공한다. 필드 제거는
"미니멀"을 위한 선택이며, 그 대가(자동 안전망 상실)는 §7에서 informed로 감수한다.

## 2. 목표 / 비목표

**목표**
- `.app-config.yml`에서 `db`/`redis`/`migrate` 필드 제거(연결=앱 SealedSecret의 `DATABASE_URL`/`REDIS_URL`).
- 로컬 개발 + GUI 접속을 tailscale로 1급 지원.
- Postgres admin superuser 한 로그인으로 전 db GUI 열람.
- A.5 발견을 **가능한 선까지 완화**(enforce 불가, best-effort).

**비목표**
- create-database/create-cache 프로비저닝 폐지 아님(논리 DB/Valkey + 자격 생성 유지 — URL의 출처).
- 멀티-DB 공유·앱당 다중 유지.

## 3. 모델: 연결 = secret

```yaml
# .app-config.yml — 최종 (env/db/redis/migrate 전부 없음)
kind: service
resources: { requests: {...}, limits: {...} }
route: { public: false }
secrets: [orders-secrets]      # 이 봉인본에 DATABASE_URL / REDIS_URL 포함
deploy: { autoDeploy: true }
```
```js
new Pool({ connectionString: process.env.DATABASE_URL })   // 로컬·클러스터 동일
```

- **출처**: `create-database`/`create-cache`는 그대로 관리형 conn secret 생성(URL의 권위 출처).
- **앱 소비**: owner가 `db:url`/`cache:url`로 URL을 받아 앱 `.env`에 `DATABASE_URL`/`REDIS_URL`로 두고
  `secret:seal`로 봉인 → `secrets:` envFrom으로 클러스터 배선. (자격 중복 = 관리형 conn + 앱 봉인본 → 회전 시 re-seal, §6.)
- **로컬/GUI**: tailscale 노출 + db:url(.env.local) + admin superuser.

## 4. 결정 요약

| # | 항목 | 결정 |
|---|---|---|
| 1 | `env` | 제거(선행 PR #113) |
| 2 | `db`/`redis` 필드 | **제거** — 연결을 앱 SealedSecret으로 |
| 3 | `migrate` 필드 + migrate Job | **제거** — 앱이 부팅 시 self-migrate(expand/contract 강제) |
| 4 | refcount 머신러리 | **축소** — `.bindings.json`은 `autoDeploy`만, teardown refcount/audit dangling-binding 제거 |
| 5 | Postgres tailscale 노출 | **추가** |
| 6 | admin superuser 롤 | **추가**(백업 pg-superuser와 분리) |
| 7 | `db:url`/`cache:url` 재작성 | RO/RW + tailscale host → `DATABASE_URL`/`REDIS_URL` 기록 |
| 8 | A.5 완화 3종 | **추가**(best-effort — §5.8) |

## 5. 상세 설계

### 5.1 `migrate` 제거 (PR-A)
- schema `migrate` 삭제, create-app `db.enabled` 분기 제거, 차트 `migrate-job.yaml` 삭제, values `db.*` 제거, 관련 차트 bats 정리.
- 앱은 부팅 시 self-migrate(직결 URL로). **계약 문서에 expand/contract + 멱등 필수 명문화**(F3 완화).

### 5.2 `db`/`redis` 제거 + 연결=secret (PR-B)
- schema `db`/`redis` 삭제, create-app의 db/redis envFrom·pre-existence·tombstone 가드 제거.
- `.bindings.json` = `{ autoDeploy }`만(db/redis 키 제거). `app-deploy-schema.json` 갱신.
- `env-example.mts` db/redis 스캐폴딩 제거(env 이미 제거됨).

### 5.3 refcount 축소 (PR-B)
- `teardown-resource.ts`: `.bindings.json` 참조 0 게이트 제거. **purge 상태머신 + `--backup-verified` 게이트는 유지**(데이터 삭제 안전은 별개 — F1 완화의 핵심).
- `audit-orphans.ts`: `dangling-binding`(db/redis) 제거.

### 5.4 Postgres tailscale 노출 (PR-C)
- `pg-rw` Service tailscale 노출(LoadBalancer/operator) → tailnet `*.ts.net`:5432.
- netpol: tailscale proxy→pg(5432)만. tailscale ACL: owner 기기만.

### 5.5 admin superuser 롤 (PR-C)
- `cluster.yaml` managed role(`superuser:true`,login)+SealedSecret 비번, 백업 pg-superuser와 분리. GUI 전용. (Valkey는 per-instance — 전 캐시 admin 없음.)

### 5.6 `db:url`/`cache:url` 재작성 (PR-C)
- `--rw` + tailscale host + 출력 키 `DATABASE_URL`/`REDIS_URL`. 평문 stdout 금지 → `.env`/`.env.local`. `db:url --admin`(GUI superuser URL, 봉인 안 함).

### 5.7 로컬 개발
- 모드1 `pnpm dev db:up`(docker), 모드2 `pnpm db:url`(tailscale RO), GUI=admin/per-instance. 로컬·클러스터 변수명 동일.

### 5.8 A.5 완화 3종 (best-effort — enforce 불가 명시)
- **F1(teardown)**: `--backup-verified` purge 게이트 유지 + 런북 "삭제 전 사용 앱 수동 확인" 명문화. **자동 refcount 없음 → 잔여 위험(§7).** (audit는 봉인 내 의존을 못 봐 경고 불가.)
- **F2(최소권한)**: `seal-secret.mts`에 **seal-time 체크** — 봉인 직전 평문 .env 값이 admin/superuser host를 가리키면 거부/경고(로컬 best-effort, 우회 가능). 봉인 후 값은 CI에서 검증 불가 → **잔여 위험(§7).**
- **F3(skew)**: self-migrate expand/contract + 멱등 **문서 강제**(가능하면 lint). ordered Job 없음 → 규칙 준수 의존.

## 6. 운영 비용 (informed)

- **자격 중복/rotation drift**: 연결 URL이 관리형 conn + 앱 봉인본 두 곳 → 회전 시 re-seal. 런북화.
- **수동 teardown 규율**: 리소스 삭제 전 사용 앱 수동 확인(자동 차단 없음).

## 7. 잔여 위험 — informed 감수 기록

owner가 A.5 HIGH 발견을 확인한 뒤 "필드 제거 + 최대 완화"를 선택. 남는 위험:
- **F1**: 수동 확인 누락 시 사용 중 DB/캐시 삭제 가능(완화: backup-verified 게이트가 데이터 복구 가능성 보장).
- **F2**: 비-superuser 과대권한 자격이 앱에 봉인돼도 정적으로 못 잡음(완화: seal-time superuser-host 거부는 명백한 사고만 차단).
- 근거: 솔로 홈랩(유일 운영자, owner-local 수동 teardown, 소수 앱) 맥락에서 일반 플랫폼 HIGH가 실질 MED 수준 + 위 완화로 감수 가능하다는 owner 판단.

## 8. 기각 대안
- **db/redis/migrate 유지(A.5 권장)**: owner가 미니멀 일관성 우선 + 잔여 위험 informed 감수로 기각.
- self-migration only는 §5.1, app-owned/프리셋은 이전 탐색에서 기각.

## 9. 구현 시퀀싱
1. **PR-A — `migrate` 제거** (소·독립; env PR #113 머지 후 리베이스)
2. **PR-B — `db`/`redis` 제거 + refcount 축소 + F1/F2/F3 완화** (계약 핵심·안전 영향)
3. **PR-C — tailscale pg 노출 + admin superuser + db:url/cache:url 재작성** (보안 민감)

## 10. 영향 표면
- 툴: `app-config-schema.json`, `create-app.ts`, `env-example.mts`, `db-url.ts`/`cache-url.ts`, `teardown-resource.ts`, `audit-orphans.ts`, `seal-secret.mts`(F2 체크), `app-deploy-schema.json`
- 차트: `migrate-job.yaml`(삭제), `deployment.yaml`, `values.yaml`, `values.schema.json`, 차트 bats
- CNPG/네트워크: `cluster.yaml`(admin role), `networkpolicy.yaml`, tailscale Service, `infra/tailscale`(ACL)
- 문서/테스트: 템플릿 README, tools/README, 런북, create-app/teardown/audit bats

## 11. 미해결 질문 (Phase B/C 입력)
1. F2 seal-time 체크의 정확한 거부 규칙(host 매칭 방식).
2. teardown 런북 수동 확인 절차의 구체 형식.
3. admin superuser URL 추출 권한 모델.
4. Valkey GUI: per-instance tailscale 상시 vs on-demand.

## 설계 리뷰(A.5) dispositions
codex `--kind design` base HEAD~1, verdict=needs-attention, 3 findings:
- **F1 (HIGH) opaque deps → teardown 위험**: **수용(완화)** — 자동 refcount 제거, backup-verified 게이트+런북으로 완화, 잔여 위험 informed 감수(§7).
- **F2 (HIGH) 최소권한 강제 불가**: **수용(완화)** — seal-time superuser-host 거부(best-effort), 잔여 위험 informed 감수(§7).
- **F3 (MED) self-migration skew**: **수용** — expand/contract+멱등 문서 강제(§5.1·5.8).
