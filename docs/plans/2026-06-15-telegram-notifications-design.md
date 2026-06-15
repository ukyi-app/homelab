# 설계: 텔레그램 알림 한국어화 · 일관성 통일 (v1)

- 날짜: 2026-06-15
- 상태: 승인됨 (brainstorming Phase A 완료 — 다관점 적대 비평으로 재설계 후 승인)
- 후속: writing-plans → codex 적대적 리뷰 (hardened-planning Phase C)
- 브랜치: `feat/telegram-notifications` (main 분기)

## 1. 배경과 원래 요청

원래 요청: **"텔레그램으로 오는 메시지를 (1) 기본 한국어로, (2) 전체적으로 일관성 있게,
(3) 추가로 좋은 방법이 있으면."**

현황(탐색으로 확정) — 봇 1개 + chat_id 1개(**봇과 1:1 DM**), 토픽 없음. 세 transport가 한 채팅으로 수렴:

| 발신처 | 트리거 | 언어 | 포맷 |
|---|---|---|---|
| **Alertmanager v0.27.0** (victoria-stack, 규칙 ~10개) | vmalert 발화, `send_resolved:true` | **100% 영어** (한국어는 주석뿐) | HTML, 중앙 Go-template, 본문=규칙 annotation |
| **CNPG restore-drill** CronJob (매주 일 05:00 KST) | PASS/FAIL | 영어 | HTML, `[restore-drill] 🟢/🔴 …` 인라인 curl |
| **GitHub Actions** (11개 워크플로 12스텝) | 9/12가 `always()` | **혼용** | **parse_mode 없음(평문)**, 호출처마다 ad-hoc |

핵심 불일치: 알림 본문 영어 / parse_mode HTML vs 평문 / 상태어휘 3종(`success·failure` vs
`FIRING·RESOLVED` vs `PASS·FAIL`) / 이모지·접두사 제각각 / 링크 누락 / `_teardown`의
`${APP}${RESOURCE}` 연결 버그.

## 2. 의사결정 기록 — "이게 최선?" → 과설계 절반 제거

초안은 **포럼 슈퍼그룹 + 토픽 3개 + `message_thread_id` + Alertmanager v0.27→v0.28 업그레이드 +
chat_id 3곳 cutover**를 포함했다. 사용자의 "이게 최선이야?" 질문에 따라 설계를 방어하지 않고
**4관점(과설계·아키텍처·홈랩제약·목표적합) 독립 적대 비평 → 각 지적 재검증 → 판정** 워크플로로
재평가했다(27건 중 25건 검증 통과, 판정 = **over-engineered**).

**유지(earned core):** composite action 1개로 13개 인라인 curl 통합 / 규칙 annotation 한국어화 /
통일 계약(HTML·이스케이프) / shared 셸 헬퍼 / 구조 불변식 bats 게이트.

**제거(gold-plating — 두 목표 어느 쪽도 진전 없이 위험만 추가):**
- 포럼 슈퍼그룹 + 토픽 3개: 혼자 한 채팅을 읽는 운영자에게 필터 가치 ≈ 0.
- v0.27→v0.28 업그레이드: 토픽(`message_thread_id`, **v0.28부터** 지원)을 위한 것일 뿐 —
  페이징 데몬을 단일 노드에서 메이저 업그레이드하는 위험을 문자열 변경에 묶음.
- chat_id cutover(2 SOPS 번들 + 1 Terraform 프로비전 GH secret): 작동 중인 DM을 옮길 이유 없음.
- thread_id를 시크릿 번들에: 비민감 정수인데 SOPS 재암호화 churn 유발.
- Phase 0 수동 의식: **VM 재구축 때 git으로 복원 안 되는 새 DR 표면**(이 레포는 막 풀 DR 드릴 통과).

**추가(비평이 잡은 더 값진 것):**
- 🔴 **상태 "단어"가 영어로 샌다** — 모든 메시지의 최빈 토큰(`job.status`/`FIRING`/`RESOLVED`)이
  한국어 제목 위에 영어로 남아 **목표 ①을 절반만 달성**. → 한국어 상태 lexicon을 계약의 핵심으로.
