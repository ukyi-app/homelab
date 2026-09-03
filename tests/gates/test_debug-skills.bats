#!/usr/bin/env bats
# 디버그 스킬 rot 가드 — .claude/skills/{argo,observability}가 (1)name/description 프론트매터를
# 갖고 (2)참조하는 make 타겟이 실제 존재하는지. 스킬이 죽은 타겟을 가리키는 드리프트를 차단.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과.

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "debug skills carry name and description frontmatter" {
  for s in argo observability; do
    run head -5 ".claude/skills/$s/SKILL.md"
    echo "$output" | grep -qE "^name: $s"
    echo "$output" | grep -qE "^description: "
  done
}

@test "every make target referenced by a debug skill exists in the Makefile" {
  # untouched-b-4: 문자 클래스에 숫자가 없어 m6-tools 같은 타겟에서 앵커드 매치가 실패했다
  # (형제 test_make-help.bats:28-34가 같은 결함을 실측·수정한 형태 그대로 이식 — LC_ALL=C 필수,
  # docs/traps-detail.md 「로케일 콜레이션이 게이트를 뒤집는다」). `.`는 클래스에 넣지 않는다 —
  # 여기 피연산자는 산문이라 문장 끝 마침표가 타겟명에 삼켜져 거짓 red가 난다(형제는 Makefile
  # 선언 앵커드 파싱이라 표면이 다르다).
  local t
  for t in $(LC_ALL=C grep -rhoE 'make [a-zA-Z0-9][a-zA-Z0-9_-]*' .claude/skills/*/SKILL.md | sed 's/^make //' | LC_ALL=C sort -u); do
    grep -qE "^$t:" Makefile || { echo "스킬이 참조하는 make 타겟 부재: $t"; false; }
  done
}
