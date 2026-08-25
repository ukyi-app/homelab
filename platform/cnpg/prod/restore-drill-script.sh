#!/usr/bin/env bash
# 복원 drill (R1): R2 백업이 실제로 복구 가능함을 증명한다.
# 0) **apply 이전에** 이전 실행의 잔여물(Cluster + PVC)을 전량 제거하고 0을 확인한다.
#    생존자가 있으면 apply가 no-op이 되어 R2를 만지지 않은 채 PASS가 난다(아래 pre-flight 주석).
#    정리에 성공하면 이번 회차는 **계속 진행한다** — 청소된 상태에서 진짜 복구가 돌기 때문이다.
# 1) 라이브 클러스터에서 안정적인 row count를 읽는다
# 2) R2에서 복구한 일회용 클러스터를 띄운다
# 3) Ready가 될 때까지 기다린 뒤 같은 row count를 읽는다
# 4) 비교; PASS/FAIL을 Telegram으로 보고; PASS 시 healthchecks를 ping하고
#    restore_drill_last_success_timestamp 메트릭을 push (M5의 CNPGRestoreDrillStale이 읽음)
# 5) 일회용 클러스터는 항상 삭제한다
set -euo pipefail

NS="database"
LIVE_CLUSTER="pg"
DRILL_CLUSTER="pg-restore-drill"
DB="app"
TABLE="${DRILL_TABLE:-restore_canary}" # 라이브 앱/시드가 유지하는 canary 테이블
TG="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
# vmsingle의 Prometheus import 엔드포인트 (M5). 클러스터 내 service를 기본값으로 해 메트릭이
# 항상 전달되게 한다 — M5의 CNPGRestoreDrillStale은 absent()를 쓰므로 시계열이 없으면 영원히 페이징된다.
PUSHGW="${METRICS_PUSH_URL:-http://vmsingle.observability.svc:8428}"

# ─── 폴링 노브 ─────────────────────────────────────────────────────────────────────
# 기본값은 현행 동작과 동일하다(phase 15s×60 = 15분). 스텁 단위테스트가 fake-clock으로 돌리기
# 위한 주입점이다 — 선례: ensure-role-password.sh:30-33(ERP_POLL_INTERVAL_SECONDS/ERP_MAX_POLLS).
POLL_INTERVAL="${DRILL_POLL_INTERVAL_SECONDS:-15}"
MAX_POLLS="${DRILL_MAX_POLLS:-60}"
PURGE_POLL_INTERVAL="${DRILL_PURGE_POLL_SECONDS:-5}"
# 5s × 120 = 10분. CNPG finalizer + 인스턴스 파드 graceful shutdown + PV 회수 여유.
# ⚠️ 예전 `delete --wait=true`의 실질 상한은 activeDeadlineSeconds 3600이었고 그 초과는
#    SIGKILL → EXIT trap 미실행 → 고아, 즉 M17이 지목한 생성 경로 자체다. 유계화는 개선이다.
#    실제 소요는 `purge attempt N: 잔여 M건` 로그로 첫 몇 주 확인하고 필요하면 CronJob env로 올린다.
PURGE_MAX_POLLS="${DRILL_PURGE_MAX_POLLS:-120}"
ORPHAN_NOTE="" # pre-flight가 고아를 치웠으면 PASS 보고 본문에 실린다(ORPHAN-FOUND 토큰)

# >>> notify-block (test-extracted)
# HTML-escape: parse_mode=HTML에서 동적 값의 & < > 를 엔티티로. & 를 먼저 치환한다.
# ⚠️ bash 파라미터 확장(${s//</&lt;})은 bash 5.2+에서 replacement의 &를 "매치 텍스트 참조"로
#    해석해 <lt; 처럼 깨진다(bash 3.2에선 literal이라 통과 — 라이브/CI는 bash 5.x). sed로 escape한다.
hx() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

# 공유 메시지 계약(parse_mode=HTML, 고정 필드 순서):
#   {glyph} <b>{제목}</b> — {상태}
#   복원드릴 · {핵심 식별자}
#   {key}: {value}
#   → {링크}            (URL이 있을 때만)
# $1=PASS|FAIL  $2=상태 상세 텍스트(동적, 이스케이프 대상)
notify() {
  local outcome=$1 detail=$2 glyph word
  case "$outcome" in
    PASS) glyph='✅'; word='성공' ;;
    *)    glyph='🔴'; word='실패' ;;   # FAIL 및 기타 → 실패 (fail-closed)
  esac
  local stamp; stamp="$(TZ=Asia/Seoul date '+%m/%d %H:%M' 2>/dev/null || true)"
  # 동적 값은 전부 이스케이프. 정적 한국어 라벨/태그는 그대로(계약 구조).
  local text
  text="${glyph} <b>복원 드릴</b> — ${word}
복원드릴 · pg-restore-drill
결과: $(hx "$detail")"
  [ -n "$stamp" ] && text="${text}
시각: ${stamp} KST"

  if [ "${DRY_RUN:-0}" = "1" ]; then
    printf '%s\n' "$text"
    return 0
  fi
  curl -fsS -X POST "$TG" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${text}" \
    --data-urlencode "parse_mode=HTML" >/dev/null || true
}
# <<< notify-block (test-extracted)

fail() {
  notify FAIL "$1"
  exit 1
}

