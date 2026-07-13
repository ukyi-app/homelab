#!/usr/bin/env bats
# R6 ImageDigestDrift 소생: digest-exporter가 (a) private GHCR 자격으로 inspect하고, (b) recording-rule
# join이 양변 라벨(app,digest) 정렬돼 오발화하지 않으며, (c) egress가 격리되고, (d) APPS가 apps/와 parity.
# (@test 이름 영어, 중간 단언 run+[ ] — bash 3.2 함정)
setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  D="$ROOT/platform/victoria-stack/prod/digest-exporter.yaml"
  # 지연 예산의 상수·파생·부등식 SSOT(발화 e2e·skopeo 스모크와 **같은 코드**를 쓴다 — 리터럴 복제 금지).
  # shellcheck source=lib/digest-exporter-budget.sh
  . "$ROOT/tests/gates/lib/digest-exporter-budget.sh"
}

# 예산 파생은 fail-closed다 — 빈 값/비수치면 즉시 RED. `deb_load || { …; false; }`로 받는 이유:
# ⚠️ `set -e`는 **&&/|| 리스트의 마지막이 아닌** 명령의 실패를 무시한다(docs/traps-detail.md
#    「bats bash 3.2 중간 [[ ]] 침묵 통과」). 예전 코드의 `[ -n "$ST" ] && [ -n "$CT" ]`가 바로 그 함정이었다:
#    파생이 비면 그 줄이 **조용히 통과**하고 BUDGET이 70으로 계산돼 부등식(< 180)이 참이 되어, 타임아웃을
#    하나도 강제하지 못한 채 게이트가 green이 됐다(= 이 테스트가 막겠다던 fail-open 그 자체).
#    → 중간 단언은 반드시 **단순 명령 + `|| { …; false; }`** 형태로만 쓴다.
load_budget() {
  deb_load "$D" || {
    echo "digest-exporter 예산 파생 실패(fail-closed) — 위 stderr 참조."
    echo "→ 매니페스트의 run.sh 타임아웃 기본값 / activeDeadlineSeconds / APPS env / cron 형식 중 하나가 바뀌었다."
    echo "→ 빈 값을 그대로 산술에 넣으면 부등식이 참이 되어 상한을 하나도 강제하지 못한 채 통과한다."
    false
  }
}

@test "digest-exporter authenticates to private GHCR via ghcr-read authfile" {
  grep -q -- '--authfile /auth/config.json' "$D"          # skopeo가 자격 사용
  grep -q 'secretName: ghcr-read' "$D"                    # observability ns dockerconfigjson 마운트
  # SealedSecret 소스 존재(owner seal 산출) + kustomization 배선
  [ -f "$ROOT/platform/victoria-stack/prod/ghcr-read.sealed.yaml" ]
  grep -q 'ghcr-read.sealed.yaml' "$ROOT/platform/victoria-stack/prod/kustomization.yaml"
}

@test "digest-exporter pod is egress-isolated (label + default-deny + ghcr/vmsingle allow)" {
  N="$ROOT/platform/victoria-stack/prod/networkpolicy.yaml"
  grep -q 'app.kubernetes.io/name: digest-exporter' "$D"   # netpol 셀렉터용 pod 라벨
  grep -q 'digest-exporter-default-deny-egress' "$N"
  grep -q 'digest-exporter-allow-egress' "$N"
}

