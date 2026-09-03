#!/usr/bin/env bats
# 콜드스타트 sync-wave 순서 가드 (2026-08-13 NUC 첫 bootstrap에서 실측한 교착).
#
# ⚠️ **이 순서가 뒤집히면 콜드스타트가 완전히 교착된다.** barman-cloud 플러그인은 Cluster가
#    참조하는 ObjectStore가 없으면 "barman object configuration not found"로 무한 requeue하고,
#    그 pre-reconcile hook이 reconciliation을 멈춘다 → Cluster가 영원히 Healthy가 아니다 →
#    ArgoCD는 그 wave에서 대기하므로 **뒤 wave의 ObjectStore는 영원히 apply되지 않는다**.
# ⚠️ 라이브 Mac에서는 드러나지 않는다 — 점진 구축이라 ObjectStore 추가 시 Cluster가 이미 떠 있었다.
#    즉 이 가드는 **아무도 매일 밟지 않는 경로**(G11 콜드스타트)를 지킨다.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"; D="$ROOT/platform/cnpg/prod"; }

wave_of() { # $1=파일 — sync-wave 값(없으면 ArgoCD 기본값 0)
  w="$(LC_ALL=C sed -n 's/^ *argocd\.argoproj\.io\/sync-wave: *"\{0,1\}\(-\{0,1\}[0-9][0-9]*\)"\{0,1\}.*/\1/p' "$1" | head -1)"
  [ -n "$w" ] || w=0
  printf '%s' "$w"
}

@test "ObjectStore applies before the Cluster that references it (cold-start deadlock guard)" {
  os="$(wave_of "$D/object-store.yaml")"
  cl="$(wave_of "$D/cluster.yaml")"
  [ "$os" -lt "$cl" ] || { echo "ObjectStore wave=$os · Cluster wave=$cl — ObjectStore가 더 앞이어야 한다"; false; }
}

@test "the credential generator lands no later than the ObjectStore that consumes it" {
  # ⚠️ 이름 정정: 여기서 `wave_of`가 집는 kustomization의 **첫** sync-wave는 :40의
  #    `generatorOptions.annotations`(= configMapGenerator 전용 wave)다. KSOPS `generators:`
  #    산출물에는 generatorOptions가 적용되지 않으므로(:42-52 주석) 그 축은 이 @test가 아니라
  #    아래 "every KSOPS seed Secret …"이 진다.
  gen="$(wave_of "$D/kustomization.yaml")"
  os="$(wave_of "$D/object-store.yaml")"
  # 같은 wave는 허용된다 — ArgoCD는 같은 wave 안에서 Secret을 CRD 인스턴스보다 먼저 적용한다.
  [ "$gen" -le "$os" ] || { echo "generator wave=$gen · ObjectStore wave=$os — 자격 Secret이 더 늦으면 안 된다"; false; }
}

@test "the ObjectStore actually declares a wave (an absent one silently means 0)" {
  # 값이 없으면 기본 0이라 Cluster(-1)보다 뒤가 된다 — 그 침묵이 이 사고의 원인이었다.
  run grep -qE '^ *argocd\.argoproj\.io/sync-wave:' "$D/object-store.yaml"
  [ "$status" -eq 0 ]
}

@test "every KSOPS seed Secret carries an explicit wave patch ahead of the Cluster" {
  # ⚠️ 2026-08-13 교착을 **실제로 고치는 것**은 kustomization의 `patches:` 4건이다 —
  #    `generatorOptions`는 내장 generator(configMapGenerator) 전용이라 `generators:`(KSOPS exec
  #    plugin) 산출물엔 적용되지 않는다(kustomization.yaml:42-52의 자기 주석). 그 4건을 통째로
  #    지워도 이 파일이 3/3 초록이었다(실측) — wave_of가 집는 건 :40의 generatorOptions뿐이다.
  #    유일한 증인이던 test_kustomize_build.bats:55-72는 tests/.ci-exclude(owner-local
  #    `make verify-ksops`, 게다가 age 키 부재 시 SKIP)라 required gate 밖이다.
  # ⚠️ 이름 하드코딩만으로는 **시드 추가 시 patch 누락**을 못 잡으므로 로스터 등식을 함께 건다.
  k="$D/kustomization.yaml"
  cl="$(wave_of "$D/cluster.yaml")"
  n="$(yq -e '[.patches[] | select(.target.kind=="Secret")] | length' "$k")"
  s="$(yq -e '.files | length' "$D/secret-generator.yaml")"
  [ "$n" -gt 0 ]      # 바닥값 — 열거 붕괴 차단(0건은 '위반 없음'이 아니라 '못 쟀다')
  [ "$n" -eq "$s" ]   # 시드 로스터 == patch 로스터
  for name in cnpg-r2-creds pg-app-credentials pg-admin-credentials restore-drill-alerting; do
    w="$(yq -e ".patches[] | select(.target.name==\"$name\") | .patch" "$k" | LC_ALL=C sed -n 's/.*sync-wave: *"\{0,1\}\(-\{0,1\}[0-9][0-9]*\)".*/\1/p' | head -1)"
    [ -n "$w" ] || { echo "$name: wave patch 없음"; false; }
    [ "$w" -lt "$cl" ] || { echo "$name wave=$w >= Cluster wave=$cl — 자격 Secret이 더 앞이어야 한다"; false; }
  done
}
