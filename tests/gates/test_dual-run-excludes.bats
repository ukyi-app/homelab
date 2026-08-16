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

@test "cloudflared is NO LONGER excluded (cutover 2026-08-17 — the competing connector is gone)" {
  # 제외의 근거는 "같은 터널 토큰의 두 번째 커넥터"였다. 라이브 Mac 클러스터가 사라져 경쟁 커넥터가
  # 원리적으로 없으므로 제외를 걷었다. 이 @test는 방향을 뒤집어 **되살아나면 red**로 만든다 —
  # 제외가 되돌아왔다는 건 누군가 두 번째 클러스터를 세웠다는 뜻이고, 그때는 이 파일도 함께 봐야 한다.
  # ⚠️ appset.yaml은 **문서가 둘**이다(platform-components · apps). `yq`(eval)는 문서마다 결과를
  #    내므로 `select`로 걸러도 **비매치 문서가 빈 결과를 보태** 출력이 두 줄이 되고 정수 비교가
  #    `integer expression expected`로 깨진다(이번에 두 번 밟았다). **`yq ea`(eval-all)**로
  #    스트림 전체를 한 번에 다뤄야 단일 값이 나온다.
  q='select(.kind == "ApplicationSet" and .metadata.name == "platform-components") | [.spec.generators[0].git.directories[] | select(.exclude == true) | .path]'
  run yq ea "$q | contains([\"platform/cloudflared/*\"])" platform/argocd/root/appset.yaml
  printf '%s' "$output" | grep -qxF -- 'false'
  # 양성 대조 — 제외 목록 자체는 살아 있다(열거가 깨진 것을 'false'로 오독하지 않는다).
  # ⚠️ 바닥값(`-ge N`)으로는 부족하다: 6→5로 하나가 사라져도 통과한다(뮤테이션으로 확인).
  #    **정확한 집합**으로 잠근다 — 제외를 더하거나 빼면 red가 나고, 그때 이 줄을 의식적으로 고친다.
  run yq ea "$q | sort | join(\",\")" platform/argocd/root/appset.yaml
  printf '%s' "$output" | grep -qxF -- 'platform/argocd/*,platform/charts/*,platform/cnpg/*,platform/namespaces/*,platform/sealed-secrets/*,platform/victoria-stack/*'
}

@test "no apps/ path is excluded from the platform appset (app exclusion is never the dual-run lever)" {
  # ⚠️ 인-레포 배포 앱은 현재 **0개**다(#455 page · #456 trip-mate-api 철거) — 지킬 앱 Application이
  #    없으니 이 단언은 지금 당장은 공허하다. 그래도 남긴다: 앱을 다시 온보딩했을 때 "병행 운용 중이니
  #    앱을 빼두자"가 재발하는 것을 막는 자리이기 때문이다. 분리는 cloudflared(공개 인입)와
  #    serverName(아카이브)으로 하지, 앱 Application을 지우는 방식으로 하지 않는다.
  ex="$(yq -e '[.spec.generators[0].git.directories[] | select(.exclude == true) | .path] | join(",")' platform/argocd/root/appset.yaml)"
  ! printf '%s' "$ex" | grep -qF -- 'apps/'
}

@test "the deadmanswitch relay is disabled while dual-running (it would green-wash the live check)" {
  # 두 클러스터가 같은 healthchecks URL을 ping하면 라이브 Mac이 죽어도 체크가 초록으로 남는다.
  run grep -nE '^[[:space:]]*- deadmanswitch-relay\.yaml' platform/victoria-stack/prod/kustomization.yaml
  [ "$status" -ne 0 ]
  grep -q 'deadmanswitch-relay.yaml' platform/victoria-stack/prod/kustomization.yaml   # 주석으로 남아 있어야 컷오버에 되살린다
}

@test "the restore drill is suspended while dual-running (same green-wash as the relay)" {
  # drill은 PASS 시 HEALTHCHECKS_URL을 ping하고, 그 시드는 main과 바이트 동일이다 —
  # 두 클러스터가 같은 체크를 ping하면 **라이브 Mac의 drill이 안 돌아도 초록으로 남는다.**
  # ⚠️ 아카이브 원본은 문제가 아니다(drill이 라이브 Cluster의 serverName에서 파생 — NUC은 pg-nuc).
  #    막는 것은 ping 하나뿐이고, 그래서 삭제가 아니라 **suspend**다: 수동 실행(G5)은 계속 된다.
  s="$(yq '.spec.suspend' platform/cnpg/prod/restore-drill-cronjob.yaml)"
  printf '%s' "$s" | grep -qxF -- 'true'
  # 마커가 그 줄에 붙어 있어야 아래 되돌림 집합 @test가 이 파일을 잡는다.
  run grep -nE '^[[:space:]]*suspend:[[:space:]]*true[[:space:]]*#[[:space:]]*dual-run' platform/cnpg/prod/restore-drill-cronjob.yaml
  [ "$status" -eq 0 ]
  # 양성 대조 — CronJob이 실재하고 스케줄을 여전히 들고 있다(컷오버에 되살릴 대상).
  run grep -qE '^[[:space:]]*schedule:' platform/cnpg/prod/restore-drill-cronjob.yaml
  [ "$status" -eq 0 ]
}

@test "every dual-run divergence carries the marker, and the revert set is exactly these files" {
  # ⚠️ 이 @test가 이 파일의 존재 이유다. 마커 없는 한시 divergence가 생기면 컷오버에서 빠뜨린다.
  #    목록이 늘거나 줄면 red — 늘었다면 마커를 달고 여기에 추가하고, 줄었다면 컷오버가 진행 중이다.
  got="$(git grep -l -- 'dual-run' | LC_ALL=C sort | tr '\n' ' ')"
  want="platform/cnpg/prod/restore-drill-cronjob.yaml platform/victoria-stack/prod/kustomization.yaml tests/gates/test_dual-run-excludes.bats "
  printf '%s' "$got" | grep -qxF -- "$want"
}
