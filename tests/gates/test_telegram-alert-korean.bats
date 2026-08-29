#!/usr/bin/env bats
# 알림 규칙 한국어화 게이트 — 3개 규칙 파일의 모든 summary/description이 한국어를
# 포함하는지(텔레그램 메시지가 한국어로 렌더되도록) 강제한다.
# ⚠️ 중간 단언은 [ ]만 사용 — bash 3.2(macOS)에서 [[ ]] 실패는 침묵 통과(검증된 버그).
# 비-ASCII 판정은 LC_ALL=C + 인쇄가능 ASCII 바이트 클래스 '[^ -~]'로 — BSD/GNU grep 양쪽에서
# 동작(grep -P는 macOS 기본 grep에 없다).

# ⚠️ 아래 8개 판정의 `[ "$status" -ne 0 ]`은 **전환 대상이 아니다**. 파이프라인 마지막 grep이
#    경로가 아니라 **stdin**(yq 출력)을 읽으므로 rc 2(대상 부재)가 원리적으로 나오지 않는다 —
#    `-eq 1`로 바꿔도 아무것도 닫지 못한다. 실측: 룰 파일 경로를 없애면 yq가 에러를 내고 빈
#    입력이 흘러 `grep -v`가 rc **1**을 낸다(= "위반 0"과 "검사 대상 0"이 같은 초록).
#    그래서 여기서 닫는 방식은 rc 좁히기가 아니라 **비공허 floor + 양성 대조**다.
setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  RULES="$ROOT/platform/victoria-stack/prod/rules"
  # 비공허 floor — 열거 도메인(룰 파일 4개)이 실재하고 비어있지 않아야 한다.
  for f in core.yaml r4-storage-backup.yaml r5-cert-tls.yaml r6-ci-staleness.yaml; do
    [ -s "$RULES/$f" ]
  done
  # 양성 대조 — 위 floor는 "파일이 있다"만 본다. 추출이 0줄이어도 8개 판정은 초록이므로
  # (빈 입력에 grep -v가 rc 1), 추출이 실제로 무언가를 집었다는 증인을 여기서 세운다:
  # 룰 파일이 사라지거나 ConfigMap 키(core.yaml/r4.yaml/...)가 바뀌면 추출이 0줄이 되어 red.
  # ⚠️ 이 대조는 **별도 @test가 아니라 setup**에 선다 — bats는 setup을 @test마다 돌리므로
  #    개별 실행(`bats -f`)에서도 8개 판정이 함께 닫힌다. 별도 @test로 두면 그 하나만 red가
  #    되고 8개는 초록으로 남는다(실측: ConfigMap 키 core.yaml -> corex.yaml 뮤테이션).
  #    각 @test는 자기 파이프라인을 `run bash -c` 서브셸에서 다시 돌리므로 카운트를 변수로
  #    넘겨줄 자리가 없다 — setup이 먼저 죽는 것으로 충분하다.
  # 하한 3은 래칫이 아니다 — 현재 최소가 r5의 4건(summary/description 각각)이다.
  for spec in "core.yaml:core.yaml" "r4.yaml:r4-storage-backup.yaml" "r5.yaml:r5-cert-tls.yaml" "r6.yaml:r6-ci-staleness.yaml"; do
    key="${spec%%:*}"; file="${spec##*:}"
    for field in summary description; do
      # grep -c는 0건에 rc 1 — 커맨드 치환이 그 rc를 삼키므로 카운트로 판정한다.
      n="$(yq -r ".data[\"$key\"]" "$RULES/$file" \
             | yq -r ".. | select(has(\"$field\")) | .$field" \
             | grep -c . || true)"
      [ "$n" -ge 3 ]
    done
  done
}

@test "core.yaml summaries all contain Korean" {
  run bash -c '
    yq -r ".data[\"core.yaml\"]" "'"$RULES"'/core.yaml" \
      | yq -r ".. | select(has(\"summary\")) | .summary" \
      | LC_ALL=C grep -vn "[^ -~]"'
  [ "$status" -ne 0 ]   # 위반 줄이 없어야 한다(grep -v가 아무것도 못 찾아 status=1)
  [ -z "$output" ]
}

@test "core.yaml descriptions all contain Korean" {
  run bash -c '
    yq -r ".data[\"core.yaml\"]" "'"$RULES"'/core.yaml" \
      | yq -r ".. | select(has(\"description\")) | .description" \
      | LC_ALL=C grep -vn "[^ -~]"'
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "r4-storage-backup summaries all contain Korean" {
  run bash -c '
    yq -r ".data[\"r4.yaml\"]" "'"$RULES"'/r4-storage-backup.yaml" \
      | yq -r ".. | select(has(\"summary\")) | .summary" \
      | LC_ALL=C grep -vn "[^ -~]"'
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "r4-storage-backup descriptions all contain Korean" {
  run bash -c '
    yq -r ".data[\"r4.yaml\"]" "'"$RULES"'/r4-storage-backup.yaml" \
      | yq -r ".. | select(has(\"description\")) | .description" \
      | LC_ALL=C grep -vn "[^ -~]"'
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "r5-cert-tls summaries all contain Korean" {
  run bash -c '
    yq -r ".data[\"r5.yaml\"]" "'"$RULES"'/r5-cert-tls.yaml" \
      | yq -r ".. | select(has(\"summary\")) | .summary" \
      | LC_ALL=C grep -vn "[^ -~]"'
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "r5-cert-tls descriptions all contain Korean" {
  run bash -c '
    yq -r ".data[\"r5.yaml\"]" "'"$RULES"'/r5-cert-tls.yaml" \
      | yq -r ".. | select(has(\"description\")) | .description" \
      | LC_ALL=C grep -vn "[^ -~]"'
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "r6-ci-staleness summaries all contain Korean" {
  run bash -c '
    yq -r ".data[\"r6.yaml\"]" "'"$RULES"'/r6-ci-staleness.yaml" \
      | yq -r ".. | select(has(\"summary\")) | .summary" \
      | LC_ALL=C grep -vn "[^ -~]"'
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "r6-ci-staleness descriptions all contain Korean" {
  run bash -c '
    yq -r ".data[\"r6.yaml\"]" "'"$RULES"'/r6-ci-staleness.yaml" \
      | yq -r ".. | select(has(\"description\")) | .description" \
      | LC_ALL=C grep -vn "[^ -~]"'
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "every rule with annotations has both summary and description (non-empty)" {
  for spec in "core.yaml:core.yaml" "r4.yaml:r4-storage-backup.yaml" "r5.yaml:r5-cert-tls.yaml" "r6.yaml:r6-ci-staleness.yaml"; do
    key="${spec%%:*}"; file="${spec##*:}"
    run bash -c '
      yq -r ".data[\"'"$key"'\"]" "'"$RULES"'/'"$file"'" \
        | yq -r ".. | select(has(\"annotations\")) | .annotations
                 | select((.summary | length == 0) or (.description | length == 0)) | path | join(\".\")"'
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
