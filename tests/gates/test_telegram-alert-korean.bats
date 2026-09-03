#!/usr/bin/env bats
# 알림 규칙 한국어화 게이트 — `rules/*.yaml` **전건**의 모든 summary/description이 한국어를
# 포함하는지(텔레그램 메시지가 한국어로 렌더되도록) 강제한다.
# ⚠️ 로스터는 손으로 적지 않는다 — 파일 글롭에서 파생한다. 손 로스터(core/r4/r5/r6 4항)는
#    5번째 패밀리 `r7-meta.yaml`을 분모 밖에 뒀고, 그 3종(AlertRuleFlapping ·
#    AlertPipelineWriteStale · AlertSuppressionProlonged)의 annotation이 영어로 회귀해도
#    10개 판정이 전건 초록이었다(실측). 「하드코딩 소비처 목록은 자기 자신에게만 정확하다」 클래스.
#    형제 선례: tests/gates/test_vmalert-config.bats · tests/gates/vmalert-rules-validate.sh(같은 글롭).
# ⚠️ 중간 단언은 [ ]만 사용 — bash 3.2(macOS)에서 [[ ]] 실패는 침묵 통과(검증된 버그).
# 비-ASCII 판정은 LC_ALL=C + 인쇄가능 ASCII 바이트 클래스 '[^ -~]'로 — BSD/GNU grep 양쪽에서
# 동작(grep -P는 macOS 기본 grep에 없다).

# ⚠️ 아래 판정의 술어는 **출력 공허성**이지 rc가 아니다. 파이프라인 마지막 grep이 경로가 아니라
#    **stdin**(yq 출력)을 읽으므로 rc 2(대상 부재)가 원리적으로 나오지 않는다 — `-eq 1`로 바꿔도
#    아무것도 닫지 못한다. 실측: 룰 파일 경로를 없애면 yq가 에러를 내고 빈 입력이 흘러 `grep -v`가
#    rc **1**을 낸다(= "위반 0"과 "검사 대상 0"이 같은 초록).
#    그래서 여기서 닫는 방식은 rc 좁히기가 아니라 **비공허 floor + 양성 대조**다.
setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  RULES="$ROOT/platform/victoria-stack/prod/rules"
  # 비공허 floor — 열거 도메인(룰 파일)이 실재하고 비어있지 않아야 한다. 글롭이 붕괴하면
  # `f`에 패턴 리터럴이 남아 `[ -s ]`가 먼저 죽는다(fail-closed).
  # 하한 5는 래칫이 아니다 — 새 패밀리가 늘면 6>=5로 통과하고, 파일 소실에만 red다.
  nfiles=0
  for f in "$RULES"/*.yaml; do
    [ -s "$f" ]
    nfiles=$((nfiles + 1))
  done
  [ "$nfiles" -ge 5 ]
  # 양성 대조 — 위 floor는 "파일이 있다"만 본다. 추출이 0줄이어도 아래 판정은 초록이므로
  # (빈 입력에 grep -v가 rc 1), 추출이 실제로 무언가를 집었다는 증인을 여기서 세운다:
  # ConfigMap 키(core.yaml/r4.yaml/…)가 바뀌면 추출이 0줄이 되어 red.
  # ⚠️ 이 대조는 **별도 @test가 아니라 setup**에 선다 — bats는 setup을 @test마다 돌리므로
  #    개별 실행(`bats -f`)에서도 판정들이 함께 닫힌다. 별도 @test로 두면 그 하나만 red가
  #    되고 나머지는 초록으로 남는다(실측: ConfigMap 키 core.yaml -> corex.yaml 뮤테이션).
  # 하한 3은 래칫이 아니다 — 현재 최소가 r7의 3건(알림 3종)이다.
  for f in "$RULES"/*.yaml; do
    key="$(yq -r '.data | keys | .[0]' "$f")"
    [ -n "$key" ]
    [ "$key" != "null" ]
    for field in summary description; do
      # grep -c는 0건에 rc 1 — 커맨드 치환이 그 rc를 삼키므로 카운트로 판정한다.
      n="$(extract_field "$f" "$key" "$field" | grep -c . || true)"
      [ "$n" -ge 3 ]
    done
  done
}

# 룰 파일 하나에서 한 필드를 전부 뽑는다. **추출식은 여기 한 곳이다** — 위 floor와 아래 판정이
# 같은 추출을 써야 한다(리터럴을 복제하면 한쪽 드리프트를 반대쪽 바닥값이 못 잡는다).
extract_field() { # $1: 룰 파일 · $2: ConfigMap 키 · $3: 필드명
  yq -r ".data[\"$2\"]" "$1" | yq -r ".. | select(has(\"$3\")) | .$3"
}

# 그 필드에서 순수 ASCII(=한국어 없음) 줄만 남긴다. 출력이 비어야 통과.
scan_ascii_only() { # $1: 룰 파일 · $2: ConfigMap 키 · $3: 필드명
  extract_field "$1" "$2" "$3" | LC_ALL=C grep -vn '[^ -~]' || true
}

@test "every rule file's summaries contain Korean" {
  bad=""
  for f in "$RULES"/*.yaml; do
    key="$(yq -r '.data | keys | .[0]' "$f")"
    out="$(scan_ascii_only "$f" "$key" summary)"
    [ -z "$out" ] || bad="$bad$(basename "$f") summary: $out
"
  done
  [ -z "$bad" ] || {
    echo "한국어가 없는 summary — 텔레그램이 영어로 렌더된다:"
    printf '%s' "$bad"
    false
  }
}

@test "every rule file's descriptions contain Korean" {
  bad=""
  for f in "$RULES"/*.yaml; do
    key="$(yq -r '.data | keys | .[0]' "$f")"
    out="$(scan_ascii_only "$f" "$key" description)"
    [ -z "$out" ] || bad="$bad$(basename "$f") description: $out
"
  done
  [ -z "$bad" ] || {
    echo "한국어가 없는 description — 텔레그램이 영어로 렌더된다:"
    printf '%s' "$bad"
    false
  }
}

@test "every rule with annotations has both summary and description (non-empty)" {
  for f in "$RULES"/*.yaml; do
    key="$(yq -r '.data | keys | .[0]' "$f")"
    run bash -c "yq -r '.data[\"$key\"]' '$f' \
      | yq -r '.. | select(has(\"annotations\")) | .annotations
               | select((.summary | length == 0) or (.description | length == 0)) | path | join(\".\")'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]   # summary/description 둘 중 하나라도 비면 위반
  done
}

@test "templating placeholders are preserved (no stray un-rendered field names)" {
  # {{ $labels.* }} / {{ $value }} 보간이 남아있어야 하는 알림에서 placeholder가 유지되는지 확인.
  run bash -c '
    yq -r ".data[\"core.yaml\"]" "'"$RULES"'/core.yaml" \
      | yq -r ".groups[].rules[] | select(.alert == \"TargetDown\") | .annotations.summary"'
  [ "$status" -eq 0 ]
  case "$output" in *'"{{ $labels.job }}"'*|*'{{ $labels.job }}'*) : ;; *) false ;; esac
  case "$output" in *'{{ $labels.instance }}'*) : ;; *) false ;; esac
}