- 🔴 **알림기 자기 관측 부재** — AM 파드에 `prometheus.io/scrape`가 없어
  `alertmanager_notifications_failed_total`이 TSDB에 부재 → 레포가 **자기 AGENTS.md 검증 규칙도
  못 지킴**. 텔레그램 침묵 실패(시스템이 막으려는 바로 그 실패)가 안 보임.
- composite action은 **best-effort 전송**이어야 함(아래 §5).
- 골든 바이트비교 픽스처는 과함(레포에 골든 0개, 26개 bats 전부 구조 검사) → house idiom.

**비평 중 기각된 2건(재검증으로 무효):**
- "TF_VAR_telegram_* 중복 = 죽은 설정, 제거" → **거짓**. `infra/github/secrets.tf:6-14`가
  `var.telegram_bot_token`/`var.telegram_chat_id`를 소비해 GH Actions secret을 프로비저닝한다.
  **제거 시 CI 알림 전부 깨짐.** → TF_VAR 쌍은 **유지**, `.env.secrets.example`의 이중입력
  footgun만 정리.
- "정기 토픽 self-DoS" → tf-reconcile은 failure()-OR-drift 게이트라 무발화 시 조용함(과교정).

## 3. v1 설계 — v0.27·기존 DM 그대로, 시크릿 스토어 0 변경

목표 분담: 채널/인프라 변경 없이 **문자열·포맷·관측**만 손대 두 목표를 완전 달성.

### 3.1 메시지 계약 (SSOT 명명: "1 계약 명세 + 3 준수 렌더러, CI 게이트")

`parse_mode=HTML`, 고정 필드 순서:
```
{글리프} <b>{한국어 제목}</b> — {한국어 상태}
{발신처 라벨} · {핵심 식별자}
{키}: {값}
{키}: {값}
→ {액션 링크}        ← 가능한 경우 항상(run URL / PR URL / 런북·대시보드)
```
- 동적 값은 **모두 HTML 이스케이프**(`< > &`). 비신뢰 `client_payload`(bump dispatch)는
  **env 경유 + 정규식 검증**(AGENTS.md: 인라인 보간 금지).
- 정확한 카피는 lint가 강제하지 않음(구조 불변식만) — 문구 조정이 테스트를 깨지 않게.

### 3.2 한국어 상태 lexicon (계약의 핵심 — 글리프와 **단어**를 함께)

| 원천 상태 | 한국어 | 글리프 |
|---|---|---|
| `success` / `PASS` | 성공 | ✅ |
| `failure` / `FAIL` / `FIRING`(critical) | 실패/발생 | 🔴 |
| `FIRING`(warning) / drift | 경고 | ⚠️ |
| `RESOLVED` | 해소 | 🔵 |
| `cancelled` | 취소 | ⚪ |
| `skipped` | 건너뜀 | ⚪ |

- AM 템플릿: `{{ .Status }}` → 발생/해소 매핑. CI: `job.status` → 성공/실패/취소/건너뜀.
  drill: PASS/FAIL → 성공/실패. **세 transport가 동일 lexicon 사용**(아래 렌더러 위치 참조).
- 발신처 라벨(한국어): 알림 / 복원드릴 / 앱생성 / DB생성 / 캐시생성 / 시크릿갱신 / 해체 /
  배포 / 온보딩 / IaC / IaC수렴 / 감사 / 이미지폴링 / 변이. 긴급도는 선두 글리프로 구분.

### 3.3 컴포넌트별 변경

**a. GitHub Actions composite action** `.github/actions/telegram-notify/`
(레포의 기존 `.github/actions/homelab-token` 컨벤션 준수)
- 입력: `source, status, severity, title, fields, url, token, chat_id` — **`thread_id` 없음**.
- §3.1/3.2 계약대로 HTML 렌더·이스케이프·전송. lexicon은 액션 내부 문자열 테이블에 중앙화.
- **best-effort 전송**: curl 출력 캡처 → 비-2xx는 로그/스텝 annotation(warning) → **exit 0**.
  (현 12스텝은 bare `curl -fsS`라 일시 4xx/5xx가 *실패 알림 스텝 자체를 죽임* — 단일화로
  blast radius가 커지므로 반드시 best-effort.)
