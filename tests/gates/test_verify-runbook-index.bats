#!/usr/bin/env bats
# 런북 인덱스 가드 — 로컬 전용(docs/runbooks/는 gitignored). 이 래퍼의 계약은 **skip과 판정의 구별**이다:
# 도메인(런북 *.md)이 비면 exit 4 + `SKIP:` 마커, 있으면 exit 0/1의 실제 판정.
# 예전엔 `[ "$status" -eq 0 ]` 하나였고 **skip 경로가 그 단언을 만족**해서 — CI엔 런북이 없으므로 —
# 가드가 실제 실행 경로를 잃어도 이 래퍼가 초록이었다(vacuous). 아래는 두 갈래를 각각 단언한다.
# 픽스처는 스크립트를 복사한 임시 트리 — 스크립트가 ROOT를 BASH_SOURCE/.. 로 잡으므로 --root 플래그가 불필요하다.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  FIX="$BATS_TEST_TMPDIR/fix"
  mkdir -p "$FIX/scripts/lib" "$FIX/docs/runbooks"
  cp "$ROOT/scripts/verify-runbook-index.sh" "$FIX/scripts/"
  cp "$ROOT/scripts/lib/guard.sh" "$FIX/scripts/lib/"
  cp "$ROOT/scripts/lib/scan-floor.sh" "$FIX/scripts/lib/"
}

# 픽스처 AGENTS.md — `## 런북` 절 아래 백틱 파일명이 인덱스(실 AGENTS.md와 같은 모양).
write_index() {   # $@: 인덱스에 나열할 런북 파일명
  {
    echo "# fixture AGENTS"
    echo
    echo "## 런북 (로컬 전용)"
    echo
    for m in "$@"; do echo "| \`$m\` | 설명 |"; done
  } > "$FIX/AGENTS.md"
}

@test "signals skip (exit 4 + SKIP marker) when the runbook domain is empty" {
  write_index
  run bash "$FIX/scripts/verify-runbook-index.sh"
  [ "$status" -eq 4 ]
  echo "$output" | grep -q "^SKIP: verify-runbook-index:"
}

@test "evaluates (exit 0, no SKIP marker) when the domain exists and matches the index" {
  write_index alpha.md
  : > "$FIX/docs/runbooks/alpha.md"
  run bash "$FIX/scripts/verify-runbook-index.sh"
  [ "$status" -eq 0 ]
  out="$output"
  run grep -q "^SKIP:" <<<"$out"
  [ "$status" -ne 0 ]
}

@test "evaluates and fails when a runbook is missing from the index (forward drift)" {
  write_index alpha.md
  : > "$FIX/docs/runbooks/alpha.md"
  : > "$FIX/docs/runbooks/orphan.md"
  run bash "$FIX/scripts/verify-runbook-index.sh"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "orphan.md"
}

@test "evaluates and fails when the index lists a runbook that is absent (reverse drift)" {
  write_index alpha.md ghost.md
  : > "$FIX/docs/runbooks/alpha.md"
  run bash "$FIX/scripts/verify-runbook-index.sh"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "ghost.md"
}

@test "index extraction stops at the next section heading (does not swallow later sections)" {
  # 실측 사고: 「## 런북」 절 추출이 파일 끝까지 읽어, 뒤에 추가된 「## Agent skills」 절의
  # 백틱 .md 참조(CONTEXT.md 등)를 인덱스 항목으로 오인해 owner 머신에서 가드가 red였다.
  # 추출이 통째로 비어도 초록이 되는 vacuous를 막으려고 절 안의 ghost.md를 증인으로 세운다:
  # 절 안 ghost.md는 여전히 잡히고(추출이 살아 있음), 경계 밖 other-doc.md는 안 잡힌다(멈춤).
  write_index alpha.md ghost.md
  {
    echo
    echo "## Agent skills"
    echo
    echo "See \`docs/agents/other-doc.md\`."
  } >> "$FIX/AGENTS.md"
  : > "$FIX/docs/runbooks/alpha.md"
  run bash "$FIX/scripts/verify-runbook-index.sh"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "ghost.md"
  out="$output"
  run grep -q "other-doc.md" <<<"$out"
  [ "$status" -ne 0 ]
}

@test "a runbook mentioned only outside the section still fails the forward lane (section-scoped, not whole-file)" {
  # grep-c-5(감사 6라운드): 예전 정방향(`grep -Fq "$b" AGENTS.md`)은 파일 **전체**를 봤다 — 표에서
  # 지운 파일명이 다른 절의 산문·HTML 주석에 한 번만 남아도 그걸로 통과했다(절 밖 언급이 인덱스로
  # 둔갑). 지금은 역방향과 같은 idx_md(절 추출)에 완전일치로만 댄다.
  write_index alpha.md
  {
    echo
    echo "## 기타"
    echo
    echo "<!-- 참고: \`b.md\` -->"
  } >> "$FIX/AGENTS.md"
  : > "$FIX/docs/runbooks/alpha.md"
  : > "$FIX/docs/runbooks/b.md"
  run bash "$FIX/scripts/verify-runbook-index.sh"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "b.md"
}

@test "an empty index extraction fails loud when runbooks exist (reverse lane must not fail open)" {
  # `^## 런북` 헤딩이 개명·강등되면 추출이 0건이 된다 — 역방향 레인이 errexit로 무언 종료하는
  # 대신 명시 FAIL을 내야 한다(무언 종료는 진단이 아니다).
  write_index
  : > "$FIX/docs/runbooks/alpha.md"
  run bash "$FIX/scripts/verify-runbook-index.sh"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "추출하지 못했다"
}

@test "runbook-index guard exists and is local-only" {
  S="$ROOT/scripts/verify-runbook-index.sh"
  [ -f "$S" ]
  run grep -Eq 'docs/runbooks|AGENTS.md' "$S"; [ "$status" -eq 0 ]
}

# 실 레포 실행 — venue에 따라 갈린다(owner 머신=런북 실재, CI/fresh checkout=부재).
# 두 갈래를 각각 단언해야 skip이 판정으로 위장하지 못한다. bash 호출=exec비트 무의존(F3).
@test "against the real repo it either evaluates or announces skip, never both" {
  S="$ROOT/scripts/verify-runbook-index.sh"
  run bash "$S"
  if ls "$ROOT"/docs/runbooks/*.md >/dev/null 2>&1; then
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "정합 OK"
  else
    [ "$status" -eq 4 ]
    echo "$output" | grep -q "^SKIP: verify-runbook-index:"
  fi
}

@test "existing verify-runbooks DR bats runner target is preserved (not replaced, F2)" {
  run grep -Eq 'bats .*docs/runbooks|bats "\$\$RB"' "$ROOT/Makefile"; [ "$status" -eq 0 ]
}