@test "drift recording-rule aligns both join sides on (app,digest) and rolls up the push metric" {
  R="$ROOT/platform/victoria-stack/prod/rules/r6-ci-staleness.yaml"
  # ⚠️ $R은 ConfigMap이다 — 룰 YAML은 .data["r6.yaml"]에 **문자열로** 박혀 있다(.spec.groups 아님 → 빈 결과).
  # 단언은 record expr **하나만** 겨냥한다(주석·타 룰이 단언을 만족시키는 오염 차단).
  EXPR="$(yq '.data["r6.yaml"]' "$R" | yq '.groups[].rules[] | select(.record == "app:image_digest_drift") | .expr')"
  [ -n "$EXPR" ]                                                          # 추출 실패 = 즉시 FAIL(빈 문자열 false-green 차단)
  grep -qE 'max by \(app, digest\) \(' <<<"$EXPR"                         # 좌변 digest 라벨 보존(조인 양변 정렬)
  grep -qE 'last_over_time\(ghcr_latest_digest\[[0-9]+m\]\)' <<<"$EXPR"   # push(10m) 메트릭에 rollup 착용 — 없으면 5m 룩백에 구멍→영구 무발화
  # ── 우변의 **추출 소스** = `image_spec`(파드가 선언한 핀) ─────────────────────────────────────────
  # 왜 계약인가: `image_id`는 **containerd의 저장 아티팩트**다. buildx attestation이 비결정적이라 소스 무변경
  # 재빌드에도 태그의 OCI **인덱스** digest가 새로 생기지만 arm64 자식은 바이트 동일 → containerd는 콘텐츠를
  # 재사용하고 `image_id`로 **구 인덱스 digest**를 계속 보고한다. 좌변(GHCR 인덱스 digest)과 **영구 불일치 =
  # 영구 오탐**(라이브 page: 신 98db4e11 / 구 54211c26, 공통 arm64 자식 d68dbeb6 → 콘텐츠 동일). 비교는 반드시
  # 파드가 **쓰기로 선언한 핀**(`image_spec`, 좌변과 같은 정체성 공간)과 해야 한다. (발화 게이트 L9)
  grep -q '"digest", "$1", "image_spec"' <<<"$EXPR"                       # digest 추출 소스 = 선언된 핀
  grep -q '"app", "$1", "image_spec"' <<<"$EXPR"                          # app 추출 소스도 같은 라벨(정체성 일관)
  # 회귀 금지: 추출 소스가 `image_id`로 되돌아가면 L9 오탐이 부활한다. (맨 `! grep` 중간 부정은 bats false-green
  # 함정 → run + status.)
  run grep -qE '"(app|digest)", "\$1", "image_id"' <<<"$EXPR"
  [ "$status" -ne 0 ]
  # 파손식(좌변이 digest 라벨을 떨궈 조인 키 소실) 회귀 금지. 부정 패턴은 ghcr_latest_digest **주변으로 좁힌다** —
  # 넓게 쓰면 우변 존재 가드의 정당한 `max by (app) (label_replace(kube_pod_container_info…))`까지 잡아
  # 올바른 픽스를 RED로 만든다. 맨 `! grep` 중간 부정은 bats false-green 함정 → run + status.
  run grep -qE 'max by \(app\) \([^)]*ghcr_latest_digest' <<<"$EXPR"
  [ "$status" -ne 0 ]
  run grep -q 'image=~' "$R"; [ "$status" -ne 0 ]                         # bare-ID 라벨 selector 회귀 금지
}

