#!/usr/bin/env bats
# 스테이징 완전성 gate — "도구가 천장 밖에 쓰면 그 변경이 커밋에서 조용히 유실되고 PR이 부분 표면으로
# 열린다"는 실패를 막는 **잔여물 판정**이 천장을 선언한 모든 `git add` 콜사이트에 있는지 잰다.
#
# 🔴 실측 근거는 2026-08-18 라이브 사고다(.github/workflows/_create-app.yaml:135-139 주석이 SSOT):
#    create-app.ts가 digest-exporter.yaml에도 쓰는데 그 경로가 add-paths 천장 밖이라 수정이 커밋에서
#    유실됐다. add·commit·push·PR이 **전부 성공**하므로 어떤 종료코드도 그 유실을 말하지 않는다.
#
# ★ 로스터를 손으로 적지 않는다. 콜사이트는 소스에서 **파생**하고, 면제도 이름이 아니라 **성질**로
#   판정한다 — "천장(pathspec)을 선언하지 않는 add"(예: `git add -A`, 앱 레포 스캐폴드)는 잔여물을
#   가둘 상한이 애초에 없으므로 이 판정의 대상이 아니다. 이름 면제 목록을 쓰면 그 목록이 다음 사본이
#   된다(같은 클래스: docs/traps-detail.md 「이미지 핀의 존재 ≠ 일치 ≠ 소유자」).
#
# ⚠️ 여기 있는 것은 **정적 절반 + 블록 실행 절반**이다. "천장이 실제로 맞는가"는 각 레인의 실행
#    증인이 진다(tools/tests/test_run-bump-plan.bats · tools/tests/test_create-app.bats:290).
# ⚠️ @test 이름은 영어 · 중간 단언은 단일 대괄호만(bash 3.2 [[ ]] 침묵 통과 — AGENTS.md).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1
  MARK='[staged-completeness]'
}

# 주석을 지운 뷰(줄 수 보존 — 줄번호가 원본과 정렬돼야 마커·판정·add의 순서를 잴 수 있다).
code_view() {
  # 다른 세션이 워킹 트리를 동시에 편집한다 — 글롭과 읽기 사이에 파일이 사라질 수 있다.
  [ -f "$1" ] || return 0
  case "$1" in
    *.ts|*.mts) sed 's#^[[:space:]]*//.*$##' "$1" ;;
    *)          sed 's/^[[:space:]]*#.*$//' "$1" ;;
  esac
}

# 이 파일의 `git add` 호출 중 **천장을 선언한** 것들의 줄번호(없으면 빈 출력).
# 셸/YAML은 줄머리 명령만 본다(문자열 안의 산문 "git add 실패"를 명령으로 오인하지 않는다).
# TS는 exec seam의 argv 배열(`["add", …]`)만 본다.
ceiling_add_lines() {
  f="$1"
  case "$f" in
    *.ts|*.mts) pat='\["add"[^]]*\]' ;;
    *)          pat='^[[:space:]]*git add [^;|&)]*' ;;
  esac
  code_view "$f" | grep -nE "$pat" | while IFS= read -r hit; do
    ln="${hit%%:*}"
    op="$(printf '%s' "${hit#*:}" | grep -oE "$pat" | head -1)"
    # 피연산자만 남긴다 — 플래그(-A/-u/--)와 배열 구두점은 천장이 아니다.
    rest="$(printf '%s' "$op" \
      | sed -e 's/^[[:space:]]*git add //' -e 's/^\["add"//' -e 's/\]$//' -e 's/[",]/ /g' \
      | awk '{for(i=1;i<=NF;i++) if ($i!="-A" && $i!="--all" && $i!="-u" && $i!="--update" && $i!="--" && $i!="-f" && $i!="-q") printf "%s ", $i}')"
    [ -z "$rest" ] || printf '%s\t%s\n' "$ln" "$rest"
  done
}

extract_block() {  # $1=레포 상대 경로 — 마커 사이를 뽑고 첫 줄의 들여쓰기만큼 벗긴다(YAML 블록 스칼라 복원)
  # ⚠️ 셸 함수에 지역 변수가 없다 — 호출자의 이름과 겹치면 조용히 덮어쓴다(실측으로 밟았다).
  _eb_text="$(sed -n "/\\[staged-completeness\\]/,/\\[\\/staged-completeness\\]/p" "$1")"
  _eb_ind="$(printf '%s\n' "$_eb_text" | head -1 | sed 's/[^[:space:]].*$//')"
  printf '%s\n' "$_eb_text" | sed "s/^$_eb_ind//"
}