# ⚠️ k8s Cluster 이름(`LIVE_CLUSTER`)과 **아카이브 serverName**은 다른 것이다. NUC 이전에서 갈렸다:
#    k8s Cluster는 `pg`인데 아카이브는 `pg-nuc`다. 여기서 겸직하면 이 드릴이 **라이브 Mac의 아카이브**를
#    복구해 NUC의 row와 비교한다 → Mac이 살아 있는 동안 **초록**이 뜨고, 계획서 G7("NUC 자체 백업
#    체인이 독립적으로 살아있음")이 거짓 통과한다. PONR 1로 `pg/`를 purge한 뒤에야 무너진다.
#    → 라이브 Cluster에서 파생한다. 파생 실패는 fail-closed(무엇을 복구할지 모른 채 증명할 수 없다).
# ⚠️ 이 블록을 **notify()/fail() 정의 뒤로 옮겼다.** 예전엔 스크립트 최상단이라 파생 실패가
#    `echo … >&2; exit 1`로 끝났다 — 이 CronJob은 in-band 무음이므로(KubeJobFailed가
#    `pg-restore-drill.*` 제외 + backoffLimit 0) Telegram도 알림도 없이 사라졌다. 이제 FAIL이 나간다.
ARCHIVE_SERVER="$(kubectl -n "$NS" get cluster "$LIVE_CLUSTER" \
  -o jsonpath='{.spec.plugins[?(@.name=="barman-cloud.cloudnative-pg.io")].parameters.serverName}' 2>/dev/null || true)"
[ -n "$ARCHIVE_SERVER" ] || fail "Cluster ${LIVE_CLUSTER}에서 아카이브 serverName을 파생하지 못했다 — 어느 아카이브를 복구할지 알 수 없다"

push_success_metric() { # M5의 CNPGRestoreDrillStale이 읽는 정식 시계열 (vmsingle import API)
  printf 'restore_drill_last_success_timestamp %s\n' "$(date -u +%s)" \
    | curl -fsS --data-binary @- "${PUSHGW}/api/v1/import/prometheus" \
    || fail "could not push restore_drill_last_success_timestamp to ${PUSHGW} (M5 would page on the absent series)"
}

# ─── drill 잔여물 회계 ────────────────────────────────────────────────────────────
# drill은 `drill-ssd` StorageClass(reclaimPolicy=Delete)를 쓰므로 PVC 삭제 시 PV가 자동 삭제된다 —
# 클러스터 전역 PV 권한도, 실행당 ~50 GiB 누수도 없다. (CNPG는 Cluster 삭제 시 PVC를 지우지 않는다.)
# ⚠️ 열거를 **라벨이 아니라 이름 접두**로 한다. 예전 셀렉터 `cnpg.io/cluster=pg-restore-drill`은
#    이 레포 어디에서도 양성 관측된 적이 없다 — 세 소비처(이 파일의 구 cleanup/구 RESID,
#    scripts/dr-drill.sh:103)가 전부 '0건=정상' 구조라 셀렉터가 빗나가도 rc 0 + 0줄이라
#    '잔여 없음'과 구별되지 않는다. 그러면 PGDATA가 살아남아 새 Cluster가 재사용하고 거짓 PASS가
#    다른 문으로 재현된다. (라이브 확인된 CNPG 자동 라벨은 networkpolicies.yaml:59의 **Pod** 라벨뿐이다.)
# ⚠️ 컬렉션 list를 쓴다 — `get <name>`은 부재 시 rc 1이지만 컬렉션은 항상 rc 0이라 "없다"와
#    "못 읽었다"가 rc로 갈린다(실측 2026-08-17 라이브: `get cluster -o name` → `cluster.postgresql.cnpg.io/pg`).
#    Role은 clusters/pvc 둘 다 `list`를 이미 갖고 있다(restore-drill-rbac.yaml:11,18).
# ⚠️ kubectl 실패를 빈 출력으로 **위장하지 않는다** — rc 2로 전파한다. 예전 잔여 검사
#    (`RESID=$(kubectl … 2>/dev/null | wc -l)`)는 API 접근이 죽어도 0을 내어 '잔여 없음'으로 읽혔다.
#    "열거할 수 없다"와 "잔여가 없다"는 다른 사실이다(같은 클래스를 scripts/audit-orphan-pv.sh:34-39가
#    '열거 바닥값'으로 막는다). 그 아이디어의 양성 대조판이 아래 verify_enumeration_positive다.
list_clusters() {
  local out
  out="$(kubectl -n "$NS" get cluster -o name)" || return 2
  printf '%s\n' "$out" | grep -x -E "cluster[^/]*/${DRILL_CLUSTER}" || true
}

list_pvcs() {
  local out
  out="$(kubectl -n "$NS" get pvc -o name)" || return 2
  printf '%s\n' "$out" | grep -x -E "persistentvolumeclaim/${DRILL_CLUSTER}(-.*)?" || true
}

# 두 열거를 **각각** 실행한다 — 앞이 실패해도 뒤의 부분 결과를 반드시 낸다. FAIL 알림이
# best-effort Telegram 한 줄뿐인 잡이라, 무엇이 남았는지가 로그에서 사라지면 재구성이 불가능하다.
list_remnants() {
  local rc=0
  list_clusters || rc=2
  list_pvcs || rc=2
  return "$rc"
}

count_remnants() { # stdout=건수. 열거 실패는 rc 2로 전파된다(0건과 구별).
  local rem
  rem="$(list_remnants)" || return 2
  [ -n "$rem" ] || { printf '0\n'; return 0; }
  printf '%s\n' "$rem" | grep -c .
}

