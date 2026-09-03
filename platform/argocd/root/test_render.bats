#!/usr/bin/env bats
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"; F="$ROOT/platform/argocd/root/appset.yaml"; }

@test "appset.yaml is valid yaml" {
  run yq e 'true' "$F"
  [ "$status" -eq 0 ]
}
@test "appset.yaml has exactly two ApplicationSets" {
  run bash -c "grep -c '^kind: ApplicationSet' '$F'"
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}
@test "appset generator discovery paths are locked (both generators)" {
  # ⚠️ 발견 경로 한 줄이 **어떤 플랫폼 컴포넌트가 존재하는지**를 혼자 결정한다. 좁히거나 오타를 내면
  #    제너레이터가 더 이상 내지 않는 Application을 ApplicationSet 컨트롤러가 삭제하고, 템플릿의
  #    resources-finalizer(:42-43)가 그 워크로드를 **cascade prune**한다 — traefik(Gateway API CRD)·
  #    network-policies·cloudflared·adguard·tailscale 등 11개가 한 커밋으로 사라진다.
  # ⚠️ 착지 전 이 축의 증인은 레포 전체에 0건이었다. 여기 있던 판정은 `grep -c`의 **건수를 비교조차
  #    하지 않고**(rc만 봤다) apps 경로 하나만 봤다. tests/gates/ 아래에서 이 appset을 읽는 형제
  #    가드는 `select(.exclude == true)` — **exclude 집합**만 잠그므로 발견 경로는 도메인 밖이다.
  #    ⚠️ 그 파일의 경로는 여기 적지 않는다 — 경로 문자열 자체가 그 파일의 마커 원장 리터럴이라,
  #       이름을 부르는 순간 「마커는 이 파일 밖 어디에도 없다」 @test가 red가 된다(실측으로 밟았다).
  # ⚠️ `yq ea`(eval-all)여야 한다 — appset.yaml은 문서가 둘이라 `yq`(eval)는 비매치 문서가 빈 결과를
  #    보태 출력이 두 줄이 된다(같은 형제 가드가 주석에 남긴 실측 함정).
  # ⚠️ `select(.exclude != true)`는 키 부재(null)를 포함한다. `yq -e`는 쓰지 않는다(값 false→exit 1).
  for p in 'platform-components=platform/*/prod' 'apps=apps/*/deploy/prod'; do
    n="${p%%=*}"; want="${p#*=}"
    run yq ea "select(.metadata.name==\"$n\") | [.spec.generators[0].git.directories[] | select(.exclude != true) | .path] | join(\",\")" "$F"
    [ "$status" -eq 0 ]
    printf '%s' "$output" | grep -qxF -- "$want" || { echo "$n path=$output want=$want"; false; }
  done
}

@test "both ApplicationSet templates carry a retry policy (cold-start CRD ordering has no other backstop)" {
  # ⚠️ appset이 만드는 Application끼리는 sync-wave 관계가 아예 없다(ApplicationSet 컨트롤러가 직접
  #    만들어 root app-of-apps의 sync 대상이 아니다). 그래서 Gateway API CRD를 소유한 traefik-prod보다
  #    소비자(HTTPRoute)가 먼저 도달할 수 있고, dry-run이 `resource mapping not found`로 죽으면
  #    그 Application의 리소스가 하나도 apply되지 않는다. auto-sync는 같은 revision의 실패를
  #    재시도하지 않고 selfHeal은 성공 이후에만 걸리므로 retry가 유일한 자가복구 경로다.
  #    (2026-08-14 NUC 콜드스타트 실측: 5개 앱이 이 상태로 Missing에 고착했다.)
  for n in platform-components apps; do
    run yq "select(.kind==\"ApplicationSet\" and .metadata.name==\"$n\") | .spec.template.spec.syncPolicy.retry.limit" "$F"
    [ "$status" -eq 0 ]
    printf '%s' "$output" | grep -qxF -- '5' || { echo "$n: retry.limit=$output (기대 5)"; false; }
    run yq "select(.kind==\"ApplicationSet\" and .metadata.name==\"$n\") | .spec.template.spec.syncPolicy.retry.backoff.duration" "$F"
    printf '%s' "$output" | grep -qxF -- '15s' || { echo "$n: retry.backoff.duration=$output (기대 15s)"; false; }
    run yq "select(.kind==\"ApplicationSet\" and .metadata.name==\"$n\") | .spec.template.spec.syncPolicy.retry.backoff.maxDuration" "$F"
    printf '%s' "$output" | grep -qxF -- '5m' || { echo "$n: retry.backoff.maxDuration=$output (기대 5m)"; false; }
  done
}

@test "telegram-notify subscription label is wired on apps appset, platform templatePatch, and cnpg-data" {
  has() { printf '%s' "$1" | grep -qF -- "$2" || { echo "miss: $2"; false; }; }
  C="$ROOT/platform/argocd/root/apps/cnpg-data.yaml"
  # apps appset: 모든 앱에 정적 라벨
  run yq 'select(.kind=="ApplicationSet" and .metadata.name=="apps") | .spec.template.metadata.labels."notify.homelab/telegram"' "$F"
  [ "$output" = "true" ] || { echo "apps label=$output"; false; }
  # cnpg-data 수동 Application: 정적 라벨(appset exclude라 직접)
  run yq '.metadata.labels."notify.homelab/telegram"' "$C"
  [ "$output" = "true" ] || { echo "cnpg-data label=$output"; false; }
  # platform-components: data-conn/cache만 templatePatch 조건부(missingkey=error 안전 — inline .X 금지)
  run yq 'select(.kind=="ApplicationSet" and .metadata.name=="platform-components") | .spec.templatePatch' "$F"
  has "$output" 'data-conn'; has "$output" 'cache'; has "$output" 'files'; has "$output" 'notify.homelab/telegram'
}
