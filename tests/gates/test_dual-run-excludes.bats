#!/usr/bin/env bats
# 병행 운용(라이브 Mac + NUC) 한시 divergence의 **발견 가능성**을 강제한다.
#
# ⚠️ 이 가드가 지키는 것은 "제외가 옳다"가 아니라 **"컷오버에서 무엇을 되돌려야 하는지 한 번의
#    grep으로 전부 찾을 수 있다"**이다. 한시 divergence가 마커 없이 늘어나면 컷오버 때 빠뜨린다.
#    `git grep dual-run` = 되돌릴 목록 전부.
#
# ⚠️ serverName(`check-pg-servername.sh`)처럼 main 진입을 막는 가드를 두지 **않은** 이유:
#    이 divergence를 안 되돌리고 컷오버하면 NUC에 공개 인입이 없어 **사이트가 즉시 죽는다** —
#    시끄럽고 1커밋으로 되돌아온다. serverName은 반대로 **조용하고 되돌릴 수 없어서** 가드를 뒀다.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "cloudflared is excluded from the platform appset while dual-running" {
  # 같은 터널 토큰 → 두 번째 커넥터 → 공개 요청이 비결정적으로 갈린다 → 두 DB로 세션 발산(되돌릴 수 없다).
  run yq -e '[.spec.generators[0].git.directories[] | select(.exclude == true) | .path] | contains(["platform/cloudflared/*"])' platform/argocd/root/appset.yaml
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qxF -- 'true'
}

@test "page and trip-mate-api are NOT excluded (they must be Healthy for G4)" {
  # cnpg를 제외가 아니라 serverName으로 분리했으므로 NUC에도 DB가 있다. 공개 인입이 없으니 유휴로
  # 뜨고, G4("전 Application Healthy")는 그것들이 떠 있어야 증명된다.
  ex="$(yq -e '[.spec.generators[0].git.directories[] | select(.exclude == true) | .path] | join(",")' platform/argocd/root/appset.yaml)"
  ! printf '%s' "$ex" | grep -qF -- 'apps/'
}

@test "the deadmanswitch relay is disabled while dual-running (it would green-wash the live check)" {
  # 두 클러스터가 같은 healthchecks URL을 ping하면 라이브 Mac이 죽어도 체크가 초록으로 남는다.
  run grep -nE '^[[:space:]]*- deadmanswitch-relay\.yaml' platform/victoria-stack/prod/kustomization.yaml
  [ "$status" -ne 0 ]
  grep -q 'deadmanswitch-relay.yaml' platform/victoria-stack/prod/kustomization.yaml   # 주석으로 남아 있어야 컷오버에 되살린다
}

@test "every dual-run divergence carries the marker, and the revert set is exactly these files" {
  # ⚠️ 이 @test가 이 파일의 존재 이유다. 마커 없는 한시 divergence가 생기면 컷오버에서 빠뜨린다.
  #    목록이 늘거나 줄면 red — 늘었다면 마커를 달고 여기에 추가하고, 줄었다면 컷오버가 진행 중이다.
  got="$(git grep -l -- 'dual-run' | LC_ALL=C sort | tr '\n' ' ')"
  want="platform/argocd/root/appset.yaml platform/victoria-stack/prod/kustomization.yaml tests/gates/test_dual-run-excludes.bats "
  printf '%s' "$got" | grep -qxF -- "$want"
}