# Cluster CR + PVC를 지우고 **사라졌음을 확인**한다. rc 0=잔여 0, 1=수렴 실패, 2=열거 실패.
# ⚠️ delete는 best-effort(`|| true`)이고 **판정은 폴링이 한다.** 삭제 호출의 rc를 믿지 않는 이유:
#    (1) `--ignore-not-found`는 없는 것도 성공이라 rc만으로 "지웠다"를 증명하지 못하고,
#    (2) CNPG finalizer 때문에 delete 반환 시점에 오브젝트가 아직 살아 있을 수 있다.
# ⚠️ `--wait=true`를 쓰지 않는다. restore-drill Role의 clusters 절에는 `watch`가 **없고**
#    (restore-drill-rbac.yaml:9-11. PVC 절 :15-18에만 :17 주석과 함께 watch가 있다 — 라이브
#    `kubectl auth can-i watch clusters… --as=…:restore-drill` → **no**, 실측 2026-08-17),
#    kubectl의 `--wait`는 대상이 즉시 사라지지 않으면 watch로 소멸을 추적한다. 지금까지 이 경로가
#    터지지 않은 것은 CNPG Cluster CR에 finalizer가 없어 삭제가 즉시 끝났기 때문이고(라이브 실측),
#    즉 **잠재 결함**이다 — finalizer가 붙는 순간 인가 오류가 나고 구 cleanup의 `|| true`가 그것을
#    통째로 삼킨다. Role이 이미 가진 `get/list` 폴링이면 같은 사실을 인가 경계 안에서 확인할 수 있고,
#    PATH-stub 테스트로도 관측된다.
# ⚠️ delete를 **매 반복 재발사**한다. Cluster를 `--wait=false`로 지운 직후에 PVC를 지우면 operator가
#    아직 deletionTimestamp를 관측하기 전이라 PVC가 재생성될 수 있고, 1회 발사 + 세기만 하면
#    그 경로에서 원리적으로 수렴하지 못한다. `--ignore-not-found`라 재발사는 멱등이다.
purge_drill() {
  # 자기방어: 이 프리미티브는 database ns의 **모든** Cluster를 지울 수 있다
  # (restore-drill-rbac.yaml:9-11에 resourceNames 없음). 유일한 방어가 '값이 리터럴이라서'인
  # 상태를 코드에 고정한다 — 누가 DRILL_CLUSTER를 변수화하면 이 단언이 먼저 죽는다.
  [ -n "$DRILL_CLUSTER" ] && [ "$DRILL_CLUSTER" != "$LIVE_CLUSTER" ] ||
    fail "purge 대상 이름이 비었거나 라이브 클러스터와 같다 — 중단"
  local i n p pvcs
  for i in $(seq 1 "$PURGE_MAX_POLLS"); do
    kubectl -n "$NS" delete cluster "$DRILL_CLUSTER" --ignore-not-found --wait=false || true
    kubectl -n "$NS" delete pvc -l "cnpg.io/cluster=${DRILL_CLUSTER}" --ignore-not-found --wait=false || true
    # 라벨이 빗나가도 지워지도록 이름으로도 지운다(라벨 삭제는 저비용 이중화로 남긴다).
    if pvcs="$(list_pvcs)"; then
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        kubectl -n "$NS" delete "$p" --ignore-not-found --wait=false || true
      done <<<"$pvcs"
    fi
    if ! n="$(count_remnants)"; then return 2; fi
    if [ "$n" = "0" ]; then return 0; fi
    echo "  purge attempt ${i}: 잔여 ${n}건" >&2
    sleep "$PURGE_POLL_INTERVAL"
  done
  return 1
}

# 열거자 양성 대조 — 이 실행이 **방금 만든** 오브젝트가 열거에 잡히는지 본다.
# 잡히지 않으면 스윕이 눈이 먼 것이고(셀렉터/접두 드리프트), 그 상태에서는 '잔여 0 확인'이
# 무측정 초록이다 — audit-orphan-pv.sh:34-39의 '열거 바닥값'과 같은 방어를 in-band로 세운다.
verify_enumeration_positive() {
  local c p
  c="$(list_clusters)" || fail "cleanup 양성 대조: Cluster를 열거하지 못했다(kubectl/API 실패)"
  p="$(list_pvcs)" || fail "cleanup 양성 대조: PVC를 열거하지 못했다(kubectl/API 실패)"
  [ -n "$c" ] || fail "열거자 실명 의심: 방금 만든 drill Cluster가 열거에 안 잡힌다 — 잔여물 스윕이 항상 0건을 내는 무측정 상태다"
  [ -n "$p" ] || fail "열거자 실명 의심: 방금 만든 drill PVC가 열거에 안 잡힌다 — PVC 스윕이 무측정이면 PGDATA가 살아남아 다음 회차가 그것을 재사용한다(거짓 PASS)"
}

