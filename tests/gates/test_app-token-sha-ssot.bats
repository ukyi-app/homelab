#!/usr/bin/env bats
# create-github-app-token 핀 SSOT — 모든 인라인 @<sha>가 단일 canonical 40-hex SHA로 일치하는가.
# 핀이 갈라지면 일부 콜사이트가 변조/취약 버전을 쓸 수 있다(공급망). mutable @vN 태그도 거부.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과.

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

# canonical 핀 — 갱신 시 이 한 줄만 바꾸고 전 콜사이트를 같은 값으로 sed 한다.
CANON="bcd2ba49218906704ab6c1aa796996da409d3eb1"

@test "every create-github-app-token pin equals the canonical SHA" {
  # 등장하는 모든 @<ref>를 모아 canonical과 다른 게 하나라도 있으면 fail
  bad=$(grep -rhoE 'actions/create-github-app-token@[0-9a-zA-Z.]+' .github/ \
        | sed -E 's#.*@##' | sort -u | grep -v "^${CANON}\$" || true)
  [ -z "$bad" ]
}

@test "no create-github-app-token uses a mutable tag" {
  run grep -rE 'actions/create-github-app-token@v[0-9]' .github/
  [ "$status" -ne 0 ]
}

@test "the dead homelab-token composite is removed (zero callers)" {
  # uses: ./.github/actions/homelab-token 호출자가 없으므로 composite 자체를 제거했다.
  [ ! -f .github/actions/homelab-token/action.yml ]
  run grep -rF 'uses: ./.github/actions/homelab-token' .github/
  [ "$status" -ne 0 ]
}
