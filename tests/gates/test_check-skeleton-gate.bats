#!/usr/bin/env bats
# check-skeleton이 required gate(ci.yaml job 'gate')에서 실행되는지 + verify.yaml 중복 제거.
# yq 구조 파싱(주석/비활성 스텝 false-positive 차단, F10). ⚠️ [ ]만.
setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1
  if ! command -v yq >/dev/null; then
    [ -z "${CI:-}" ] || { echo "FAIL: CI인데 yq 부재 — gate 구조 검증 불가(dead-green 방지)"; return 1; }
    skip "yq 미설치(로컬만 — CI는 setup-toolchain 제공)"
  fi
}

@test "required gate has an ACTIVE run step invoking check-skeleton.sh (structural, F10)" {
  # 주석/비활성 텍스트가 아니라 jobs.gate.steps[]의 실제 run 필드 — 행두 호출만 잡는다(untouched-b-2:
  # .run 문자열 전문에 test()를 걸면 그 안의 `# 비활성화: bash scripts/check-skeleton.sh` 같은
  # 주석 줄도 매치돼 스텝을 무력화해도 초록이었다). 주석 줄은 앵커에서 탈락.
  run yq -e '.jobs.gate.steps[] | select((.run // "") | test("(^|\n)\s*bash scripts/check-skeleton\.sh")) | .run' .github/workflows/ci.yaml
  [ "$status" -eq 0 ]
}

@test "ci gate setup-toolchain enables kustomize + yq (render guard cannot silently skip in CI, F6/F10)" {
  # jobs.gate.steps[]의 setup-toolchain 스텝 with.kustomize/with.yq가 'true'(주석 아닌 실제 필드)
  run yq -e '.jobs.gate.steps[] | select((.uses // "") | test("setup-toolchain")) | (.with.kustomize == "true" and .with.yq == "true")' .github/workflows/ci.yaml
  [ "$status" -eq 0 ]; [ "$output" = "true" ]
}

@test "check-skeleton FAILS when README component table lists a nonexistent platform dir (reverse tie)" {
  run bash -c 'sed "s/| \`files\`/| \`ghostcomp\`/" README.md > /tmp/ck_readme_$$ && CK_README=/tmp/ck_readme_$$ ./scripts/check-skeleton.sh; rc=$?; rm -f /tmp/ck_readme_$$; exit $rc'
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "ghostcomp"
}

@test "check-skeleton FAILS when a platform dir's README table row is removed, even if the name is not mentioned elsewhere (forward tie)" {
  # 정방향(dir→표)이 표 행 **멤버십**인지 확인한다 — 옛 판은 `grep -q "$c" "$README"`로 파일 전체를
  # 부분문자열 검사해서, 표 행이 없어도 산문 어딘가에 이름이 있으면(cloudflared 등) 초록이었다.
  # `files`는 README에서 이 표 행에만 등장하므로 행을 지우면 표 밖 증인도 없다.
  run bash -c 'sed "/| \`files\` |/d" README.md > /tmp/ck_readme_$$ && CK_README=/tmp/ck_readme_$$ ./scripts/check-skeleton.sh; rc=$?; rm -f /tmp/ck_readme_$$; exit $rc'
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "files"
}