# ─── pre-flight: 이전 실행의 잔여물을 지운 뒤에 진행한다 ────────────────────────────
# ⚠️ **이 드릴의 유일한 정리는 `trap cleanup EXIT`였다.** 비정상 종료(노드 재부팅·OOM·evict·
#    SIGKILL·activeDeadlineSeconds 3600 초과)에서는 EXIT trap이 돌지 않아 고아 Cluster가 남는다.
#    그 상태에서 다음 실행의 `kubectl apply`는 생존자에 대해 **no-op**이다: 힙독 텍스트가 매주
#    바이트 동일이라 3-way merge patch가 비고, 무엇보다 CNPG는 `bootstrap`을 **초기화 시점에만**
#    읽고 이후 무시한다(cluster.yaml의 bootstrap 주석에 적힌 라이브 CRD 실측 — 불변 CEL도 없다). 그러면 아래 phase
#    루프가 첫 시도에서 통과하고 canary 행 수는 지난 회차 값 그대로라 `>=` 비교도 통과해
#    → **R2를 한 번도 만지지 않은 drill이 '검증된 복원'을 보고한다.**
# ⚠️ Cluster CR만 지우는 것으론 부족하다. CNPG는 Cluster 삭제 시 PVC를 남기므로 `<cluster>-<serial>`
#    PGDATA가 살아 있으면 새 Cluster가 그것을 재사용해 bootstrap.recovery가 생략될 수 있다.
#    Cluster + PVC를 함께 지우고 0을 확인한다.
# ⚠️ **정리에 성공하면 이번 회차는 계속 진행한다.** 앞선 판은 여기서 fail-closed로 중단했는데,
#    그 근거("거짓 PASS가 staleness 타이머를 매주 리셋해 영구 초록")가 코드와 달랐다 — 구 말미의
#    성공 경로 `cleanup`이 **자기가 재사용한 고아를 지우므로** 성공 간격이 7일이 아니라 14일이 되고
#    CNPGRestoreDrillStale(8.1일)은 그 사이 ~5.9일간 이미 발화한다. 중단은 이미 울고 있는 알림에
#    정보를 더하지 않으면서 R2 복원 가능성 증명을 14일간 비운다 — 국면 A에서 순손실이다.
#    정리 후 계속하면 이 회차는 **청소된 상태에서 진짜 복구를 수행**해 그 알림을 정당하게 해소한다.
#    사건 기록은 PASS 본문의 `ORPHAN-FOUND` 토큰이 진다(검색 가능한 고정 문자열).
# ⚠️ 중단은 **purge 실패에만** 건다. 그때는 생존자 위의 apply가 실제로 no-op이 되므로 진행이 무의미하다.
#    그리고 purge가 성공했다는 착각(눈먼 열거)은 아래 phase 루프의 SAW_NONHEALTHY 증인이 잡는다.
preflight_purge() {
  local n rem rc=0
  if ! n="$(count_remnants)"; then
    fail "pre-flight: drill 잔여물을 열거하지 못했다(kubectl/API 실패) — 생존자 유무를 모르는 채 apply하면 no-op 거짓 PASS가 난다"
  fi
  if [ "$n" != "0" ]; then
    rem="$(list_remnants)" || rem="(부분 열거 — 일부 kubectl 실패)"
    echo "[drill] pre-flight: 이전 실행의 잔여물 ${n}건" >&2
    printf '%s\n' "$rem" >&2
    ORPHAN_NOTE=" · ORPHAN-FOUND: 이전 실행 잔여물 ${n}건을 정리하고 진행했다(직전 회차 비정상 종료)"
  fi
  # ⚠️ 잔여가 0이어도 **무조건** 지운다. 조건부로 지우면 "apply 직전 상태가 비어 있다"는 불변식이
  #    열거 결과에 의존하게 되고, 무엇보다 정상 경로에 delete가 사라져 그 순서 자체를 행위 테스트가
  #    물 수 없다. `--ignore-not-found`라 잔여 0에서는 무해한 no-op 호출이 전부다.
  purge_drill || rc=$?
  case "$rc" in
  0) : ;;
  2) fail "pre-flight: purge 중 drill 잔여물을 열거하지 못했다(kubectl/API 실패) — 지웠는지 확인할 수 없다" ;;
  *) fail "pre-flight: drill 잔여물이 수렴하지 않는다(finalizer 잔류/CNPG operator 의심) — 생존자 위의 apply는 no-op(=R2 미접촉 거짓 PASS)이 되므로 진행하지 않는다" ;;
  esac
  echo "[drill] pre-flight: 잔여물 0 확인"
}

preflight_purge

# EXIT trap 정리. 종료 중이므로 rc로 흐름을 바꾸지 않고 로그만 남긴다 — 실패한 정리의 **판정**은
# 성공 경로의 명시 호출(맨 아래)이 하고, 그것마저 못 돈 경우의 안전망은 **다음 실행의 pre-flight**다.
# ⚠️ trap을 pre-flight **뒤에** 무장한다. 그 이전에는 이 실행이 만든 것이 아무것도 없어 정리할
#    대상 자체가 없고, 앞에 걸면 pre-flight의 fail 경로에서 purge가 한 번 더 돌아 이미 내린 결정
#    뒤에 delete가 재발사되고 activeDeadlineSeconds 예산을 두 배로 태운다.
# ⚠️ 여기에 INT/TERM을 붙이지 않는다. terminationGracePeriodSeconds 기본 30초 안에 10분짜리 purge
#    폴링이 완주할 수 없어 반쪽 삭제만 남기고, SIGKILL 경로(deadline 초과·OOM·evict)는 애초에 trap이
#    못 돈다. 그 경로의 안전망은 trap이 아니라 pre-flight라는 것이 이 설계의 요지다.
cleanup() {
  purge_drill || echo "[drill] cleanup 미완: drill 잔여물이 남았다 — 다음 실행의 pre-flight가 잡는다" >&2
}
trap cleanup EXIT