- 입력 enum 방어 검증(오타 status → 일반 메시지로 degrade, abort 금지).
- 13개 인라인 curl(12 GH 스텝)을 이 액션 호출로 치환. **`_teardown`의 `${APP}${RESOURCE}`**는
  채워진 쪽만 `app=`/`resource=` 라벨로 렌더(버그 수정, bats로 회귀 잠금).

**b. restore-drill 공유 셸 헬퍼** (`platform/cnpg/prod/restore-drill-script.sh`의 `notify()`)
- §3.1/3.2 계약 렌더 + 한국어 상태. `DRY_RUN` 출력 모드(골든 없이 구조 단언용).
- 기존 `|| true` swallow 유지(텔레그램 장애가 드릴을 깨지 않게).

**c. Alertmanager 규칙 annotation 한국어화 + 템플릿 제자리 재작성 (v0.27 유지, 업그레이드 없음)**
- `platform/victoria-stack/rules/{core,r4-storage-backup,r6-ci-staleness}.yaml`의
  `summary`/`description`을 한국어로(메트릭명·alertname·식별자 영문 유지) — 알림 한국어가
  **테스트 가능한 YAML**에 살게.
- `platform/victoria-stack/alertmanager.yaml`의 `message:` Go-template를 §3.1 계약 구조로
  제자리 재작성(글리프 + bold 한국어 제목 + 발신처/식별자 + 본문). `.Status` → 발생/해소.
- HTML 이스케이프는 **Go 템플릿 함수**로(init `sed` 아님). 라우트/receiver 구조 무변경
  (단일 telegram receiver, 단일 chat_id 유지).

**d. 알림기 자기 관측 (토픽 마이그레이션 대신 노력 재배치)**
- AM 파드에 `prometheus.io/scrape: "true"` 애너테이션(vmagent가 수집하도록) →
  `alertmanager_notifications_total{integration="telegram"}` / `..._failed_total` TSDB 적재.
- 새 규칙: `increase(alertmanager_notifications_failed_total{integration="telegram"}[15m]) > 0` 알림.
- Watchdog 커버리지 경계 문서화: Watchdog→deadmanswitch→healthchecks는 **AM 파이프라인 생존만**
  증명, **텔레그램 전송/CronJob/GH transport는 커버 안 함**(NOTES.md 또는 규칙 주석).

### 3.4 회귀 게이트 (house idiom — 골든·라이브목 없음)

레포의 26개 bats가 전부 구조 검사인 관례를 따른다(골든 바이트비교 0개):
1. **구조 불변식 bats**(`tools/test/telegram-*.bats`): composite action·drill `notify()`를 `DRY_RUN`
   렌더 → `parse_mode=HTML` 존재 / 글리프 ∈ 허용집합 / 한국어 제목 비-ASCII / 링크 존재 단언.
   `_teardown` 라벨 분리 회귀 잠금. **중간 단언은 `[ ]`**(bash 3.2 `[[ ]]` 침묵통과 함정 회피),
   `@test` 이름은 영어.
2. **규칙 한국어 단언**: core/r4/r6 annotation이 한국어 산문·필수 필드를 만족하는지.
3. **`amtool check-config`**: 핀된 **v0.27** 이미지로 재작성 템플릿/설정 유효성 검증
   (CI 컨테이너 스텝). KSOPS 풀 렌더는 AGENTS.md의
   `kustomize build --enable-helm --enable-alpha-plugins --enable-exec`로.
- `make verify` / `make chart-test` green 유지.

### 3.5 부수 정리
- `.env.secrets.example`: 같은 값 이중입력 footgun 정리(주석 명확화 또는 한쪽을 다른 쪽에서 파생).
  **`TF_VAR_telegram_*` 쌍은 유지**(secrets.tf가 GH secret 프로비저닝에 소비).
- 선택적 KST 타임스탬프: 셸 경로(composite action·drill)에서 `TZ=Asia/Seoul date '+%m/%d %H:%M'`.
  AM은 v0.27 유지로 생략(가치 낮음 — 텔레그램 자체 전송시각이 근사).