# 스캔 우주 — 레포에서 원격으로 나가는 쓰기를 만드는 모든 실행 표면.
scan_files() {
  for f in "$ROOT"/.github/workflows/*.yaml "$ROOT"/.github/actions/*/action.yml \
           "$ROOT"/scripts/*.sh "$ROOT"/tools/*.ts "$ROOT"/tools/*.mts "$ROOT"/tools/lib/*.ts; do
    [ -e "$f" ] || continue
    echo "${f#"$ROOT"/}"
  done
}

@test "every git-add callsite that declares a ceiling carries the staged-completeness judgment before it" {
  scanned=0; ceiling=0; open=0; bad=""
  while IFS= read -r f; do
    scanned=$((scanned + 1))
    lines="$(ceiling_add_lines "$f")"
    if [ -z "$lines" ]; then
      # 천장 미선언 add가 이 파일에 있는지(= 면제 분기가 실제로 밟히는지)를 따로 센다.
      case "$f" in
        *.ts|*.mts) p2='\["add"[^]]*\]' ;;
        *)          p2='^[[:space:]]*git add [^;|&)]*' ;;
      esac
      if code_view "$f" | grep -qE "$p2"; then open=$((open + 1)); fi
      continue
    fi
    ceiling=$((ceiling + 1))
    # ① 마커 — 판정 블록이 이 파일에 실재한다(원본 뷰: 마커는 주석이다).
    m="$(grep -nF "$MARK" "$f" | head -1 | cut -d: -f1)"
    if [ -z "$m" ]; then bad="$bad $f(마커없음)"; continue; fi
    blk="$BATS_TEST_TMPDIR/blk.$ceiling"; extract_block "$f" > "$blk"
    # ② 각 천장 add를 **개별로** 판정한다 — 파일에 판정이 하나 있다는 사실은 나중에 들어온 다른
    #    천장의 add를 덮지 않는다(그 add의 유실은 여전히 조용하다).
    while IFS="$(printf '\t')" read -r a rest; do
      [ -n "$a" ] || continue
      # 코드 — 마커가 주석뿐인 파일을 배제한다. 판정 본체(`git status --porcelain`)가
      # **주석 제거 뷰**에 있어야 하고, 마커 뒤이자 이 add 앞이어야 한다.
      sl="$(code_view "$f" | grep -n -- '--porcelain' | cut -d: -f1 | awk -v a="$a" '$1 < a {last=$1} END {print last}')"
      if [ -z "$sl" ]; then bad="$bad $f:$a(판정없음)"; continue; fi
      [ "$m" -lt "$sl" ] || bad="$bad $f:$a(마커=$m≥판정=$sl)"
      [ "$sl" -lt "$a" ] || bad="$bad $f:$a(판정=$sl≥add=$a)"
      # ③ 결속 — 이 add의 천장 피연산자가 전부 판정 블록 안에 나타나야 한다. 없으면 판정이 **다른**
      #    천장을 재고 있다는 뜻이고, 그 add의 유실은 아무도 안 본다(파일 단위 판정의 사각).
      for tok in $rest; do
        grep -qF -- "$tok" "$blk" || bad="$bad $f:$a(천장 $tok 미결속)"
      done
    done <<INNER
$lines
INNER
  done <<EOF
$(scan_files)
EOF

  # 비공허 바닥값 — 스캔·양쪽 분기가 모두 실제로 밟혔다. 하나라도 0이면 아래 전칭이 항진이다.
  [ "$scanned" -ge 1 ] || { echo "enumeration collapse: 스캔 대상 0개 — 글롭이 붕괴했다"; false; }
  [ "$ceiling" -ge 1 ] || { echo "enumeration collapse: 천장 선언 콜사이트 0곳 — 검출기가 붕괴했다"; false; }
  [ "$open" -ge 1 ] || { echo "enumeration collapse: 천장 미선언 add 0곳 — '성질로 파생 제외' 분기가 무증인이다"; false; }
  # 부분 실명 대책 — 구조 스캔이 센 add 호출부 파일 수 == 같은 우주의 raw 열거(둘이 어긋나면 red).
  raw=0
  while IFS= read -r f; do
    case "$f" in *.ts|*.mts) p3='\["add"[^]]*\]' ;; *) p3='^[[:space:]]*git add [^;|&)]*' ;; esac
    if code_view "$f" | grep -qE "$p3"; then raw=$((raw + 1)); fi
  done <<EOF
$(scan_files)
EOF
  [ "$((ceiling + open))" -eq "$raw" ] || { echo "partial blindness: 분류 $((ceiling + open)) ≠ raw 열거 $raw"; false; }

  [ -z "$bad" ] || { echo "잔여물 판정이 없거나 add 뒤에 있는 콜사이트:$bad"; false; }
}

# ── 블록 실행 증인 ────────────────────────────────────────────────────────────────────────────
# 셸/YAML 세 레인의 판정 블록을 **소스에서 그대로 뽑아** 픽스처 repo에서 돌린다. 판정문을 여기에
# 다시 쓰면 그 사본이 원본과 조용히 갈라진다(이 캠페인이 반복해 밟은 형태).

mkfixture() {  # 천장 안 2파일을 고친 깨끗한 레인(= 잔여물 0이어야 하는 정상 상태)
  FX="$BATS_TEST_TMPDIR/fx.$1"; rm -rf "$FX"; mkdir -p "$FX/apps/orders" "$FX/platform/victoria-stack/prod" "$FX/docs" "$FX/infra/cloudflare"
  echo v > "$FX/apps/orders/values.yaml"
  echo d > "$FX/platform/victoria-stack/prod/digest-exporter.yaml"
  echo m > "$FX/docs/memory-ledger.md"
  echo j > "$FX/infra/cloudflare/apps.json"
  git -C "$FX" init -q -b main; git -C "$FX" config user.email t@t; git -C "$FX" config user.name t
  git -C "$FX" add -A; git -C "$FX" commit -q -m init
  echo v2 >> "$FX/apps/orders/values.yaml"          # 도구가 천장 **안**에 쓴 변경
  echo d2 >> "$FX/platform/victoria-stack/prod/digest-exporter.yaml"
}

run_block() {  # $1=소스 파일 · $2=천장 env 할당 줄 — 픽스처에서 블록을 그대로 실행
  SCRIPT="$BATS_TEST_TMPDIR/blk.sh"
  { echo 'set -euo pipefail'; [ -z "$2" ] || echo "$2"; extract_block "$1"; } > "$SCRIPT"
  # 추출 바닥값 — 마커가 리네임되면 블록이 비어 스크립트가 무조건 exit 0이 된다(무증인 초록).
  n="$(grep -c -- '--porcelain' "$SCRIPT")"
  [ "$n" -ge 1 ] || { echo "추출 붕괴: $1에서 판정 블록을 못 뽑았다(마커 드리프트)"; false; }
  run bash -c "cd '$FX' && exec bash '$SCRIPT'"
}

@test "each shell lane's extracted judgment passes a clean tree and rejects a write outside its ceiling" {
  # ALLOWLIST는 teardown.sh 자신에서 파생한다 — 여기 베껴 쓰면 그 사본이 천장의 두 번째 진실이 된다.
  ALLOW="$(sed -n 's/^ALLOWLIST="\(.*\)"$/\1/p' scripts/teardown.sh)"
  [ -n "$ALLOW" ] || { echo "teardown.sh의 ALLOWLIST 선언을 못 읽었다"; false; }

  lanes=0
  # "<파일>|<천장 env 할당>" — bump.yaml은 천장이 블록 안 리터럴이라 할당이 없다.
  while IFS='|' read -r f assign; do
    [ -n "$f" ] || continue
    lanes=$((lanes + 1))
    mkfixture "$lanes"

    # ① 정상 레인 — 천장 안 변경만 있으면 통과한다(바닥값: 픽스처에 변경이 실재한다).
    st="$(git -C "$FX" status --porcelain)"
    [ -n "$st" ] || { echo "픽스처 붕괴: 변경 0건이면 아래 통과가 항진이다($f)"; false; }
    run_block "$f" "$assign"
    [ "$status" -eq 0 ] || { echo "정상 레인이 red다($f): $output"; false; }

    # ② 천장 밖 쓰기 — 거부하고, 진단이 그 경로를 지목한다(비-0만 보면 다른 이유로 죽어도 통과한다).
    mkdir -p "$FX/built"; echo x > "$FX/built/orders"
    run_block "$f" "$assign"
    [ "$status" -ne 0 ] || { echo "천장 밖 쓰기를 통과시켰다($f)"; false; }
    echo "$output" | grep -qF "built/orders"
  done <<EOF
.github/actions/pr-first-commit/action.yml|ADD_PATHS="apps/orders platform/victoria-stack/prod/digest-exporter.yaml"
scripts/teardown.sh|ALLOWLIST="$ALLOW"
.github/workflows/bump.yaml|
EOF
  [ "$lanes" -eq 3 ] || { echo "enumeration collapse: 레인 $lanes개만 돌았다(기대 3)"; false; }
}

@test "the bump lane keeps its build artifact out of the checkout (the residue judgment would flag it)" {
  # bump.yaml은 build run의 `built-*` 아티팩트를 내려받는다. 그 자리가 워크스페이스(=레포 체크아웃)
  # 안이면 untracked 잔여물이 되어 위 판정이 정상 실행에서 red가 된다 — 중간 산출물은 /tmp(runner.temp)
  # 아니면 gitignored여야 한다는 규약의 이 레인 몫이다.
  run grep -c 'path: built$' .github/workflows/bump.yaml
  [ "$output" = "0" ]
  # 양성 대조 — 같은 술어가 이 파일 어딘가에서는 매치한다(0건이 "안 본다"가 되지 않게).
  run grep -c 'path: \${{ runner.temp }}/built' .github/workflows/bump.yaml
  [ "$output" = "1" ]
}