# ─── RPO 증명: 지금 쓴 것이 아카이브에 실렸는가 ────────────────────────────────────
# ⚠️ **이것이 없으면 이 드릴은 "어떤 백업이 복구된다"까지만 증명한다.** 행 수 비교는 시드가
#    initdb 1회성이라(cluster.yaml의 postInitApplicationSQL) 라이브가 영구히 1행이었고,
#    `ACTUAL >= EXPECTED && > 0`은 6개월 전 base backup으로도 통과한다 — 즉 **아카이브 신선도를
#    원리적으로 검사하지 못했다**(실측 2026-08-17: EXPECTED_ROWS=1/ACTUAL_ROWS=1).
#    지금 쓴 행이 복구본에 나타나야만 "아카이브가 최신이다"가 증명된다.
# ⚠️ **이 잡이 프로덕션 DB에 쓰기를 시작한다**(owner 승인 2026-08-18). 범위는 최소다:
#    `restore_canary`는 이 용도로 존재하는 전용 테이블이고, initdb 시드도 같은 INSERT를 한다.
#    주 1행(연 52행). 스키마는 건드리지 않는다 — `id serial`을 그대로 마커로 쓴다.
#    RBAC 확대도 없다: 이미 `pods/exec`로 psql을 돌리고 있었다(restore-drill-rbac.yaml:12-14).
# ⚠️ 실패 방향이 안전하다 — 쓰지 못하거나 아카이브가 못 따라오면 **시끄럽게 FAIL**한다.
#    조용해지는 방향이 아니다.
# 폴링 예산. ⚠️ 회차마다 kubectl exec가 도는 비싼 폴링이라 간격을 넓게 잡는다 —
#    5s로 잡았더니 프로덕션 primary에 최대 120회 exec가 갔다(적대 검증 지적). 20×15s = 5분으로
#    같은 상한을 유지하면서 호출을 1/3로 줄인다. archive_timeout=300s(라이브 실측)와 같은 크기라
#    pg_switch_wal이 어떤 이유로 no-op이어도 강제 전환이 이 창 안에 들어온다.
RPO_MAX_POLLS="${DRILL_RPO_MAX_POLLS:-20}"
RPO_POLL_INTERVAL="${DRILL_RPO_POLL_SECONDS:-15}"
RPO_NOTE="" # 대기가 타임아웃했으면 최종 보고 본문에 실린다

# ⚠️ **타임아웃을 건다.** 이 헬퍼는 이제 프로덕션 primary에 **쓰기**도 한다 — 무타임아웃이면
#    테이블 락이나 반쯤 죽은 API에서 fail-closed가 아니라 **무한 대기**로 끝나고, 그건
#    activeDeadlineSeconds 초과 → SIGKILL → 고아라는 M17의 생성 경로 그 자체다(이 파일 상단 참조).
# ⚠️ **`kubectl --request-timeout`을 쓰면 안 된다** — kubectl v1.36.x가 그 플래그와 in-cluster REST
#    config 로딩을 상호작용시켜 **config를 통째로 버리고 localhost:8080으로 폴백**한다(2026-08-24 실측:
#    `--request-timeout=30s`·`=1m` 둘 다 재현, 플래그 없으면 정상). pg-tools 재빌드로 kubectl이
#    v1.36.3으로 올라가며 매 drill이 RPO 마커 단계에서 결정적으로 죽었다(8/22·8/25 재현). 값 무관이라
#    시간만 조정해선 못 고친다. ⇒ 타임아웃은 kubectl 플래그가 아니라 `timeout` 코어유틸로 exec 전체를
#    감싸 건다(무한 대기 방지 요구는 그대로 충족). psql 내부 statement/lock_timeout은 DB 레벨 보호로 유지.
_live_psql() {
  timeout 35 kubectl -n "$NS" exec "${LIVE_CLUSTER}-1" -c postgres -- \
    env PGOPTIONS='-c statement_timeout=15s -c lock_timeout=5s' psql -X -v ON_ERROR_STOP=1 -U postgres "$@"
}

echo "[drill] RPO 마커 기록 — 지금 쓴 행이 복구본에 나타나야 아카이브가 최신이다"
# 마커는 `id`와 `ts`를 **함께** 받는다. id 단독은 시퀀스가 되감기면(pg_dump 복원의 setval 등)
# 옛 행과 충돌해 거짓 PASS가 날 수 있고, ts가 있어야 **실제 RPO 수치**를 보고할 수 있다.
MARKER_ROW="$(_live_psql -d "$DB" -tAF'|' -c "INSERT INTO ${TABLE} DEFAULT VALUES RETURNING id, extract(epoch from ts)::bigint;")" \
  || fail "RPO 마커를 라이브에 쓰지 못했다 — 아카이브 신선도를 증명할 수 없다(테이블 부재/권한/DB 다운/락 확인)"
MARKER_ID="${MARKER_ROW%%|*}"
MARKER_TS="${MARKER_ROW##*|}"
case "$MARKER_ID" in '' | *[!0-9]*) fail "RPO 마커 INSERT가 숫자 id를 반환하지 않았다(${MARKER_ROW}) — ${TABLE} 스키마 변경 의심" ;; esac
case "$MARKER_TS" in '' | *[!0-9]*) fail "RPO 마커 INSERT가 숫자 ts를 반환하지 않았다(${MARKER_ROW}) — ${TABLE} 스키마 변경 의심" ;; esac
echo "[drill] MARKER_ID=${MARKER_ID} MARKER_TS=${MARKER_TS}"

