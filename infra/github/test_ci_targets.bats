#!/usr/bin/env bats
# drift-github의 `-target` 목록 ↔ 실제 리소스 집합 정합.
#
# 왜 -target인가(2026-08-19 실측): GitHub은 repo의 merge 설정(allow_squash_merge·allow_auto_merge·
# delete_branch_on_merge…)을 **Administration:write 토큰에게만** 응답에 싣는다. CI가 쓰는 읽기 전용
# PAT에는 그 필드가 **null로 빠지고**, terraform provider가 부재를 `false`로 읽어 `false -> true`
# **영구 허위 드리프트**를 만든다. 같은 시점에 owner R&W 토큰은 "No changes"였다 — 즉 드리프트가
# 아니라 **읽기 실패가 드리프트로 위장한 것**이다. 403이면 시끄럽게 죽었을 텐데 조용한 오답이라 더 나쁘다.
# write를 주는 우회는 금지다: 이 감시가 지키는 대상이 branch protection·ruleset인데, 그걸 다시 쓸 수
# 있는 자격을 CI에 놓는 것이 된다(tf-reconcile.yaml이 명시한 보안 모델 위반).
# ⇒ 읽히는 것만 감시하고, github_repository 두 건이 감시 밖이라는 사실을 원장이 계상한다.
#
# @test 이름은 영어. 중간 부정 단언은 run + [ ]로만(bash 3.2에서 중간 `!`는 조용히 통과한다).
#
# ⚠️ 이 파일의 부정 단언 두 개는 `-eq 1` **전환 대상이 아니다** — 마지막 grep이 경로가 아니라
#    파이프 stdin을 읽어서 대상이 사라져도 rc 2가 아니라 무매치 rc 1이 온다(cf. docs/traps-detail.md
#    「열거 붕괴 → vacuous green」③-b). 그래서 SSOT의 다른 처방을 쓴다: 아래 setup의 **비공허 바닥값**
#    + 각 @test의 **양성 대조**를 한 쌍으로 건다. 2026-08-29 격리 트리 실측 — infra/github를 리네임하면
#    이 파일 4개 중 그 두 개가 초록으로 남았다(감시 사각 가드와 -target 전제 가드가 통째로 공허했다).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1
  WF=".github/workflows/tf-reconcile.yaml"
  TFDIR="infra/github"
  # 비공허 바닥값 — 두 열거 도메인(tf 루트·워크플로)이 실재해야 아래 대조가 뜻을 갖는다.
  [ -d "$TFDIR" ]
  [ -f "$WF" ]
  # 선언된 리소스 전건: `resource "TYPE" "NAME"` → TYPE.NAME
  ALL="$(cat "$TFDIR"/*.tf | sed -nE 's/^resource[[:space:]]+"([^"]+)"[[:space:]]+"([^"]+)".*/\1.\2/p' | LC_ALL=C sort -u)"
  # 감시 대상 = repository 리소스를 뺀 나머지(위 주석의 이유로 repository는 읽기 전용 plan 불가)
  WANT="$(printf '%s\n' "$ALL" | grep -v '^github_repository\.' || true)"
  # 워크플로가 실제로 지정한 것
  GOT="$(sed -nE 's/.*-target=([A-Za-z0-9_.]+).*/\1/p' "$WF" | LC_ALL=C sort -u)"
  # 파싱이 통째로 깨져 양쪽이 함께 비면 모든 대조가 공허해진다 — @test 단위가 아니라 여기서 막아야
  # 개별 실행에서도 닫힌다.
  [ -n "$ALL" ]
  [ -n "$GOT" ]
}

@test "the tf root declares resources at all (enumeration floor — a broken parse must not read as agreement)" {
  # 🔴 열거가 깨져 양쪽이 함께 비면 아래 대조가 공허하게 통과한다. 바닥값으로 그걸 막는다.
  n="$(printf '%s\n' "$ALL" | grep -c . || true)"
  [ "$n" -ge 6 ]
}

@test "the drift-github -target list covers EVERY non-repository resource (no silent blind spot)" {
  # 리소스를 더하고 워크플로에 -target을 안 더하면 그 리소스는 조용히 무감시가 된다.
  [ -n "$WANT" ]
  [ -n "$GOT" ]
  run bash -c "diff <(printf '%s\n' \"$WANT\") <(printf '%s\n' \"$GOT\")"
  [ "$status" -eq 0 ]
}

@test "github_repository resources are NOT targeted (they would reintroduce the false drift)" {
  # 읽기 전용 PAT로는 merge 설정을 못 읽어 영구 드리프트가 된다 — 목록에 들어오면 즉시 문다.
  # 양성 대조 — 같은 피연산자·같은 앵커 술어가 매치한다(-target 목록이 리소스 주소를 담고 있다).
  run bash -c "printf '%s\n' \"$GOT\" | grep -q '^github_'"
  [ "$status" -eq 0 ]
  run bash -c "printf '%s\n' \"$GOT\" | grep -q '^github_repository\\.'"
  [ "$status" -ne 0 ]
}

@test "no monitored resource references the github_repository RESOURCE (that dependency defeats -target)" {
  # ⚠️ 이게 -target이 성립하는 전제다. `-target`은 **의존성을 함께 끌어온다** — 감시 대상이
  #    `github_repository.homelab.name`이나 `.node_id`를 참조하면 repository 리소스가 plan에 딸려
  #    들어와 허위 드리프트가 그대로 돌아온다(2026-08-19에 실제로 밟았다: -target을 걸었는데도
  #    `# github_repository.homelab will be updated in-place`가 나왔다).
  #    대신 `var.repo_name`과 `data.github_repository.homelab`을 쓴다 — data는 diff를 내지 않는다.
  #    `data.` 접두는 리소스 참조가 아니므로 제외하고 센다.
  # 양성 대조 — 같은 피연산자에서 **허용된** 형태(data. 접두)는 실제로 매치해야 한다. 이게 없으면
  # tf 루트가 사라지거나 참조가 var.*로 전부 갈아엎여도 아래 부정 단언이 그냥 통과한다.
  run bash -c "cat '$TFDIR'/*.tf | grep -oE 'data\\.github_repository\\.[a-z_]+\\.' | grep -q ."
  [ "$status" -eq 0 ]
  run bash -c "cat '$TFDIR'/*.tf | grep -oE '(^|[^.[:alnum:]_])github_repository\\.[a-z_]+\\.' | grep -q ."
  [ "$status" -ne 0 ]
}
