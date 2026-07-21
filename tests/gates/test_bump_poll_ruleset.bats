#!/usr/bin/env bats
# F-0: bump-poll/** ref 네임스페이스를 writer App 전용으로 예약하는 ruleset이 무인 편집으로 약화되지
# 못하게 잠근다(CI-safe, 라이브 API 미호출, 파일 구조만).
#
# ── 정직한 한계(red-team으로 입증) ────────────────────────────────────────────────────────────
# 정적 텍스트 가드는 terraform HCL의 **resolved 의미**를 검증할 수 없다. 개별 grep 토큰 단언(예전 버전)은
# 8개 적대 각도에서 전부 우회됐다: decoy 블록(locals/변수/data)이 파일 전역 grep을 만족시키고, 간접화
# (var/local/함수)가 실제 값을 리터럴 위치 밖으로 빼며, meta-argument(count=0 / for_each={})가 리소스를
# 0개 인스턴스로 만들어 룰셋을 통째로 없애고, 인라인 /* */ 주석이 앵커 카운트를 회피하며, cross-file
# 값(variables.tf)이 rulesets.tf-only 검사를 피한다. 전부 terraform validate를 통과한다.
#
# 그래서 이 가드는 **블랙리스트(공격 열거)가 아니라 화이트리스트(정규형 freeze)**다: 보안 핵심 3블록
# (data github_app.writer · resource ruleset · variable writer_app_slug)을 추출→주석 제거→공백 정규화한
# 뒤 **핀된 canonical과 정확히 일치**해야 한다. 세 블록 밖의 decoy는 무관하고, 블록 안의 어떤 간접화·
# meta-arg·추가 actor·값 변경도 canonical을 바꿔 잡힌다. 즉 이 가드는 **변경 감지기**다 — 보안 블록에
# 손대면 CI가 red가 되어 owner 재검토·재검증을 강제한다.
# **실제 강제 동작(resolved 의미)의 권위 검증은 owner-local Seam C**(apply + 적대 라이브 테스트)다.
#
# canonical 재생성(블록을 의도적으로 바꿨을 때): canonical_blocks를 실제 파일에 돌린 출력으로 아래
# CANONICAL 리터럴을 교체한다. 그 변경 자체가 리뷰 대상이다.
# deletion 규칙은 이번 increment 범위 밖이라 canonical에 없다(spec R-2 — 후속이 정리경로와 함께 추가).
# @test 이름은 영어(디렉토리 단위 실행 시 한글 인코딩 깨짐 — AGENTS.md).

TF="$BATS_TEST_DIRNAME/../../infra/github/rulesets.tf"
VARS="$BATS_TEST_DIRNAME/../../infra/github/variables.tf"

# 보안 3블록의 정규형: 각 블록을 header~(컬럼0 })로 추출 → 주석(#, //, 인라인 /* */) 제거 →
# 모든 공백 정규화(fmt 정렬·개행 무해화) → 1줄 토큰열. bash 3.2 호환(파이프·sed·tr만).
extract_block() { sed -n "/$2/,/^}/p" "$1"; }
canonical_blocks() {
  {
    extract_block "$1" '^data "github_app" "writer" {'
    extract_block "$1" '^resource "github_repository_ruleset" "bump_poll_writer_only" {'
    extract_block "$2" '^variable "writer_app_slug" {'
  } | sed -E 's://.*$::; s:#.*$::; s:/\*[^*]*\*/::g' | tr '\n' ' ' | tr -s '[:space:]' ' ' | sed -E 's/^ //; s/ $//'
}

# 핀된 canonical(신뢰 앵커의 리뷰된 형태). 위 재생성 절차로만 갱신한다.
CANONICAL='data "github_app" "writer" { slug = var.writer_app_slug } resource "github_repository_ruleset" "bump_poll_writer_only" { name = "bump-poll-writer-only" repository = github_repository.homelab.name target = "branch" enforcement = "active" conditions { ref_name { include = ["refs/heads/bump-poll/**"] exclude = [] } } rules { creation = true update = true } bypass_actors { actor_id = tonumber(data.github_app.writer.id) actor_type = "Integration" bypass_mode = "always" } } variable "writer_app_slug" { type = string default = "ukyi-homelab-writer" }'

@test "security blocks match the pinned canonical form" {
  got="$(canonical_blocks "$TF" "$VARS")"
  [ "$got" = "$CANONICAL" ] || { echo "canonical 불일치 — 실제:"; echo "$got"; false; }
}

# ── 뮤테이션 증인 — red-team이 예전 grep 가드를 뚫은 각 클래스가 canonical에서 잡힘을 증명 ──────
# 각 증인: 사본을 변형 → canonical이 핀과 달라짐(≠)을 단언. 변형은 원본을 건드리지 않는다.

