#!/usr/bin/env bats
# F-0: bump-poll/** ref 네임스페이스를 writer App 전용으로 예약하는 ruleset이 무인 편집으로 약화되지
# 못하게 잠근다(CI-safe, 라이브 API 미호출, 파일 구조만).
#
# ── 정직한 한계(structure 게이트 S-1/S-2 + 8각도 red-team으로 입증) ──────────────────────────────
# 정적 텍스트 가드는 terraform HCL의 **resolved 모듈 의미**를 완전히 검증할 수 없다. 개별 grep 토큰 단언은
# 8각도 red-team에 전부 우회됐고(간접화+decoy·meta-arg·주석 카운트 회피·identity redirect·cross-file),
# canonical freeze조차 모듈 컨텍스트로 우회됐다(리소스를 /* */로 감싸 terraform에서 사라지게 하기; 추적된
# *_override.tf로 count=0/enforcement disable 병합). 완전 검증은 terraform plan(GitHub API+백엔드 자격)이
# 필요한데, 신뢰 앵커 보안 모델이 그 자격을 CI에서 의도적으로 배제한다 → 원리적으로 불가.
#
# 그래서 이 가드는 **best-effort 변경 감지기**다(완전 의미 검증기 아님). 알려진 클래스를 3층으로 잡는다:
#   (1) canonical freeze — 보안 핵심 **1블록(resource ruleset — actor_id=4043080 리터럴 핀)**을
#       추출→주석제거→공백정규화한 뒤 핀된 canonical과 정확일치. 블록 밖 decoy 무관, 블록 안 어떤
#       간접화·meta-arg·추가 actor·**actor_id 값 변경**도 canonical을 바꿔 잡힘. (2026-07-23: App ID를
#       slug data source 대신 직접 핀 — fine-grained PAT가 GET /apps/{slug} 404. data source·writer_app_slug
#       변수가 사라져 관련 identity 우회 클래스도 소멸, actor_id 리터럴 리다이렉트 witness로 대체.)
#   (2) no-block-comments — rulesets.tf에서 문자열을 blank한 뒤 남는 /* 또는 */(진짜 블록주석)를 금지 →
#       리소스를 주석으로 감싸 없애는 wrap을 잡음. (bump-poll/**의 /* 는 문자열 내부라 무해.)
#   (3) no-override — infra/github에 추적된 terraform override 파일(*_override.tf[.json], override.tf[.json])
#       0을 단언 → 바이트 동일한 가드 파일 뒤에 병합돼 리소스를 재정의/비활성화하는 우회를 잡음.
# 그래도 남는 것(removed 블록·resolved plan·apply-time tfvars·provider/owner)은 CI에서 검증 불가 —
# **권위·필수 검증은 owner-local Seam C**(apply + 적대 라이브 테스트)이며, HCL 구조와 무관하게 *실제 룰셋*을
# 관측하므로 이 정적 가드가 못 잡는 모든 약화를 잡는다. (spec Testing Decisions 참조.)
#
# canonical 재생성(블록을 의도적으로 바꿨을 때): canonical_blocks를 실제 파일에 돌린 출력으로 CANONICAL을
# 교체한다. 그 변경 자체가 리뷰 대상이다.
# deletion 규칙은 이번 increment canonical에 없다(spec R-2 — 후속이 정리경로와 함께 추가).
# @test 이름은 영어(디렉토리 단위 실행 시 한글 인코딩 깨짐 — AGENTS.md). bash 3.2 호환([[ ]] 미사용).

ROOT="$BATS_TEST_DIRNAME/../.."
TF="$ROOT/infra/github/rulesets.tf"

# (1) 보안 1블록(ruleset resource)의 정규형: header~(컬럼0 }) 추출 → 주석(#, //, 인라인 /* */) 제거 → 공백 정규화.
# 인라인 /* */ 는 s:/\*[^*]*\*/: 로 제거(내부에 * 없을 때) — bump-poll/** 의 /** 는 매치 안 됨(문자열 안전).
extract_block() { sed -n "/$2/,/^}/p" "$1"; }
canonical_blocks() {
  extract_block "$1" '^resource "github_repository_ruleset" "bump_poll_writer_only" {' \
    | sed -E 's://.*$::; s:#.*$::; s:/\*[^*]*\*/::g' | tr '\n' ' ' | tr -s '[:space:]' ' ' | sed -E 's/^ //; s/ $//'
}