# ⚠️ **전환과 이름 획득을 한 문장으로 묶는다.** 예전엔 `pg_walfile_name(pg_current_wal_lsn())`로
#    이름을 먼저 잡고 별도 커넥션에서 `pg_switch_wal()`을 불렀는데, 그 사이에 archive_timeout이나
#    다른 백엔드의 쓰기가 끼면 둘이 어긋난다. `pg_switch_wal()`은 방금 닫은 세그먼트의 end+1 LSN을
#    반환하고 `pg_walfile_name()`은 경계 LSN에서 **직전** 세그먼트를 내므로(XLByteToPrevSeg),
#    이 합성이 정확히 "방금 닫혔고 아카이브되어야 할 세그먼트"다. no-op이었어도 현재 세그먼트를 낸다.
MARKER_WAL="$(_live_psql -tAc "SELECT pg_walfile_name(pg_switch_wal());")" \
  || fail "WAL 세그먼트를 닫지 못했다 — 마커가 아카이브에 실릴 수 없다"
case "$MARKER_WAL" in [0-9A-F][0-9A-F]*) : ;; *) fail "WAL 세그먼트 이름이 예상 형식이 아니다(${MARKER_WAL})" ;; esac
echo "[drill] MARKER_WAL=${MARKER_WAL} — 아카이브 완료 대기"

# 아카이버가 그 세그먼트를 실을 때까지 폴링한다.
# ⚠️ `last_archived_wal`은 **세그먼트가 아닌 파일명**도 담는다(`<TLI>.history`·`.partial`·`.backup`).
#    특히 히스토리 파일은 큐를 앞질러 아카이브되므로, 형식 가드 없이 사전식 비교를 하면
#    `00000003.history` > `00000002…`가 되어 **마커가 안 실렸는데 통과**한다. 24자 hex만 비교에 넣는다.
# ⚠️ 타임라인이 드릴 중 바뀌면 그 자체가 사건이다 — 조용히 통과시키지 않고 끊는다.
# ⚠️ `failed_count` 증가로는 **끊지 않는다.** 그건 누적 카운터라 재시도로 결국 성공할 일시적
#    오류에도 오른다. 이 레포는 같은 사실에 이미 판별을 내려놨다 — r4의 WALArchiveStalled는
#    레벨(`last_failed_time > last_archived_time`) + `for: 15m`이다. 증분 1로 끊으면 R2 블립 한 번이
#    주간 드릴을 통째로 죽인다(backoffLimit 0 · 주 1회 · in-band 무음). 진단 문구로만 쓴다.
FAILED_BEFORE="$(_live_psql -tAc "SELECT failed_count FROM pg_stat_archiver;")" \
  || fail "pg_stat_archiver를 읽지 못했다 — 아카이브 진행을 판별할 수 없다"
RPO_OK=0
for i in $(seq 1 "$RPO_MAX_POLLS"); do
  last="$(_live_psql -tAc "SELECT coalesce(last_archived_wal,'') FROM pg_stat_archiver;" || true)"
  case "$last" in
  [0-9A-F][0-9A-F]*) [ "${#last}" = 24 ] || last="" ;; # .history/.partial/.backup 배제
  *) last="" ;;
  esac
  if [ -n "$last" ] && [ "${last%????????????????}" != "${MARKER_WAL%????????????????}" ]; then
    fail "라이브 타임라인이 드릴 중 바뀌었다(${MARKER_WAL} → ${last}) — 승격/복구가 일어났다는 뜻이고, 이 회차의 RPO 판정은 성립하지 않는다"
  fi
  # last >= MARKER_WAL 을 "NOT (last < MARKER_WAL)"로 쓴다(부정 한 번이 우선순위 함정을 피한다).
  if [ -n "$last" ] && ! [ "$last" \< "$MARKER_WAL" ]; then
    RPO_OK=1
    echo "[drill] 아카이브 확인: last_archived_wal=${last} >= ${MARKER_WAL} (${i}회차)"
    break
  fi
  echo "  rpo attempt ${i}: last_archived_wal=${last:-<none>}"
  sleep "$RPO_POLL_INTERVAL"
done
# ⚠️ 타임아웃이어도 **중단하지 않는다.** 복구본의 마커 판정이 이 대기보다 **엄격하게 강한**
#    단언이라(아카이브에 있어도 복구본에 없을 수 있다) 최종 판정을 잃지 않고, 여기서 죽으면
#    "R2 복구가 되는가"라는 **주 1회짜리 유일 신호**까지 함께 버린다. 반면 "아카이브 정체"는
#    WALArchiveStalled(critical, 15분)가 이미 상시 감시한다 — 중복 신호를 위해 유일 신호를 버리지 않는다.
if [ "$RPO_OK" != "1" ]; then
  now_failed="$(_live_psql -tAc "SELECT failed_count FROM pg_stat_archiver;" || echo "?")"
  RPO_NOTE=" · RPO-WAIT-TIMEOUT(${MARKER_WAL} 미아카이브, failed_count ${FAILED_BEFORE}→${now_failed})"
  echo "[drill] 경고: ${MARKER_WAL}이 대기 창 안에 아카이브되지 않았다 — 복구본 마커 판정으로 계속한다" >&2
fi

echo "[drill] expected row count from live cluster"
EXPECTED_ROWS="$(_live_psql -d "$DB" -tAc "SELECT count(*) FROM ${TABLE};")" \
  || fail "could not read live row count"
echo "[drill] EXPECTED_ROWS=${EXPECTED_ROWS}"

