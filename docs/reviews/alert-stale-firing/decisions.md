# 결정 원장 — alert-stale-firing

## 범위 승인 (Stage 1 게이트, 2026-07-30)

진단이 **두 개의 독립 근본 원인**을 확정했고, `/bugfix`의 "정확히 하나의 관찰 가능한 동작이 flip"
제약을 넘는다는 점을 사용자에게 제시했다. 선택지는 (a) 두 결함 모두 이번에 수정 (b) 결함별로 나눠
순차 진행 (c) 결함 B만 (d) 결함 A만 이었다.

**사용자 결정: (a) 두 결함 모두 이번에 수정** — 단일 flip 제약을 명시적으로 완화하는 것에 동의.
근거: 두 결함이 같은 증상(알림 오탐 반복)을 내고, 사용자가 겪는 문제는 **둘 다 고쳐야** 멈춘다.
회귀 테스트는 결함별로 별도 seam에 둔다(공통 테스트로 묶지 않는다).

**사용자 결정: 즉시 완화 승인** — 근본 수정 배포 전까지 3일 묵은 실패 Job(`edge/adguard-rewrite-
reconciler-29751320`)을 삭제해 발화를 즉시 중단. 실행 완료(클러스터 실패 Job 0건). 그 Job의 로그와
실패 원인은 `diagnosis.md`에 보존했으므로 삭제로 잃은 정보는 없다.

**범위에서 의도적으로 제외**: adguard 리컨실러의 `curl --retry`가 DNS 해석 실패(exit 6)를 재시도하지
않는 문제. 진단서가 근본 원인이 아니라 **기여 요인**으로 분류했고, 세 번째 동작 flip이라 승인 범위 밖이다.
이번 수정으로 그 실패가 영구 알림이 되지는 않지만(억제가 다음 성공에 걸린다) 실패 자체는 여전히 15분간
페이징한다 → 별도 후속 대상.

## 자체 감사 (release r1 수정 직후, 4개 독립 렌즈 + 반증 라운드 — 22 에이전트)

라운드 2 게이트 전에 R-2 수정 자체를 적대 검토했다. 18건 제기 · **생존 12건** · 반증 6건.
중복을 접으면 실질 7건이고, 대부분 **회귀 하네스가 광고한 락을 실제로는 갖지 않는다**는 것이었다 —
전부 뮤테이션 실측으로 입증됐다(주장이 아니라 검사).

- S-1/S-5/S-11 accept — L4가 `owner_kind="CronJob"` 좁힘을 전혀 잠그지 못한다. standalone 픽스처가
  `kube_cronjob_status_last_successful_time`을 아예 안 내보내 억제식 우변이 빈 벡터였고, 그래서
  **필터를 지워도 6/6 green**이었다. 하네스 헤더와 룰 주석 둘 다 갖지 않은 락을 광고했다.
  → 픽스처가 억제 재료를 **전부 갖춘 채** owner_kind만 다르게(`Workflow`, owner_name은 CronJob과 동일)
    두도록 재설계. 이제 필터를 지우면 red다.
- S-2 accept — 조인 키 granularity 미검증. 각 시나리오에 실패 Job이 하나뿐이고 ns도 하나라
  `unless on (namespace, job_name)` → `on (namespace)`로 뭉개도 **전건 green**이었다. 라이브 형태로
  실재하는 공백이다(observability ns 하나에 CronJob 3개 공존 → ns 단위 억제면 정상 CronJob의 성공이
  고장 난 형제의 실패를 삼킨다 = 이 픽스가 막으려던 것의 정반대 fail-open).
  → 같은 ns에 해소/미해소 Job을 하나씩 두는 L5a/L5b 레그 신설.
- S-3 accept — §3b preflight가 R-2류를 **원리적으로** 못 막는다. 네 불변식이 전부 `FOR_S`에서 파생된
  셸 스칼라 비교(사실상 `FOR_S > eval` 한 문장)이고 `gen()`이 써 내는 JSONL을 한 번도 읽지 않는다.
  R-2의 몸통은 생성기 안에 있었다. 실측: last-success를 `to+3600` 상수로 되돌려도 침묵 + 전건 green.
  → 생성된 JSONL을 실제로 스캔해 **타임스탬프 값 ≤ 그 샘플의 시각**을 강제하는
    `assert_no_future_timestamps`를 추가(run_scenario마다 호출). 산술 블록은 역할을 축소해 명시.
