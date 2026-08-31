#!/usr/bin/env bats
# create-github-app-token 핀 SSOT — 모든 인라인 @<sha>가 단일 canonical 40-hex SHA로 일치하는가.
# 핀이 갈라지면 일부 콜사이트가 변조/취약 버전을 쓸 수 있다(공급망). mutable @vN 태그도 거부.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과.

# ⚠️ 열거 도메인 존재를 setup에서 확인한다 — 실측: `.github`를 통째로 옮기면 **3 @test 전부**가
# baseline과 동일한 초록이었다(rc=0). 디렉토리 실재는 그 절반뿐이다: 트리가 **남은 채 비면**
# `grep -r … ; [ "$status" -eq 1 ]`이 다시 무증인 초록이 된다(빈 디렉토리 grep -r은 rc **1** —
# 무매치와 값이 같다). 그래서 비공허까지 여기서 잰다. 나머지 절반인 양성 대조는 각 @test가
# **같은 피연산자(.github/)** 로 세운다. 글롭이 `.yaml`인 것은 레포 규약이다(워크플로는 전부
# `.yaml` — AGENTS.md 네이밍 규약). cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」③-a
# 뮤테이션 실측(2026-08-31, 격리 트리): `.github`를 **디렉토리만 남기고 비우면** 착지 전 형태는
# 아래 두 @test가 green(vacuous)이었고 지금은 red다. 두 증인은 각각 단독으로도 하중을 진다 —
# 바닥값만 남겨도, 양성 대조만 남겨도 같은 뮤테이션에서 red였다.
setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1
  [ -d .github ]
  [ -n "$(find .github -name '*.yaml' -print -quit)" ]
}

# canonical 핀 — 갱신 시 이 한 줄만 바꾸고 전 콜사이트를 같은 값으로 sed 한다.
CANON="bcd2ba49218906704ab6c1aa796996da409d3eb1"

@test "every create-github-app-token pin equals the canonical SHA" {
  # 열거를 한 번만 받아 세 판정이 공유한다. 커맨드 치환은 grep rc=2(디렉토리 부재)와 stderr를
  # 둘 다 삼키므로 바닥값 없이는 "14건 전건 일치"와 "0건 검사"가 같은 초록이다.
  refs=$(grep -rhoE 'actions/create-github-app-token@[0-9a-zA-Z.]+' .github/ || true)
  n=$(printf '%s\n' "$refs" | grep -c . || true)
  [ "$n" -ge 8 ]     # 현재 14건 — 콜사이트 6개 축소를 견딘다. 래칫 아님
  # 등장하는 모든 @<ref>를 모아 canonical과 다른 게 하나라도 있으면 fail
  bad=$(printf '%s\n' "$refs" | sed -E 's#.*@##' | LC_ALL=C sort -u | grep -v "^${CANON}\$" || true)
  [ -z "$bad" ]
}

@test "no create-github-app-token uses a mutable tag" {
  # 양성 대조 — 부재 판정과 **같은 피연산자**가 실제 워크플로 트리인가(`on:`은 이 트리에서
  # 사라질 리 없다). 트리가 비면 rc 1이라 여기서 먼저 red다.
  run grep -rlE '^on:' .github/
  [ "$status" -eq 0 ]
  # ⚠️ `-ne 0`이면 grep rc=**2**(디렉토리 부재)도 통과한다 — "mutable 태그 0건"과 "검사 대상 0건"이
  # 같은 초록이 되는 부정-카운트 함정. 매치 없음은 정확히 rc=1이다.
  run grep -rE 'actions/create-github-app-token@v[0-9]' .github/
  [ "$status" -eq 1 ]
}

@test "the dead homelab-token composite is removed (zero callers)" {
  # uses: ./.github/actions/homelab-token 호출자가 없으므로 composite 자체를 제거했다.
  [ ! -f .github/actions/homelab-token/action.yml ]
  # 양성 대조 — 같은 피연산자(.github/)가 비지 않았다. 트리 자체가 사라진 경우는 아래 부재
  # 판정이 rc 2로 잡고(`-eq 1`), 트리가 남은 채 비어 버린 경우를 이 줄이 rc 1로 잡는다.
  run grep -rlE '^on:' .github/
  [ "$status" -eq 0 ]
  run grep -rF 'uses: ./.github/actions/homelab-token' .github/
  [ "$status" -eq 1 ]
}
