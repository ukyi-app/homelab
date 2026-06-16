#!/usr/bin/env bats
# 알림 규칙 한국어화 게이트 — 3개 규칙 파일의 모든 summary/description이 한국어를
# 포함하는지(텔레그램 메시지가 한국어로 렌더되도록) 강제한다.
# ⚠️ 중간 단언은 [ ]만 사용 — bash 3.2(macOS)에서 [[ ]] 실패는 침묵 통과(검증된 버그).
# 비-ASCII 판정은 LC_ALL=C + 인쇄가능 ASCII 바이트 클래스 '[^ -~]'로 — BSD/GNU grep 양쪽에서
# 동작(grep -P는 macOS 기본 grep에 없다).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  RULES="$ROOT/platform/victoria-stack/rules"
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