echo "[drill] applying throwaway recovery cluster"
kubectl apply -f - <<YAML
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: ${DRILL_CLUSTER}
  namespace: ${NS}
  labels: { cnpg.io/drill: "true" }
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:18.4@sha256:6138f19539304b585c6cafd1af82ca407f184139459a8e06f0880df4556d3588
  storage: { size: 40Gi, storageClass: drill-ssd }      # Delete reclaim → PVC 삭제 시 PV 자동 제거 (누수 없음, PV RBAC 불필요)
  walStorage: { size: 10Gi, storageClass: drill-ssd }
  resources:
    requests: { cpu: 250m, memory: 768Mi }
    limits:   { cpu: "1", memory: 1Gi }
  bootstrap:
    recovery:
      source: r2-source
  externalClusters:
    - name: r2-source
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: pg-r2
          serverName: ${ARCHIVE_SERVER}
YAML

echo "[drill] waiting for ${DRILL_CLUSTER} to reach healthy phase"
PHASE=""
SAW_NONHEALTHY=0
for i in $(seq 1 "$MAX_POLLS"); do
  PHASE="$(kubectl -n "$NS" get cluster "$DRILL_CLUSTER" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  echo "  attempt ${i}: phase=${PHASE:-<none>}"
  if [ "$PHASE" = "Cluster in healthy state" ]; then break; fi
  SAW_NONHEALTHY=1
  sleep "$POLL_INTERVAL"
done
[ "$PHASE" = "Cluster in healthy state" ] || fail "drill cluster never became healthy (phase=${PHASE:-none})"
# ⚠️ **복구가 실제로 일어났다는 양성 증인.** 판정에 쓰이는 관측은 `.status.phase`와 canary 행 수뿐인데,
#    전자는 생존자에게 즉시 참이다. 후자(행 수)는 **2026-08-18부터는 상수가 아니다** — 이 드릴이
#    매 실행 마커 1행을 쓰므로 지난 주 생존자의 복구본은 EXPECTED에 못 미쳐 걸린다. 즉 행 수 비교가
#    이 증인의 **이중화**가 됐다. 그래도 이 증인을 없애지 않는다: 같은 회차 안의 생존자 재사용
#    (동시 실행 창)은 행 수가 같아 구별되지 않기 때문이다. 아래는 그 이전의 근거다 — 라이브 실측
#    2026-08-17: 테이블 1행 고정, 그날 drill 로그도 `EXPECTED_ROWS=1`/`ACTUAL_ROWS=1`. 즉 pre-flight를
#    우회하는 임의의 경로(동시 실행 창, 눈먼 열거, CNPG 동작 변경)는 이 두 관측점에서 진짜 복구와
#    구별되지 않는다. R2에서의 진짜 복구는 첫 폴링에 healthy가 될 수 없으므로(같은 실측 로그:
#    1회차 phase=<none> → Setting up primary → … → 5회차에 healthy), healthy가 아닌 phase를
#    한 번도 못 봤다는 것 자체가 **생존자 재사용의 증거**다. 무-RBAC·무지연.
#    ⚠️ 위 한 줄에 백틱을 쓰지 마라. 이 파일은 push 메트릭 생산자라 `tools/check-alert-rules.ts`의
#       EXPO_INLINE이 **주석까지 포함해** 전문을 스캔하는데, 백틱/따옴표 **직후**에 소문자 식별자와
#       공백과 값 토큰이 오면 exposition 라인으로 읽힌다. 실제로 이 자리에서 위 로그 예시를 백틱으로
#       감쌌다가 그 식별자가 미등록 메트릭으로 잡혀 F-3(레지스트리 완전성)가 났다.
#    (cluster.yaml의 bootstrap 주석: "증명은 매니페스트나 ArgoCD 상태가 아니라 PGDATA 출처로만 세울 것" —
#     그 기준의 최소 실행체다. 인스턴스 로그 증인은 Role에 `pods/log`가 없어 별건이다 — rbac :12-14.)
[ "$SAW_NONHEALTHY" = "1" ] || fail "drill cluster가 **첫 폴링에 이미 healthy**였다 — R2 복구가 일어나지 않았다(생존자 재사용/동시 실행 의심). pre-flight가 무엇을 놓쳤는지 확인할 것: 잔여물 열거 접두, 수동 drill-now 동시 실행"

_drill_psql() { kubectl -n "$NS" exec "${DRILL_CLUSTER}-1" -c postgres -- psql -U postgres "$@"; }

# ─── RPO 판정: 복구본에 **그 마커**가 있는가 ────────────────────────────────────────
# ⚠️ 이 단언이 이 드릴의 성격을 바꾼다. 행 수 비교는 "테이블이 존재하고 비어 있지 않다"까지지만,
#    **방금 쓴 id가 복구본에 있다**는 것은 "아카이브가 몇 분 전 쓰기까지 담고 있다"는 뜻이다.
#    앞의 아카이브 대기가 이 단언을 통과 가능하게 만들고, 이 단언이 그 대기를 공허하지 않게 만든다 —
#    둘 중 하나만 있으면 무의미하다.
echo "[drill] RPO 판정 — 복구본에서 마커 ${MARKER_ID} 확인"
# ⚠️ id **와** ts를 함께 본다. id 단독은 시퀀스가 되감기면(pg_dump 복원의 setval 등) 옛 행과
#    충돌해 거짓 PASS가 날 수 있다 — ts가 그 구멍을 막고, 동시에 실제 RPO 수치를 준다.
MARKER_FOUND="$(_drill_psql -d "$DB" -tAc "SELECT count(*) FROM ${TABLE} WHERE id = ${MARKER_ID} AND extract(epoch from ts)::bigint = ${MARKER_TS};")" \
  || fail "복구본에서 마커를 조회하지 못했다(id=${MARKER_ID}) — 먼저 확인: 수동 drill-now 동시 실행(concurrencyPolicy는 --from=cronjob을 덮지 않는다)"