- `_audit` 요약 길이 캡(텔레그램 4096 한도): `…(생략 N건)`으로 절단.

## 4. 비목표 (명시)

- 포럼 슈퍼그룹·토픽·`message_thread_id` 도입 ✗
- Alertmanager v0.27→v0.28 업그레이드 ✗
- chat_id 마이그레이션(DM→슈퍼그룹), thread_id 시크릿 추가 ✗
- Phase 0 수동 의식 ✗
- `TF_VAR_telegram_*` 제거 ✗ (CI 알림 프로비저닝에 소비 — 제거 시 파손)
- 골든 바이트비교 픽스처 / 라이브 mock-api_url 테스트 ✗
- AM 라우트/receiver 구조 변경, send_resolved 정책 변경 ✗
  (FIRING+RESOLVED 동일 목적지 유지 — 느린·끈끈한 백업/디스크/staleness 알림이라 RESOLVED는
  유용한 stand-down 신호; flapper 아님)

## 5. 미래 분리 작업 (지금 안 함 — 토픽이 정말 필요해지면 독립·게이트 PR)

슈퍼그룹 + v0.28 업그레이드 + 토픽 receiver(스레드별) + chat_id cutover +
**스레드별 라이브 스모크 + 합성 하트비트**(침묵실패 검출). 이때 `message_thread_id`는 작은 추가
단계이며, 본 일관성 작업에 엉키지 않는다.

## 6. 위험 등록부

| # | 위험 | 완화 |
|---|---|---|
| R1 | composite action 단일화 → 버그 시 12 워크플로 알림 동시 파손 | best-effort 전송(exit 0 + warning annotation) + enum 방어검증 + 구조 bats |
| R2 | 3 렌더러(Go-template·POSIX셸·composite셸) 독립 드리프트 | "1 계약 명세 + 3 준수 렌더러, CI 게이트"로 정직히 명명; 구조 불변식 bats가 3곳 모두 단언 |
| R3 | HTML 이스케이프 이식성(busybox/POSIX vs Go 템플릿) | AM은 Go 템플릿 함수로, 셸은 POSIX sed/tr, **모든 이스케이프를 DRY_RUN bats로 검증**(busybox 1.36 GNU 확장 가정 금지) |
| R4 | 페이징 경로(AM 템플릿)가 가장 load-bearing인데 테스트 어려움 | 한국어를 규칙 annotation(YAML)에 두어 단언 가능 + `amtool check-config` + 템플릿 분기 구조 단언 |
| R5 | `_audit` 무제한 요약 → 4096 초과 시 `curl -f` 스텝 실패 | 길이 캡 `…(생략 N건)` |
| R6 | 자기관측 추가가 victoria-stack 단일 Application sync에 포함 | 애너테이션·규칙 추가만(워크로드 스키마 무변경), KSOPS 풀 렌더로 사전 검증 |

## 7. 데이터 흐름 (변경 후)

```
vmalert ─fire─▶ Alertmanager(v0.27, 단일 receiver) ─HTML 계약─▶ Telegram DM
                     └─Watchdog─▶ deadmanswitch ─▶ healthchecks (AM 생존만)
CronJob(주1) ─▶ notify()[공유 셸 헬퍼, 한국어 lexicon] ─HTML 계약─▶ Telegram DM
GH Actions job ─▶ telegram-notify[composite action, best-effort] ─HTML 계약─▶ Telegram DM
vmagent ─scrape─▶ AM /metrics ─▶ alertmanager_notifications_failed_total ─▶ 전송실패 알림
```

## 8. 롤아웃 · 롤백

- 단일 저위험 PR(PR-first + auto-merge, 레포 규약). 시크릿/이미지/채널 변경 0 → sync 위험 최소.
- 검증: `make verify`/bats green → ArgoCD sync → 의도적 테스트 알림 1건으로 한국어·HTML 도달 확인
  + `alertmanager_notifications_failed_total == 0` 확인(AGENTS.md 검증법).
- 롤백 = revert 커밋(설정·문자열만이라 안전, 인프라 상태 무변경).