- S-9 accept — `LAG_CEILING`이 unset/빈 값이면 `[ 1800 -lt "" ]`가 종료코드 2를 내는데 `if` 조건부는
  errexit 면제라 **조건이 거짓으로 읽혀 floor가 3주기로 남고**, 테스트는 조용히 형제와 동치가 된다.
  → 기준량 자기검사(`[ "${LAG_CEILING:-0}" -ge 21600 ]`) + "천장이 실제로 채택된 항목 ≥ 1" 단언 추가.
- S-8 accept — `scheduled()`가 큰따옴표 cron만 파싱해 작은따옴표/plain scalar 워크플로를 **조용히
  건너뛴다**. 그러면 새 워크플로가 watched·scheduled 양쪽에서 동시에 사라져 집합 대조가 초록이고,
  고정 바닥값 `-ge 5`도 기존 8건이 세어져 못 잡는다.
  → 바닥값을 상수에서 **레포 실측 대조**로 교체(`.github/workflows/*.yaml`의 cron 보유 파일 수와 일치 강제).
- S-10 accept — 제품 파일 안 두 번째 예산 파생 주석이 반증된 전제("maxage >= 3주기")를 그대로 선언하고
  있었고, 하필 값을 실제로 **쓰는** 코드에 더 가까웠다. → 새 모델로 갱신 + SSOT 위치 명시.
- S-4/S-7/S-12 accept — core.yaml의 회귀 게이트 레그 지도가 R-2 재설계 이후 stale(번호가 한 칸씩 밀리고
  전이 레그 누락). → 새 레그 구성으로 갱신.
- S-6 **defer(별도 후속)** — 억제가 실패 **빈도**에 무조건적이라, 주기 P < `for:15m`인 CronJob의 만성
  flapping(실패↔성공 교대)이 영구 무성이 된다. 대상: `adguard-rewrite-reconciler`(*/10, P=600),
  `digest-exporter`(*/10). 개별 실패 관점에서는 "그 뒤 성공했다"가 참이므로 억제가 논리적으로 옳고,
  이를 닫으려면 **실패율이라는 다른 축의 알림**이 필요하다(현재 레포에 부재) — 이번 버그픽스의 범위
  밖이다. 룰 주석에 한계를 명시하고 후속으로 넘긴다. ⚠️ 수정 전에는 (문구는 틀렸어도) 이 상태가
  발화했으므로 **탐지 능력이 좁아진 것은 사실**이다. 연속 2회 이상 실패는 여전히 발화한다.

반증된 6건은 기록만 남긴다(전제는 참이나 결함으로 성립하지 않음): KSM ownerless 센티널 값 차이,
`concurrencyPolicy: Allow`에서의 의미론, 하한 합성이 `max`가 아니라 가산이어야 한다는 주장,
형제 테스트 포섭, 감지 지연 6h vs 6.5h, 모드 B의 by-list ⊋ on-list 불변식.

## release r1

- R-1 accept — Open question: two independent behavior flips lack the required approval
  (분리 릴리스가 아니라 권고의 두 번째 갈래로 해소: 위 「범위 승인」 절과 `diagnosis.md`의 범위 판정
  섹션에 명시적 승인을 기록. 사용자는 (b) 분리 진행을 이미 반려했다.)
- R-2 accept — The recovery regression test injects a future success outside its replay window
  (지적이 정확했다: `SPAN_S=3×for=2700s`인데 `RESOLVE_LAG_S=3600`이라 주장된 성공이 replay 종료보다
  900s 뒤였고, 그 값을 모든 샘플에 실어 첫 평가부터 억제가 걸렸다 → 전이를 한 번도 실행하지 않는
  vacuous green. 수정: L1을 라이브 모양(창 이전 실패 + 계속 성공하는 CronJob)으로 재설계하고,
  창 **안에서** 발화→복구→해소를 겪는 전이 레그 L2a/L2b를 신설. 창 밖 타임스탬프·관측 불가 구간은
  §3b preflight가 전제 붕괴로 끊는다. 이빨 실측: 억제 절 제거 시 L1·L2b가 red, 나머지는 green.)

## release r2

`verdict: approve` · findings 0 · `ok: true` · plan/HEAD 드리프트 없음.
R-1(범위 승인 기록)·R-2(전이 회귀 테스트) 재검증 통과, 수정이 새로 들여온 critical/high 없음.
게이트 통과 조건 충족 — 웨이버 없이 approve로 닫힌다.