# (2) 문자열("...")을 blank + 라인주석 제거 후 남는 블록주석(/* 또는 */) 금지 → 주석 wrap 차단.
no_block_comments() {
  b=$(sed -E 's/"[^"]*"/""/g; s://.*$::; s:#.*$::' "$1")
  case "$b" in *"/*"*|*"*/"*) return 1;; *) return 0;; esac
}

# (3) terraform override 파일 경로 판정(override.tf · override.tf.json · *_override.tf · *_override.tf.json).
is_override_path() { printf '%s' "$1" | grep -Eq '(^|/)([^/]*_)?override\.tf(\.json)?$'; }

# 핀된 canonical(신뢰 앵커의 리뷰된 형태). 위 재생성 절차로만 갱신한다.
CANONICAL='resource "github_repository_ruleset" "bump_poll_writer_only" { name = "bump-poll-writer-only" repository = github_repository.homelab.name target = "branch" enforcement = "active" conditions { ref_name { include = ["refs/heads/bump-poll/**"] exclude = [] } } rules { creation = true update = true } bypass_actors { actor_id = 4043080 actor_type = "Integration" bypass_mode = "always" } }'

@test "security block matches the pinned canonical form" {
  got="$(canonical_blocks "$TF")"
  [ "$got" = "$CANONICAL" ] || { echo "canonical 불일치 — 실제:"; echo "$got"; false; }
}

@test "no block comment wraps the security region (rulesets.tf)" {
  run no_block_comments "$TF"
  [ "$status" -eq 0 ]
}

@test "no tracked terraform override file exists in infra/github" {
  matches="$(git -C "$ROOT" ls-files infra/github | grep -E '(^|/)([^/]*_)?override\.tf(\.json)?$' || true)"
  [ -z "$matches" ]
}

# ── 뮤테이션 증인 — red-team이 각 가드 계층을 뚫으려던 클래스가 잡힘을 증명(사본만 변형) ──────────

@test "witness: indirection — target=var.tgt + decoy locals is caught" {
  c="$(mktemp)"; sed -E 's/^([[:space:]]*target[[:space:]]*=[[:space:]]*)"branch"/\1var.tgt/' "$TF" > "$c"
  printf '\nlocals { target = "branch" }\n' >> "$c"
  [ "$(canonical_blocks "$c")" != "$CANONICAL" ]; rm -f "$c"
}

@test "witness: case-evasion — enforcement=lower(\"DISABLED\") + decoy is caught" {
  c="$(mktemp)"; sed -E 's/^([[:space:]]*enforcement[[:space:]]*=[[:space:]]*)"active"/\1lower("DISABLED")/' "$TF" > "$c"
  printf '\nlocals { enforcement = "active" }\n' >> "$c"
  [ "$(canonical_blocks "$c")" != "$CANONICAL" ]; rm -f "$c"
}

@test "witness: meta-arg — for_each={} disabling the resource is caught" {
  c="$(mktemp)"; sed -E 's/^(resource "github_repository_ruleset" "bump_poll_writer_only" \{)/\1\n  for_each = {}/' "$TF" > "$c"
  [ "$(canonical_blocks "$c")" != "$CANONICAL" ]; rm -f "$c"
}

@test "witness: meta-arg — count=0 disabling the resource is caught" {
  c="$(mktemp)"; sed -E 's/^(resource "github_repository_ruleset" "bump_poll_writer_only" \{)/\1\n  count = 0/' "$TF" > "$c"
  [ "$(canonical_blocks "$c")" != "$CANONICAL" ]; rm -f "$c"
}

@test "witness: comment-prefixed second bypass actor is caught" {
  c="$(mktemp)"
  awk '/^}/ && !d { print "  bypass_actors {"; print "    actor_id    = 99999"; print "    actor_type  = \"Integration\""; print "    bypass_mode = \"always\""; print "  }"; d=1 } {print}' "$TF" > "$c"
  [ "$(canonical_blocks "$c")" != "$CANONICAL" ]; rm -f "$c"
}