@test "drift rule's twin pod selectors stay byte-identical (unless RHS vs. existence guard)" {
  R="$ROOT/platform/victoria-stack/prod/rules/r6-ci-staleness.yaml"
  EXPR="$(yq '.data["r6.yaml"]' "$R" | yq '.groups[].rules[] | select(.record == "app:image_digest_drift") | .expr')"
  [ -n "$EXPR" ]
  # `unless` 우변과 말미 존재 가드는 같은 파드 셀렉터의 **바이트 쌍둥이**다(중복 수용: 새 recording rule은
  # eval 순서 의존, 우변 rollup은 fail-open 거울상 → 둘 다 더 나쁘다). 문제는 그 쌍둥이 계약을 지키는 가드가
  # 없다는 것 — 누가 ns/owner/app-추출 정규식을 **한쪽만** 고치면 가드의 app 집합이 조용히 좁아져 진짜
  # 드리프트를 억제한다(= 우리가 고친 fail-open의 재발 경로). 여기서 못박는다.
  sel="$(grep -oE 'kube_pod_container_info\{[^}]*\}' <<<"$EXPR")"
  [ "$(printf '%s\n' "$sel" | wc -l | tr -d ' ')" -eq 2 ]           # 파드 셀렉터는 정확히 2회(unless 우변 + 존재 가드)
  [ "$(printf '%s\n' "$sel" | sort -u | wc -l | tr -d ' ')" -eq 1 ] # …그리고 둘이 동일(namespace + image_id 정규식)
  # ── 셀렉터는 **여전히 `image_id`** 여야 한다 = materialization 가드(B-1에서 추출 소스만 image_spec으로 옮겼다) ──
  # 왜 계약인가: 셀렉터를 `image_spec`으로 바꾸면 **fail-open**이다. ImagePullBackOff 파드는 KSM이
  # `image_spec=<최신 digest>` + **`image_id=""`** 로 내보내는데, 그 **실행조차 못 한** 파드가 우변에 들어와
  # 최신 digest와 매치되면 `unless`가 좌변을 지워 **진짜 드리프트를 억제한다**(구 파드가 여전히 구 이미지를
  # 서빙 중인데 침묵) — 발화 게이트 **L10**(롤아웃 교착)이 실측으로 락하는 회귀다. 빈 `image_id`는 아래
  # 정규식에 걸리지 않으므로, 이 필터가 곧 "이미지를 **실제로 실현한** 파드만" 이라는 존재 판정이다.
  sel_want='image_id=~"ghcr[.]io/ukyi-app/.*"'
  [ "$(printf '%s\n' "$sel" | grep -cF "$sel_want" | tr -d ' ')" -eq 2 ] || {
    echo "우변 파드 셀렉터가 materialization 가드('$sel_want')를 잃었다 — image_spec 셀렉터는 pull 실패 파드가"
    echo "진짜 드리프트를 억제하는 fail-open이다(L10). 셀렉터는 image_id, 추출 소스만 image_spec이다."
    echo "실제 셀렉터: $sel"
    false
  }
  # app-추출 label_replace도 쌍둥이 — 치환 정규식까지 포함해 동일해야 가드의 app 집합이 우변과 일치한다.
  # (소스 라벨은 image_spec — 위 join-alignment 테스트가 그 계약을 소유한다.)
  lr="$(grep -oE '"app", "\$1", "image_spec", "[^"]*"' <<<"$EXPR")"
  [ "$(printf '%s\n' "$lr" | wc -l | tr -d ' ')" -eq 2 ]
  [ "$(printf '%s\n' "$lr" | sort -u | wc -l | tr -d ' ')" -eq 1 ]
}

@test "digest-exporter APPS tracks exactly the deployed apps/ set (variant-chain parity)" {
  val="$(yq 'select(.kind=="CronJob").spec.jobTemplate.spec.template.spec.containers[].env[] | select(.name=="APPS").value' "$D")"
  got="$(printf '%s' "$val" | tr ' ' '\n' | sed -n 's/=.*//p' | grep -v '^$' | sort | tr '\n' ' ')"
  want="$(ls -1 "$ROOT/apps" | grep -vx 'README.md' | sort | tr '\n' ' ')"
  [ "$got" = "$want" ] || { echo "APPS names='$got' != apps/='$want'"; false; }
}

@test "digest-exporter pushes via curl (wget is absent from the skopeo image)" {
  # ★ 플래그 **인접**이 아니라 **존재**를 본다 — 인접 grep은 매니페스트의 argv 순서를 테스트에 종속시킨다
  #   (실제로 그랬다: run.sh가 --max-time을 --data-binary 뒤로 밀어야 했다).
  # ⚠️ 주석 제거 후 단언한다 — run.sh 주석이 'curl … --data-binary'를 언급하므로 원문을 그대로 grep하면
  #   **주석이 단언을 만족시킨다**(fail-open). 단언은 실행 라인만 겨냥한다.
  RUN="$(yq 'select(.kind=="ConfigMap").data["run.sh"]' "$D")"
  [ -n "$RUN" ] || { echo "run.sh 추출 실패 — ConfigMap 경로가 바뀌었다"; false; }
  CODE="$(grep -v '^[[:space:]]*#' <<<"$RUN")"
  run grep -qE 'curl[^|]*--data-binary' <<<"$CODE"; [ "$status" -eq 0 ]
  # 주석의 'wget' 언급은 허용 — 파이프 호출(| wget)만 금지(회귀 표적을 정확히 겨냥)
  run grep -qE '\|\s*wget' <<<"$CODE"; [ "$status" -ne 0 ]
}

# ── 지연 상한 강제(부트스트랩 안전성 계약) ──────────────────────────────────────────────────────────
# DigestExporterStale의 `for: 15m`은 "첫 하트비트가 반드시 840s 안에 온다"는 **강제된 상한** 위에 서 있다.
# 그 상한을 만드는 4개 계약(Replace · activeDeadlineSeconds · skopeo/curl 타임아웃 · APPS 카디널리티)을
# 여기서 정적으로 못박는다. 하나라도 되돌리면 최초 배포 거짓 페이지 또는 원인 오귀속이 되살아난다.
# (같은 부등식을 tests/gates/vmalert-digest-stale-firing-e2e.sh의 preflight ①④가 독립 파생해 강제한다.)

@test "digest-exporter CronJob caps hung Jobs (concurrencyPolicy Replace + activeDeadlineSeconds)" {
  load_budget   # activeDeadlineSeconds 부재/비정수 = fail-closed RED(lib이 강제)
  # ⚠️ Forbid이면 안 된다: activeDeadlineSeconds는 jobTemplate에만 붙고 k8s는 **이미 실행 중인 Job에
  #    소급 적용하지 않는다** → 랜딩 순간 살아 있던 무제한 레거시 Job이 Forbid 슬롯을 계속 점유하면
  #    상한이 통째로 무너진다. Replace는 구 Job을 죽이고 새(제한된) Job을 반드시 띄운다(잡은 멱등).
  [ "$DEB_CONCURRENCY_POLICY" = "Replace" ] || { echo "concurrencyPolicy='$DEB_CONCURRENCY_POLICY' (기대: Replace — 레거시 무제한 Job이 상한을 빠져나간다)"; false; }
  [ "$DEB_ACTIVE_DEADLINE_S" -gt 0 ] || { echo "activeDeadlineSeconds='$DEB_ACTIVE_DEADLINE_S' — 양의 정수여야 한다(부재 = 상한 없음)"; false; }
}

@test "digest-exporter run.sh puts skopeo --command-timeout BEFORE inspect and bounds the curl push" {
  RUN="$(yq 'select(.kind=="ConfigMap").data["run.sh"]' "$D")"
  [ -n "$RUN" ] || { echo "run.sh 추출 실패 — ConfigMap 경로가 바뀌었다"; false; }

  # ── skopeo: 존재가 아니라 **순서**를 단언한다(의도된 계약) ──
  #   run.sh는 tests/gates/skopeo-timeout-smoke.sh가 핀된 실물 이미지에서 **실제로 증명한** 배치
  #   (글로벌 옵션이 서브커맨드 앞)에서 벗어나면 안 된다.
  #   (실측: 그 skopeo 빌드는 cobra persistent flag 상속으로 `inspect` 뒤 배치도 상한을 강제한다 —
  #    계획이 가정한 "뒤=무효"는 사실이 아니었다. 그래도 증명된 배치를 계약으로 고정한다: 뒤 배치의
  #    수용은 구현 세부이고, 그것이 조용히 사라지면 상한이 무강제가 된다. 스모크의 S3가 그 회귀를 감시한다.)
  run grep -qE 'skopeo --command-timeout="\$SKOPEO_TIMEOUT" inspect ' <<<"$RUN"
  [ "$status" -eq 0 ]
  # inspect 뒤에 --command-timeout이 오는 형태(증명되지 않은 배치) 회귀 금지
  run grep -qE 'skopeo +inspect[^|]*--command-timeout' <<<"$RUN"
  [ "$status" -ne 0 ]

  # ── curl: **순서가 아니라 존재**를 단언한다(플래그 순서는 계약이 아니다) ──
  #   ★ 예전 게이트는 `curl -fsS --data-binary` **인접**을 grep해서, 매니페스트가 --max-time을
  #     --data-binary 뒤로 밀도록 강요했다(테스트가 프로덕션 argv를 구속 = test-induced coupling).
  #     이제 curl 호출 하나를 잘라내(파이프 앞까지) 그 안에 필요한 플래그가 **있는지**만 각각 본다.
  #   ⚠️ 주석 줄 먼저 제거 — run.sh 주석에 "push는 curl …"이 있어 그냥 grep하면 **주석이 먼저 잡힌다**
  #     (실측: 단언이 주석을 검사하게 되어 오탐). 단언은 실행 라인만 겨냥한다.
  CURL_CALL="$(grep -v '^[[:space:]]*#' <<<"$RUN" | grep -oE 'curl [^|]*' | head -1)"
  [ -n "$CURL_CALL" ] || { echo "run.sh에서 curl 호출을 찾지 못했다 — push 경로가 사라졌다"; false; }
  run grep -q -- '-fsS' <<<"$CURL_CALL"; [ "$status" -eq 0 ]                        # 조용히 실패하지 않는다
  run grep -q -- '--data-binary @-' <<<"$CURL_CALL"; [ "$status" -eq 0 ]            # stdin 페이로드
  run grep -qE -- '--max-time "\$CURL_MAX_TIME"' <<<"$CURL_CALL"; [ "$status" -eq 0 ] # push 상한

  # env 기본값(오버라이드 가능해야 테스트가 빠른 값으로 돈다 — lib의 파생 대상이기도 하다)
  run grep -qE 'SKOPEO_TIMEOUT="\$\{SKOPEO_TIMEOUT:-[0-9]+s\}"' <<<"$RUN"
  [ "$status" -eq 0 ]
  run grep -qE 'CURL_MAX_TIME="\$\{CURL_MAX_TIME:-[0-9]+\}"' <<<"$RUN"
  [ "$status" -eq 0 ]
}

@test "digest-exporter APPS cardinality satisfies the strict in-deadline budget (8th app must go red)" {
  # 상수(POD_START·EXEC_SLACK)·파생(타임아웃·ADS·N)·부등식은 전부 lib이 소유한다 — 발화 e2e preflight ④와
  # **같은 코드**로 판정하므로 두 게이트가 갈릴 수 없다. 파생 실패는 여기서 fail-closed RED가 된다.
  load_budget
  # ★ 순차 스크레이프 예산 — **엄격 부등식**이다(등호 금지):
  #   activeDeadlineSeconds는 **파드 생성부터** 재고(startup이 그 안에 포함된다) 컨트롤러는 duration ≥ ADS에서
  #   만료시키므로, 등호를 허용하면 CI가 "push 전에 죽는 Job"을 승인하게 된다 → GHCR 장애가 아니라
  #   DigestExporterStale/KubeJobFailed로 **오귀속**된다.
  BUDGET="$(deb_in_deadline_budget)"
  N_MAX="$(deb_n_max)"
  [ "$BUDGET" -lt "$DEB_ACTIVE_DEADLINE_S" ] || {
    echo "in-deadline 예산 초과: POD_START($DEB_POD_START_BUDGET_S) + N($DEB_APPS_N)×SKOPEO_TIMEOUT($DEB_SKOPEO_TIMEOUT_S) + CURL_MAX_TIME($DEB_CURL_MAX_TIME_S) + EXEC_SLACK($DEB_EXEC_SLACK_S) = $BUDGET ≥ activeDeadlineSeconds($DEB_ACTIVE_DEADLINE_S)."
    echo "→ Job이 push 전에 죽어 하트비트가 미발행되고 GHCR 장애가 'push 사망'으로 오귀속된다."
    echo "→ activeDeadlineSeconds를 올리되(그러면 부트스트랩 부등식 for > cron+ADS+파드예산 을 함께 재확인),"
    echo "   또는 SKOPEO_TIMEOUT을 낮춰라. 두 부등식을 **동시에** 만족해야 한다."
    false
  }
  # 현 계약의 상한을 명시적으로 기록(문서 아닌 실행 가능한 형태) — N_MAX = 7
  echo "# APPS N=$DEB_APPS_N / N_MAX=$N_MAX (ADS=$DEB_ACTIVE_DEADLINE_S skopeo=${DEB_SKOPEO_TIMEOUT_S}s curl=${DEB_CURL_MAX_TIME_S}s)" >&3
  [ "$DEB_APPS_N" -le "$N_MAX" ] || { echo "APPS N=$DEB_APPS_N > N_MAX=$N_MAX — 앱을 더 붙이려면 예산을 재설계하라"; false; }
}
