#!/usr/bin/env bats
# sync-wave 원장 드리프트 가드 — root 3계층(argocd-app/root-app/apps/*)의 모든 sync-wave 값이
# SYNC-WAVES.md **root 표**에 행으로 존재하는지. manifest엔 있으나 표에 없는 값 = wave 교착 1차 신호(AGENTS.md).
# 순수 텍스트 검사(라이브 무관). + 부호는 양변에서 정규화(manifest "2" == 표 "+2").
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과.
#
# ⚠️⚠️ **여기에 `sort -u`를 쓰지 마라.** 구두점을 1차 가중에서 무시하는 콜레이션(en_US 계열)은
#   `-1`과 `1`을 같다고 보고 하나를 버린다(실측: `printf -- '-1\n1\n' | sort -u`가 en_US에서 1줄).
#   매니페스트 쪽이 삼켜지면 그 wave는 루프에 아예 안 들어가 원장 누락을 못 잡는 **fail-open**이 된다
#   (실측 2026-08-20: SYNC-WAVES.md의 `-1` 행을 지워도 en_US 초록 / C에서만 red — 이 가드가 존재
#   이유로 삼는 바로 그 드리프트를 놓쳤다). 중복 제거는 애초에 필요 없다 — 아래 루프는 멱등이다.
#   cf. `docs/traps-detail.md` 「로케일 콜레이션이 게이트를 뒤집는다 …」
#
# ⚠️ 건초더미는 **첫 표(root 전역 표)로 좁힌다.** SYNC-WAVES.md엔 표가 셋 있고, 전부 뒤지면
#   traefik/앱 내부 표의 무관한 행이 root 표의 누락을 가린다(실측: root 표 `+2` 행을 지워도
#   traefik 표의 `2`가 대신 매치돼 초록). 로케일과 무관한 별개의 over-broad haystack 결함이다.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  LEDGER="$ROOT/platform/argocd/root/SYNC-WAVES.md"
}

@test "every sync-wave value in root app definitions has a row in SYNC-WAVES.md" {
  local files mwaves lwaves w missing="" nm nl nd
  files="$(ls "$ROOT"/platform/argocd/argocd-app.yaml "$ROOT"/platform/argocd/root/root-app.yaml "$ROOT"/platform/argocd/root/apps/*.yaml)"
  mwaves="$(grep -hoE 'sync-wave: "[+-]?[0-9]+"' $files | grep -oE '[+-]?[0-9]+' | sed 's/^+//')"
  lwaves="$(awk '/^\| Wave \|/{t++} t==1' "$LEDGER" \
            | grep -E '^\|[[:space:]]*[+-]?[0-9]+[[:space:]]*\|' \
            | sed -E 's/^\|[[:space:]]*([+-]?[0-9]+)[[:space:]]*\|.*/\1/' | sed 's/^+//')"
  nm="$(printf '%s\n' "$mwaves" | grep -c . || true)"
  nl="$(printf '%s\n' "$lwaves" | grep -c . || true)"
  # 열거 붕괴 바닥값 — 정규식 드리프트든 콜레이션 붕괴든 값이 줄면 여기서 먼저 죽는다
  # (2026-08-20 실측 mwaves 10 / lwaves 10 — 정당한 축소 여유를 두되 붕괴는 못 넘긴다).
  [ "$nm" -ge 8 ] || { echo "매니페스트 wave 열거가 ${nm}건으로 붕괴했다(기대 >=8)"; false; }
  [ "$nl" -ge 8 ] || { echo "원장 root 표 wave 열거가 ${nl}건으로 붕괴했다(기대 >=8)"; false; }
  # 바닥값의 바닥값: 서로 다른 wave가 실제로 여러 개 남아 있는가. uniq는 바이트 비교라 로케일 무관.
  nd="$(printf '%s\n' "$mwaves" | LC_ALL=C sort | uniq | grep -c . || true)"
  [ "$nd" -ge 6 ] || { echo "서로 다른 wave가 ${nd}종뿐이다 — 값이 콜레이션에 삼켜졌을 수 있다(기대 >=6)"; false; }
  # ★ 부정 대조군: 원장에 없는 합성 wave 999는 **반드시** 미검출로 잡혀야 한다.
  #   lwaves가 통째로 비거나(정규식 드리프트) 매칭이 무조건 참이 되면 이 등식이 먼저 깨진다.
  for w in $mwaves 999; do
    echo "$lwaves" | grep -qxF -- "$w" || missing="$missing $w"
  done
  [ "$missing" = " 999" ] || { echo "SYNC-WAVES.md root 표 대조 실패 — 미검출:${missing} (999는 대조군이라 항상 포함)"; false; }
}

@test "every root Application is bound to its own row in the SYNC-WAVES.md root table (component <-> wave)" {
  # 위 @test는 **값**만 대조한다 — 어떤 컴포넌트가 그 wave에 있는지는 묻지 않는다. 그래서 root 표에서
  # 행 하나가 통째로 빠져도 같은 wave를 쓰는 다른 행이 그 값을 대신 만족시킨다(실측 2026-09-02:
  # namespaces(-9) 행이 없는데 root(-9)·traefik CRD(-9) 두 행 때문에 초록이었다 — 티켓 09가 README
  # 포인터를 「값은 매니페스트가 소유한다」로 우회하게 만든 바로 그 갭). 여기서 이름↔wave를 묶는다.
  # ⚠️ `sort -u` 금지 · 건초더미는 첫 표(root 전역 표)로 좁힘 — 근거는 파일 머리말과 같다.
  local files f name wave table row p pairs="" missing="" n=0
  files="$(ls "$ROOT"/platform/argocd/argocd-app.yaml "$ROOT"/platform/argocd/root/root-app.yaml "$ROOT"/platform/argocd/root/apps/*.yaml)"
  table="$(awk '/^\| Wave \|/{t++} t==1' "$LEDGER")"
  [ -n "$table" ]
  for f in $files; do
    name="$(yq '.metadata.name' "$f")"
    wave="$(yq '.metadata.annotations."argocd.argoproj.io/sync-wave"' "$f" | sed 's/^+//')"
    [ -n "$name" ]
    [ -n "$wave" ]
    pairs="$pairs $name:$wave"
    n=$((n + 1))
  done
  # 열거 붕괴 바닥값 — 글롭이 비면 루프가 0회라 어떤 대조도 안 도는 vacuous green이 된다.
  [ "$n" -ge 8 ] || { echo "root Application 열거가 ${n}건으로 붕괴했다(기대 >=8)"; false; }
  # ★ 부정 대조군: 원장에 없는 합성 컴포넌트는 **반드시** 미검출로 잡혀야 한다.
  #   표 추출이 비거나 매칭이 무조건 참이 되면 이 등식이 먼저 깨진다.
  for p in $pairs zzz-absent:-10; do
    name="${p%:*}"
    wave="${p##*:}"
    row="$(printf '%s\n' "$table" | grep -E "^\|[[:space:]]*[+]?${wave}[[:space:]]*\|" | grep -F -- "$name" || true)"
    [ -n "$row" ] || missing="$missing $name"
  done
  [ "$missing" = " zzz-absent" ] || { echo "SYNC-WAVES.md root 표에 컴포넌트 행 없음 — 미검출:${missing} (zzz-absent는 대조군이라 항상 포함)"; false; }
}