@test "witness: identity redirect — actor_id changed to an attacker App ID + decoy is caught" {
  # slug data source가 사라진 뒤의 identity-pin 방어: bypass actor_id(4043080=writer App)를 다른 App ID로
  # 바꾸면 룰셋이 엉뚱한 App을 bypass시킨다(승인 우회). decoy locals가 있어도 canonical이 바뀌어 잡힌다.
  c="$(mktemp)"; sed -E 's/^([[:space:]]*actor_id[[:space:]]*=[[:space:]]*)4043080/\199999/' "$TF" > "$c"
  printf '\nlocals { actor_id = 4043080 }\n' >> "$c"
  [ "$(canonical_blocks "$c")" != "$CANONICAL" ]; rm -f "$c"
}

@test "witness: indirection — actor_id=tonumber(var.x) + decoy var is caught" {
  # 리터럴을 다시 간접화(변수/함수)로 빼돌리는 우회 — 값이 리졸브돼 같아 보여도 canonical(리터럴 4043080)이
  # 아니므로 잡힌다. slug data source 시절의 cross-file redirect를 대체하는 in-block 간접화 witness다.
  c="$(mktemp)"; sed -E 's/^([[:space:]]*actor_id[[:space:]]*=[[:space:]]*)4043080/\1tonumber(var.aid)/' "$TF" > "$c"
  printf '\nvariable "aid" { type = string\n  default = "4043080" }\n' >> "$c"
  [ "$(canonical_blocks "$c")" != "$CANONICAL" ]; rm -f "$c"
}

@test "witness: decoy-locals include redirect to a dead namespace is caught" {
  c="$(mktemp)"; sed -E 's#^([[:space:]]*include[[:space:]]*=[[:space:]]*)\["refs/heads/bump-poll/\*\*"\]#\1["refs/heads/__dead__/**"]#' "$TF" > "$c"
  printf '\nlocals { include = ["refs/heads/bump-poll/**"] }\n' >> "$c"
  [ "$(canonical_blocks "$c")" != "$CANONICAL" ]; rm -f "$c"
}

@test "witness: decoy-locals exclude carve-out of the namespace is caught" {
  c="$(mktemp)"; sed -E 's#^([[:space:]]*exclude[[:space:]]*=[[:space:]]*)\[\]#\1["refs/heads/bump-poll/**"]#' "$TF" > "$c"
  printf '\nlocals { exclude = [] }\n' >> "$c"
  [ "$(canonical_blocks "$c")" != "$CANONICAL" ]; rm -f "$c"
}

@test "witness: an enclosing multiline comment wrapping the resource is caught" {
  c="$(mktemp)"
  awk '/^resource "github_repository_ruleset" "bump_poll_writer_only" \{/ && !o { print "/*"; o=1 } {print} /^}/ && o==1 && !k { print "*/"; k=1 }' "$TF" > "$c"
  run no_block_comments "$c"
  rm -f "$c"
  [ "$status" -ne 0 ]
}

@test "witness: override-file detection flags override files, not the security files" {
  run is_override_path "infra/github/override.tf"; [ "$status" -eq 0 ]
  run is_override_path "infra/github/override.tf.json"; [ "$status" -eq 0 ]
  run is_override_path "infra/github/bump_override.tf"; [ "$status" -eq 0 ]
  run is_override_path "infra/github/foo_override.tf.json"; [ "$status" -eq 0 ]
  run is_override_path "infra/github/rulesets.tf"; [ "$status" -ne 0 ]
  run is_override_path "infra/github/variables.tf"; [ "$status" -ne 0 ]
}

@test "control: a harmless comment change does not trip the canonical or block-comment guard" {
  c="$(mktemp)"; sed -E 's/# bypass = writer App 하나.*/# 주석만 변경/' "$TF" > "$c"
  [ "$(canonical_blocks "$c")" = "$CANONICAL" ]
  run no_block_comments "$c"; [ "$status" -eq 0 ]
  rm -f "$c"
}
