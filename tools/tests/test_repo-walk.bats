#!/usr/bin/env bats
# 저장소 스캔 워커(tools/lib/repo-walk.ts) 단위 — 스코프별 열거·제외 어휘·열거 붕괴 바닥값.
# 가드 15개가 9가지 방식으로 트리를 걷던 것을 한 곳으로 모으는 커널이라, 이 파일이 후속 호출자들의
# 열거 정확성을 대신 증명한다.
#
# ⚠️ **픽스처 트리로 검증한다**(실 레포 단언이 아니라). 실 레포로 제외를 단언하면 죽은 가드가 된다 —
# 추적된 platform/**/tests/·fixtures*/ 경로가 전부 platform/charts/app/ 아래라 charts/ 규칙에 이미
# 걸린다. 즉 그 두 규칙을 삭제해도 실-레포 단언은 초록이다. 픽스처는 그것들을 charts/ **밖**에 두어
# 규칙 하나하나를 load-bearing으로 만든다.
#
# 단언 규율: 중간 단언은 `run …; [ "$status" … ]` / `[ … ]`(단일 대괄호)로만(check-bats-style 강제).
# ⚠️ @test 이름은 영어만(bats dir-run 인코딩 함정).
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; }

# 워커를 bun -e로 로드해 $1(JS 본문)을 실행하고 stdout을 반환. $2 = repo root(기본 실 레포).
walk() { bun -e "
  import { walkManifests, listUnits, SCOPE_NAMES } from '$ROOT/tools/lib/repo-walk.ts';
  const ROOT = '${2:-$ROOT}';
  $1
"; }

# 제외 규칙마다 정확히 하나씩 대응하는 픽스처 트리를 만들고 경로를 echo 한다.
# untracked.yaml은 일부러 git add 하지 않는다(tracked 열거 증명용).
_fixture() {
  local t; t="$(mktemp -d)"
  mkdir -p "$t/platform/comp/prod/charts" "$t/platform/comp/prod/tests" \
           "$t/platform/comp/prod/fixtures-bad" "$t/platform/cnpg/barman-plugin" \
           "$t/platform/argocd/root/apps" "$t/platform/traefik/prod"
  echo 'kind: Deployment' > "$t/platform/comp/prod/deploy.yaml"          # 포함
  echo 'kind: ConfigMap'  > "$t/platform/comp/prod/config.yml"           # 포함(.yml)
  echo 'kind: Application'> "$t/platform/argocd/root/apps/cnpg-barman-plugin.yaml" # 포함(부분문자열 아님)
  echo 'kind: Deployment' > "$t/platform/comp/prod/charts/vendored.yaml" # 제외 charts/
  echo 'kind: Secret'     > "$t/platform/cnpg/barman-plugin/manifest.yaml" # 제외 barman-plugin/
  echo 'kind: Deployment' > "$t/platform/comp/prod/tests/fixture.yaml"   # 제외 tests/ (charts/ 밖)
  echo 'kind: Deployment' > "$t/platform/comp/prod/fixtures-bad/x.yaml"  # 제외 fixtures*/ (charts/ 밖)
  echo 'kind: CustomResourceDefinition' > "$t/platform/traefik/prod/gateway-api-crds.yaml" # 제외
  echo 'not yaml'         > "$t/platform/comp/prod/notes.txt"            # 제외(include 정규식)
  mkdir -p "$t/apps/probe/deploy/prod"
  echo 'image: {}'        > "$t/apps/probe/deploy/prod/values.yaml"      # apps-values 대상
  echo 'x: 1'             > "$t/apps/probe/deploy/prod/kustomization.yaml" # 제외(values.yaml 아님)
  git -C "$t" init -q; git -C "$t" add -A
  echo 'kind: Deployment' > "$t/platform/comp/prod/untracked.yaml"       # 제외(추적 안 됨)
  echo "$t"
}

@test "platform-manifests includes tracked YAML and excludes every vocabulary rule independently" {
  tmp="$(_fixture)"
  run walk 'console.log(walkManifests("platform-manifests", ROOT).map(e => e.path).join(","))' "$tmp"
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
  [ "$output" == "platform/argocd/root/apps/cnpg-barman-plugin.yaml,platform/comp/prod/config.yml,platform/comp/prod/deploy.yaml" ]
}

# 회귀 가드: 구 check-resource-limits는 `p.includes("barman-plugin")`으로 **부분 문자열** 제외를 했다.
# 그 필터는 벤더 디렉토리뿐 아니라 이름에 그 문자열이 들어간 정상 파일(ArgoCD Application
# cnpg-barman-plugin.yaml)까지 과잉 제외한다. 스코프는 **경로 세그먼트** 매치를 써야 한다.
@test "barman-plugin is excluded as a path segment and not as a substring" {
  tmp="$(_fixture)"
  run walk 'const p = walkManifests("platform-manifests", ROOT).map(e => e.path);
    console.log([
      p.includes("platform/argocd/root/apps/cnpg-barman-plugin.yaml"),
      p.includes("platform/cnpg/barman-plugin/manifest.yaml"),
    ].join(","))' "$tmp"
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
  [ "$output" == "true,false" ]
}

# tracked(git ls-files) 열거 — gitignored helm 캐시(platform/*/prod/charts/)가 자동으로 빠진다.
# 이 지식은 지금까지 scripts/check-image-pins.sh:96 주석에만 있었다.
@test "platform-manifests enumerates tracked files and skips untracked ones" {
  tmp="$(_fixture)"
  run walk 'const p = walkManifests("platform-manifests", ROOT).map(e => e.path);
    console.log(p.includes("platform/comp/prod/untracked.yaml"))' "$tmp"
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
  [ "$output" == "false" ]
}

# 바닥값은 **열거 붕괴**(스코프가 아무것도 못 잡음)만 본다. 레포 규모 단언이 아니다 —
# 실 레포 크기에 맞춘 상수를 박으면 모든 픽스처 트리가 깨진다(구현 중 실제로 겪은 회귀).
@test "enumeration floor fails loudly when the scope matches nothing" {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/platform"
  echo 'not yaml' > "$tmp/platform/notes.txt"
  git -C "$tmp" init -q; git -C "$tmp" add -A
  run walk 'try { walkManifests("platform-manifests", ROOT); console.log("NO_THROW"); }
    catch (e) { console.log("THREW:" + (e instanceof Error && e.message.includes("platform-manifests"))); }' "$tmp"
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
  [ "$output" == "THREW:true" ]
}

@test "docs parse lazily and yield the manifest kind" {
  tmp="$(_fixture)"
  run walk 'const e = walkManifests("platform-manifests", ROOT)
      .find(x => x.path === "platform/comp/prod/deploy.yaml");
    console.log([e.text.includes("kind: Deployment"), e.docs[0].toJS().kind].join(","))' "$tmp"
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
  [ "$output" == "true,Deployment" ]
}

@test "an unknown scope name is rejected rather than silently returning nothing" {
  run walk 'try { walkManifests("no-such-scope", ROOT); console.log("NO_THROW"); }
    catch (e) { console.log("THREW"); }'
  [ "$status" -eq 0 ]
  [ "$output" == "THREW" ]
}

# listUnits는 진입점으로 존재하되 유닛 스코프는 티켓 04에서 등록된다. 지금 호출하면 미등록 스코프로
# 거부돼야 한다 — 조용히 빈 배열을 주면 소비자가 vacuous하게 통과한다.
@test "listUnits rejects scopes that are not registered yet" {
  run walk 'try { listUnits("apps", ROOT); console.log("NO_THROW"); }
    catch (e) { console.log("THREW"); }'
  [ "$status" -eq 0 ]
  [ "$output" == "THREW" ]
}

@test "SCOPE_NAMES exposes the registered scopes" {
  run walk 'console.log(SCOPE_NAMES.slice().sort().join(","))'
  [ "$status" -eq 0 ]
  [ "$output" == "apps-values,platform-image-refs,platform-manifests" ]
}

# `platform-manifests`와 `platform-image-refs`는 **다른 질문**에 답한다.
#   manifests = "이 파일이 배포되는 매니페스트인가" → 차트 소스 제외. 템플릿은 렌더 전이라
#     `{{ }}` 때문에 YAML 파싱이 깨진다(실측: 공유 차트 deployment.yaml에 파싱 에러 509건).
#   image-refs = "이 파일이 이미지 참조를 담을 수 있는가" → **추적된 차트 소스 포함**.
#     check-image-pins는 공급망 가드다 — 조용히 좁히면 D-2 클래스(차트 내부 이미지 무소유)를 키운다.
@test "platform-image-refs keeps tracked chart sources that platform-manifests drops" {
  tmp="$(_fixture)"
  run walk 'const m = walkManifests("platform-manifests", ROOT).map(e => e.path);
    const i = walkManifests("platform-image-refs", ROOT).map(e => e.path);
    console.log([
      m.includes("platform/comp/prod/charts/vendored.yaml"),
      i.includes("platform/comp/prod/charts/vendored.yaml"),
    ].join(","))' "$tmp"
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
  [ "$output" == "false,true" ]
}

# image-refs도 벤더·픽스처 제외는 공유한다 — 차트 규칙 하나만 다르다.
@test "platform-image-refs still excludes vendor and fixture paths" {
  tmp="$(_fixture)"
  run walk 'const p = walkManifests("platform-image-refs", ROOT).map(e => e.path);
    console.log([
      p.includes("platform/cnpg/barman-plugin/manifest.yaml"),
      p.includes("platform/comp/prod/tests/fixture.yaml"),
      p.includes("platform/comp/prod/fixtures-bad/x.yaml"),
      p.includes("platform/traefik/prod/gateway-api-crds.yaml"),
    ].join(","))' "$tmp"
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
  [ "$output" == "false,false,false,false" ]
}

@test "apps-values enumerates only tracked app deploy values files" {
  tmp="$(_fixture)"
  run walk 'console.log(walkManifests("apps-values", ROOT).map(e => e.path).join(","))' "$tmp"
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
  [ "$output" == "apps/probe/deploy/prod/values.yaml" ]
}

# ── CLI 진입점: 셸 가드가 열거만 받아 쓰는 경로 ──
# 셸 가드는 TS로 이관하지 않는다(CONTRIBUTING이 grep/yq 필터를 셸 영역으로 규정). 대신 열거·제외·
# 바닥값만 워커에서 받고 추출 로직은 셸이 유지한다 → 제외 어휘의 사본이 원리적으로 없어진다.
@test "CLI emits newline-delimited paths for a manifests scope" {
  tmp="$(_fixture)"
  run bun "$ROOT/tools/lib/repo-walk.ts" --manifests apps-values --root "$tmp"
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
  [ "$output" == "apps/probe/deploy/prod/values.yaml" ]
}

@test "CLI rejects an unknown flag with the usage exit code" {
  run bun "$ROOT/tools/lib/repo-walk.ts" --nope x
  [ "$status" -eq 2 ]
}

@test "CLI rejects an unknown scope with the usage exit code" {
  run bun "$ROOT/tools/lib/repo-walk.ts" --manifests no-such-scope
  [ "$status" -eq 2 ]
}

@test "CLI fails loudly when enumeration collapses" {
  tmp="$(mktemp -d)"; mkdir -p "$tmp/platform"; git -C "$tmp" init -q
  run bun "$ROOT/tools/lib/repo-walk.ts" --manifests platform-manifests --root "$tmp"
  rm -rf "$tmp"
  [ "$status" -eq 1 ]
}

# 실 레포 스모크 — 픽스처가 증명하지 못하는 것 하나: 스코프가 실제 트리에서 붕괴하지 않는다.
@test "platform-manifests does not collapse against the real repository" {
  run walk 'console.log(walkManifests("platform-manifests", ROOT).length > 0)'
  [ "$status" -eq 0 ]
  [ "$output" == "true" ]
}
