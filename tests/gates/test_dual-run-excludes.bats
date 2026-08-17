#!/usr/bin/env bats
# 컷오버(2026-08-17)로 **닫힌** 병행 운용 divergence의 재발을 잡는다.
#
# ⚠️ **이 파일은 목적이 한 번 바뀌었다.** 원래는 "되돌릴 목록의 원장"이었다 —
#    `git grep dual-run` = 되돌릴 파일 전부. 라이브 Mac 클러스터가 사라져 divergence 3건
#    (cloudflared 제외 · relay 비활성 · drill 정지)이 전부 걷혔으므로, 이제는 **방향이 뒤집힌
#    드리프트 가드**다: divergence가 되살아나면 red다.
#
# ⚠️ 셋은 근거 하나를 공유한다 — "두 번째 클러스터가 **같은 외부 자원**(터널 토큰 · healthchecks
#    체크)을 비결정적으로/거짓 초록으로 오염시킨다." 그래서 하나가 되살아나면 셋을 **함께** 봐야 한다.
#    즉 red는 "이 줄을 고쳐라"가 아니라 "이 파일 전체를 다시 읽어라"라는 신호다.
#
# ⚠️ 마지막 @test는 마커 원장을 **닫는** 자리다: 마커 문자열이 이 파일 밖 어디에도 없어야 한다.
#    새 한시 divergence가 생기면 마커를 달고 그 @test를 의식적으로 고쳐라 — 그게 컷오버에서
#    빠뜨리지 않는 유일한 장치다(원장을 지우면 그 장치가 사라진다).
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

@test "the deadmanswitch relay is wired back in (cutover 2026-08-17 — the competing pinger is gone)" {
  # 비활성의 근거는 "두 클러스터가 같은 healthchecks 체크를 ping하면 라이브 Mac이 죽어도 초록으로
  # 남는다"였다. 라이브 Mac 클러스터가 사라져 경쟁 pinger가 원리적으로 없으므로 되살렸다.
  # 이 @test는 방향을 뒤집어 **다시 빠지면 red**로 만든다 — relay가 빠지면 Watchdog → AM webhook →
  # healthchecks.io 체인이 통째로 침묵하고, 그 침묵은 조용하다(오프노드 스위치는 ping **부재**를
  # 페이징하므로 레포 안에는 증거가 없다).
  # ⚠️ 반드시 `yq`로 **파싱된** resources를 본다. 원문 grep은 (a) 주석 줄과 (b) 들여쓰기가 어긋나
  #    시퀀스의 원소가 아닌 줄을 통과시킨다 — 되살릴 때 실제로 밟는 두 가지다(이 항목은 0칸
  #    주석으로 누워 있었고 다른 항목은 전부 2칸이다).
  # ⚠️ 양성 대조를 **함께** 요구한다. relay 하나만 물으면 `resources`에서 나머지 20여 항목을
  #    전부 지워도 통과한다 — `#476`이 "바닥값으로는 부족했다(6→5 붕괴가 통과)"고 실측한 그 형태다.
  #    다만 `resources`는 정당하게 늘어나는 목록이라 **정확한 집합 고정은 곧 드리프트**한다.
  #    그래서 중간 형태를 쓴다: 붕괴하면 반드시 함께 사라질 앵커 2개를 같이 묻는다.
  run yq '.resources | contains(["namespace.yaml","alertmanager.yaml","deadmanswitch-relay.yaml"])' platform/victoria-stack/prod/kustomization.yaml
  printf '%s' "$output" | grep -qxF -- 'true'
  # 참조 대상이 실재한다(kustomize build를 깨는 dangling 참조를 초록으로 넘기지 않는다).
  [ -f platform/victoria-stack/prod/deadmanswitch-relay.yaml ]
}

@test "the restore drill runs on schedule again (cutover 2026-08-17 — the competing drill is gone)" {
  # 정지의 근거는 "PASS 시 HEALTHCHECKS_URL ping이 라이브 Mac의 체크를 green-wash한다"였다.
  # 라이브 Mac 클러스터가 사라져 경쟁 drill이 원리적으로 없으므로 재개했다. 이 @test는 방향을
  # 뒤집어 **다시 정지되면 red**로 만든다 — suspend는 조용하다: CronJob 오브젝트는 그대로 Healthy로
  # 남고, CNPGRestoreDrillStale은 마지막 성공으로부터 8.1일이 지나야 뜬다.
  # ⚠️ 'false' **정확 일치**다. 필드를 지워도(기본값 false라 동작은 같다) yq가 'null'을 내 red다 —
  #    선언이 사라지는 것 자체가 "이 drill은 돈다"는 진술의 소실이라 통과시키지 않는다.
  s="$(yq '.spec.suspend' platform/cnpg/prod/restore-drill-cronjob.yaml)"
  printf '%s' "$s" | grep -qxF -- 'false'
  # 양성 대조 — CronJob이 실재하고 **주간** 스케줄을 그대로 들고 있다(재개의 대상 그 자체).
  # ⚠️ 바닥값(`schedule:` 존재)으로는 부족하다: 스케줄이 통째로 바뀌어도 통과한다. 값을 잠근다.
  run grep -nE '^[[:space:]]*schedule:[[:space:]]*"0 5 \* \* 0"' platform/cnpg/prod/restore-drill-cronjob.yaml
  [ "$status" -eq 0 ]
}

@test "the marker ledger is closed — no file but this one still carries it" {
  # ⚠️ 이 @test가 이 파일의 존재 이유다. 컷오버 전에는 "되돌릴 목록"이었고, 컷오버 후에는
  #    **"목록이 비었다"**를 잠근다. 마커가 이 파일 밖에 다시 나타나면 red — 새 한시 divergence가
  #    생겼다는 뜻이고, 그때 마커를 달고 여기 want에 추가한 뒤 위 @test들의 방향도 함께 재검토한다.
  # ⚠️ 이 파일 자신이 마커를 들고 있다는 사실이 **양성 대조를 겸한다** — git grep이 깨져 0건이 되면
  #    got이 빈 문자열이 되어 여기서 red다(빈 결과를 '깨끗하다'로 오독하는 vacuous green을 닫는다).
  # ⚠️ 매니페스트 축약 주석은 마커 리터럴도, **이 파일의 경로도** 부르지 않는다 —
  #    경로 자체에 마커 문자열이 들어 있어 이름을 부르는 순간 그 파일이 다시 잡힌다.
  got="$(git grep -l -- 'dual-run' | LC_ALL=C sort | tr '\n' ' ')"
  want="tests/gates/test_dual-run-excludes.bats "
  printf '%s' "$got" | grep -qxF -- "$want"
}