@test "witness: indirection — target=var.tgt + decoy locals is caught" {
  c="$(mktemp)"
  sed -E 's/^([[:space:]]*target[[:space:]]*=[[:space:]]*)"branch"/\1var.tgt/' "$TF" > "$c"
  printf '\nlocals { target = "branch" }\n' >> "$c"
  [ "$(canonical_blocks "$c" "$VARS")" != "$CANONICAL" ]
  rm -f "$c"
}

@test "witness: case-evasion — enforcement=lower(\"DISABLED\") + decoy is caught" {
  c="$(mktemp)"
  sed -E 's/^([[:space:]]*enforcement[[:space:]]*=[[:space:]]*)"active"/\1lower("DISABLED")/' "$TF" > "$c"
  printf '\nlocals { enforcement = "active" }\n' >> "$c"
  [ "$(canonical_blocks "$c" "$VARS")" != "$CANONICAL" ]
  rm -f "$c"
}

@test "witness: meta-arg — for_each={} disabling the resource is caught" {
  c="$(mktemp)"
  sed -E 's/^(resource "github_repository_ruleset" "bump_poll_writer_only" \{)/\1\n  for_each = {}/' "$TF" > "$c"
  [ "$(canonical_blocks "$c" "$VARS")" != "$CANONICAL" ]
  rm -f "$c"
}

@test "witness: meta-arg — count=0 disabling the resource is caught" {
  c="$(mktemp)"
  sed -E 's/^(resource "github_repository_ruleset" "bump_poll_writer_only" \{)/\1\n  count = 0/' "$TF" > "$c"
  [ "$(canonical_blocks "$c" "$VARS")" != "$CANONICAL" ]
  rm -f "$c"
}

@test "witness: comment-prefixed second bypass actor is caught" {
  c="$(mktemp)"
  awk '/^}/ && !d { print "  /* extra */ bypass_actors {"; print "    /* id */ actor_id = 99999"; print "    actor_type  = \"Integration\""; print "    bypass_mode = \"always\""; print "  }"; d=1 } {print}' "$TF" > "$c"
  [ "$(canonical_blocks "$c" "$VARS")" != "$CANONICAL" ]
  rm -f "$c"
}

@test "witness: identity redirect — writer data source slug literal + decoy is caught" {
  c="$(mktemp)"
  sed -E 's/^([[:space:]]*slug[[:space:]]*=[[:space:]]*)var\.writer_app_slug/\1"ukyi-homelab-attacker"/' "$TF" > "$c"
  printf '\ndata "github_app" "pin_decoy" { slug = var.writer_app_slug }\n' >> "$c"
  [ "$(canonical_blocks "$c" "$VARS")" != "$CANONICAL" ]
  rm -f "$c"
}

@test "witness: cross-file — writer_app_slug default redirect + decoy var is caught" {
  c="$(mktemp)"
  sed -E 's/^([[:space:]]*default[[:space:]]*=[[:space:]]*)"ukyi-homelab-writer"/\1"attacker-app"/' "$VARS" > "$c"
  printf '\nvariable "writer_app_slug_note" { type = string\n  default = "ukyi-homelab-writer" }\n' >> "$c"
  [ "$(canonical_blocks "$TF" "$c")" != "$CANONICAL" ]
  rm -f "$c"
}

@test "witness: cross-file — deleting the writer_app_slug default is caught" {
  c="$(mktemp)"
  sed -E '/^[[:space:]]*default[[:space:]]*=[[:space:]]*"ukyi-homelab-writer"/d' "$VARS" > "$c"
  printf '\nvariable "pinned_note" { type = string\n  default = "ukyi-homelab-writer" }\n' >> "$c"
  [ "$(canonical_blocks "$TF" "$c")" != "$CANONICAL" ]
  rm -f "$c"
}

@test "witness: decoy-locals include redirect to a dead namespace is caught" {
  c="$(mktemp)"
  sed -E 's#^([[:space:]]*include[[:space:]]*=[[:space:]]*)\["refs/heads/bump-poll/\*\*"\]#\1["refs/heads/__dead__/**"]#' "$TF" > "$c"
  printf '\nlocals { include = ["refs/heads/bump-poll/**"] }\n' >> "$c"
  [ "$(canonical_blocks "$c" "$VARS")" != "$CANONICAL" ]
  rm -f "$c"
}

@test "witness: decoy-locals exclude carve-out of the namespace is caught" {
  c="$(mktemp)"
  sed -E 's#^([[:space:]]*exclude[[:space:]]*=[[:space:]]*)\[\]#\1["refs/heads/bump-poll/**"]#' "$TF" > "$c"
  printf '\nlocals { exclude = [] }\n' >> "$c"
  [ "$(canonical_blocks "$c" "$VARS")" != "$CANONICAL" ]
  rm -f "$c"
}

@test "control: a harmless comment change does not trip the canonical guard" {
  c="$(mktemp)"
  sed -E 's/# bypass = writer App 하나.*/# 주석만 변경/' "$TF" > "$c"
  [ "$(canonical_blocks "$c" "$VARS")" = "$CANONICAL" ]
  rm -f "$c"
}