[ "$MARKER_FOUND" = "1" ] \
  || fail "RPO 위반: 복구본에 마커 id=${MARKER_ID}(ts=${MARKER_TS})가 없다(count=${MARKER_FOUND}) — 아카이브가 이 드릴 시작 시점의 쓰기를 담고 있지 않다. base backup만 실리고 WAL이 안 실렸거나 복구가 더 과거에 멈췄다. 먼저 확인: 수동 drill-now 동시 실행"
# 실제 RPO 수치 — r4의 "5분 RPO 목표"를 처음으로 **측정**한다(이분법이 아니라 초 단위).
RPO_LAG="$(_drill_psql -d "$DB" -tAc "SELECT round(extract(epoch from (now() - max(ts))))::bigint FROM ${TABLE};" || echo "?")"
echo "[drill] 마커 확인 — 복구본의 최신 쓰기가 ${RPO_LAG}초 전이다(RPO 실측)"

echo "[drill] actual row count from recovered cluster"
ACTUAL_ROWS="$(_drill_psql -d "$DB" -tAc "SELECT count(*) FROM ${TABLE};")" \
  || fail "could not read recovered row count"
echo "[drill] ACTUAL_ROWS=${ACTUAL_ROWS}"

# WAL replay가 base backup 이후 쓰인 row를 포함할 수 있으므로 >= 허용.
if [ "$ACTUAL_ROWS" -ge "$EXPECTED_ROWS" ] && [ "$ACTUAL_ROWS" -gt 0 ]; then
  push_success_metric # PASS notify 전에 실행: 메트릭 적재 실패 시 즉시 실패 (아니면 M5의 absent() 알림이 영원히 페이징)
  notify PASS "복구 ${ACTUAL_ROWS}행 (라이브 ${EXPECTED_ROWS}행) · RPO ${RPO_LAG}초 (마커 ${MARKER_ID}) — R2${ORPHAN_NOTE}${RPO_NOTE}"
  # dead-man's switch: 진짜 PASS일 때만 ping (healthcheck 정의는 M5 소유)
  curl -fsS -m 10 "${HEALTHCHECKS_URL}" >/dev/null || true
  echo "[drill] PASS"
else
  fail "row mismatch: recovered=${ACTUAL_ROWS} expected>=${EXPECTED_ROWS}"
fi

# 이 실행이 방금 만든 오브젝트가 열거에 잡히는지 먼저 본다(양성 대조) — 잡히지 않으면
# 아래 '잔여 0 확인'은 무측정 초록이다.
verify_enumeration_positive
# ⚠️ `trap - EXIT`로 EXIT trap을 해제하고 명시 정리에 인계한다 — 해제하지 않으면 정리가 두 번 돈다
#    (레포 선례: scripts/backup-local-asset.sh:54, scripts/backup-sealed-secrets-key.sh:79).
trap - EXIT
PURGE_RC=0
purge_drill || PURGE_RC=$?
# ⚠️ 실패 문구에서 RBAC 오귀속을 걷어냈다. 예전 문구는 "check the restore-drill RBAC (pvc/pv delete
#    perms)"였는데 **둘 다 틀렸다**: Role은 PVC delete를 이미 갖고 있고(restore-drill-rbac.yaml:15-18),
#    PV 권한은 설계상 없다·필요 없다(:20-24 — drill-ssd가 reclaimPolicy=Delete라 PVC 삭제로 PV가
#    자동 회수된다). 틀린 진단을 남기면 사람이 없는 권한을 찾다가 진짜 원인을 지나친다.
#    같은 이유로 '열거 실패'와 '수렴 실패'도 갈라 보고한다 — 전자에 finalizer를 보라고 하면 정확히
#    반대 방향이다.
case "$PURGE_RC" in
0) : ;;
2) fail "drill cleanup: 잔여물을 열거하지 못했다(kubectl/API 실패) — 지워졌는지 확인할 수 없다. 먼저 볼 것: API 서버 도달성, ServiceAccount 토큰, database ns의 Role 바인딩" ;;
*) fail "drill cleanup INCOMPLETE: drill Cluster/PVC가 남았다 — storage 누수이자 다음 실행이 이 생존자를 재사용할 씨앗이다. RBAC는 원인이 아니다: Role은 clusters/pvc delete를 이미 갖고 있고 PV 권한은 설계상 없다·필요 없다(drill-ssd reclaimPolicy=Delete). 먼저 볼 것: Cluster/PVC의 finalizer 잔류, CNPG operator 로그, drill-ssd StorageClass의 reclaimPolicy 드리프트" ;;
esac
# ⚠️ 검증 범위를 정확히 쓴다. 이 스크립트는 PV를 한 번도 열거하지 않는다(그럴 수도 없다 —
#    restore-drill-rbac.yaml:20-24가 PV 권한을 설계상 두지 않는다). 잔여 PV는 감사 도구 몫이다.
echo "[drill] cleanup done (Cluster + PVC 잔여 0 확인 — PV는 drill-ssd reclaimPolicy=Delete에 위임, 잔여 PV 감사는 scripts/audit-orphan-pv.sh)"
