# 0005 — 데이터 연결을 일반 SealedSecret으로 다루고 그 잔여 위험을 감수한다

- 상태: 수용(accepted) — **완화책 1건은 여전히 미구현**(아래 「현재 상태」)
- 관련: `docs/decisions/0001-secret-management-hybrid.md`, `AGENTS.md`(멀티레포 앱 플로우),
  `tools/app-config-schema.json`, `tools/teardown-resource.ts`, `docs/runbooks/teardown-resource.md`

## 맥락

앱 계약(`.app-config.yml`)에서 `db`/`redis`/`migrate` 필드를 **전면 제거**하고, DB·캐시 연결을
일반 SealedSecret(`DATABASE_URL` 등 URL 문자열)으로만 다루기로 했다. 목표는 계약 미니멀리즘 —
모든 설정과 비밀이 `.env` → `bun run secret:seal` 한 경로로 흐른다.

설계 리뷰가 HIGH 2건을 제기했고, 그 둘은 **구조적으로 완화 불가**다: F1/F2가 요구하는 것은
"비밀 아닌 리소스 선언"인데 그게 곧 제거 대상 필드이기 때문이다. 즉 필드를 지우기로 한 이상
enforce는 성립할 수 없고 best-effort까지만 가능하다.

## 결정

**필드를 제거하고 두 위험을 informed로 감수한다.**

| # | 잔여 위험 | 완화 | 성격 |
|---|---|---|---|
| F1 | 자동 refcount가 사라져, 수동 확인을 빠뜨리면 **사용 중인 DB/캐시를 삭제**할 수 있다 | `teardown-resource`의 backup-verified 게이트(`--refs-verified` attestation) + retain 기본 + purge 4단계 상태머신 | 데이터 복구 가능성은 보장, 삭제 자체는 못 막음 |
| F2 | 과대권한 자격(예: superuser)이 앱에 봉인돼도 **정적으로 잡을 수 없다** | seal-time에 superuser-host를 거부해 명백한 사고만 차단 | **미구현** — 아래 참고 |

근거는 맥락 의존적이다: 솔로 홈랩(유일 운영자 · owner-local 수동 teardown · 소수 앱)에서
일반 플랫폼 기준의 HIGH가 실질 MED에 가깝다는 owner 판단이다. **이 전제가 바뀌면
(운영자 2명 이상, 무인 teardown, 앱 다수) 결정을 재검토해야 한다.**

## 현재 상태 — F2 완화는 아직 없다

`tools/seal-secret.mts`에 superuser/admin 검사는 **0건**이다(2026-07-30 확인). 즉 F2는
완화 없이 감수 중인 상태다. 구현하려면 미해결 질문 하나를 먼저 답해야 한다:
**거부 규칙의 host 매칭 방식** — URL의 사용자명만 볼지, host+user 조합을 볼지, admin 롤 이름
목록을 어디서 파생할지. 그 답 없이 넣으면 정당한 봉인을 막거나(false positive) 아무것도 안 막는다.

봉인 계약 자체는 `tools/lib/sealed-contract.ts`의 `readSealed`가 소유하므로, 규칙이 정해지면
그 커널에 조항으로 추가하는 것이 맞다(게이트 `check-app-deploy.sh`가 두 adapter에서 강제한다).
단 **URL 사용자명 매칭은 `readSealed`가 볼 수 없다** — 그 자리에 오는 것은 kubeseal이 끝난
`encryptedData`이므로(`tools/lib/sealed-contract.ts:20` — 정렬된 키 목록), 키명 기반 절만 그
커널에서 가능하고 값 기반 절은 앱 레포에 vendored된 `tools/seal-secret.mts`의 best-effort로만
성립한다(2026-09-03 확인). readSealed를 지목한 근거 자체는 유효하다 — homelab이 강제할 수 있는
유일한 커널이기 때문이다. 참고로 원 구현의 롤명 목록 `ADMIN_DB_USERS`는 49412fe(#126)에서
제거됐고, 그 사실을 광고하던 `platform/cnpg/prod/cluster.yaml`의 상호 포인터도 함께 정정했다.

## 기각한 대안

- **`db`/`redis`/`migrate` 유지** (설계 리뷰 권장): 자동 refcount와 최소권한 강제를 얻지만
  계약이 두 갈래(선언형 리소스 + 봉인 시크릿)로 갈린다. owner가 미니멀 일관성을 우선해 기각.
- **app-owned 프로비저닝 / 프리셋**: 이전 탐색에서 기각(앱 레포에 homelab-write 자격이 0이라는
  트리거 경계와 충돌).

## 결과

- 목표였던 "로컬 서버·GUI에서 DB 접속"은 `db:` 필드가 아니라 **접속 계층**이 제공한다
  (tailscale 직결 + `db:url` + admin superuser — 런북 `db-cache-access.md`).
- teardown 안전망은 자동에서 **절차**로 이동했다. 그 절차가 곧 안전망이므로
  `docs/runbooks/teardown-resource.md`를 건너뛰면 F1이 그대로 실현된다.
- `tools/audit-orphans.ts`의 드리프트 감사가 사후 관측을 담당한다(차단이 아니라 알림).
