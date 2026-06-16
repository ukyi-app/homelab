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
  local t
  for t in $(grep -rhoE 'make [a-z][a-z-]+' .claude/skills/*/SKILL.md | sed 's/^make //' | sort -u); do
    grep -qE "^$t:" Makefile || { echo "스킬이 참조하는 make 타겟 부재: $t"; false; }
  done
}
