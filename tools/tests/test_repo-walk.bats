#!/usr/bin/env bats
# 저장소 스캔 워커(tools/lib/repo-walk.ts) 단위 — 스코프별 열거·제외 어휘·유닛 파생.
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
  mkdir -p "$t/apps/probe/deploy/prod" "$t/apps/naked/deploy/prod"
  echo 'image: {}'        > "$t/apps/probe/deploy/prod/values.yaml"      # apps-values 대상
  echo 'x: 1'             > "$t/apps/probe/deploy/prod/kustomization.yaml" # 제외(values.yaml 아님)
  echo 'kind: NetworkPolicy' > "$t/apps/probe/deploy/prod/netpol.yaml"   # apps-manifests 대상
  # values.yaml **없는** 앱 — R-1 회귀 가드: 유닛 열거가 필수 산출물로 거르면 안 된다.
  echo '{}'               > "$t/apps/naked/deploy/prod/.bindings.json"
  echo 'readme'           > "$t/apps/README.md"                          # 유닛 아님(디렉토리 미형성)
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

# 바닥값(scan-floor)은 워커에 두지 않는다 — 열거자는 "글롭이 깨져 0건"과 "정당하게 0건"을 구별할
# 도메인 지식이 없다. 비어 있으면 **조용히 빈 배열**을 주고, 그게 고장인지는 소비자가 판단한다
# (소비자들은 이미 MIN_SCAN을 갖고 있고 그건 의미론적 필터 이후를 세므로 더 정확하다).
@test "an empty scope yields an empty list rather than a spurious failure" {
  tmp="$(mktemp -d)"; mkdir -p "$tmp/platform"; git -C "$tmp" init -q
  run walk 'console.log(walkManifests("platform-manifests", ROOT).length)' "$tmp"
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
  [ "$output" == "0" ]
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

@test "listUnits rejects a manifests scope passed to the units entrypoint" {
  run walk 'try { listUnits("apps-values", ROOT); console.log("NO_THROW"); }
    catch (e) { console.log("THREW"); }'
  [ "$status" -eq 0 ]
  [ "$output" == "THREW" ]
}

# ⚠️ R-1 회귀 가드(design-r1 R-1의 핵심). 유닛 열거는 **필수 산출물로 거르면 안 된다** —
# audit-orphans에겐 values.yaml 필터가 맞지만 check-app-deploy는 그 파일의 **부재**를 잡아야 한다.
# 열거자가 미리 거르면 위반이 검사 대상에서 사라져 배포를 깨뜨리는 false green이 된다.
@test "apps units include an app that is missing its required artifacts" {
  tmp="$(_fixture)"
  run walk 'console.log(listUnits("apps", ROOT).map(u => u.name + "@" + u.dir).join(","))' "$tmp"
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
  [ "$output" == "naked@apps/naked,probe@apps/probe" ]
}

# 유닛 파생은 **디렉토리 패턴 매치를 강제**한다. apps/README.md처럼 유닛 디렉토리를 형성하지 않는
# 추적 파일이 유닛으로 새어 나오면 안 된다(차이 리포트가 잡은 실제 파생 버그).
@test "unit derivation drops tracked paths that form no unit directory" {
  tmp="$(_fixture)"
  run walk 'console.log(listUnits("apps", ROOT).some(u => u.dir.includes("README")))' "$tmp"
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
  [ "$output" == "false" ]
}

@test "platform units exclude the shared chart directory" {
  tmp="$(_fixture)"
  run walk 'const u = listUnits("platform", ROOT).map(x => x.name);
    console.log([u.includes("comp"), u.includes("charts")].join(","))' "$tmp"
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
  [ "$output" == "true,false" ]
}

@test "apps-manifests enumerates tracked YAML under apps" {
  tmp="$(_fixture)"
  run walk 'console.log(walkManifests("apps-manifests", ROOT).map(e => e.path).sort().join(","))' "$tmp"
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
  [ "$output" == "apps/probe/deploy/prod/kustomization.yaml,apps/probe/deploy/prod/netpol.yaml,apps/probe/deploy/prod/values.yaml" ]
}

@test "CLI emits unit directories for a units scope" {
  tmp="$(_fixture)"
  run bun "$ROOT/tools/lib/repo-walk.ts" --units apps --root "$tmp"
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
  [ "$output" == "apps/naked
apps/probe" ]
}

@test "SCOPE_NAMES exposes the registered scopes" {
  run walk 'console.log(SCOPE_NAMES.slice().sort().join(","))'
  [ "$status" -eq 0 ]
  [ "$output" == "apps,apps-manifests,apps-values,guards,platform,platform-image-refs,platform-manifests,producers,rules" ]
}

# `guards` 스코프는 "이 레포에서 무엇이 불변식을 강제한다고 주장하는가"에 답한다(G1 권위 회계의 열거 대상).
# ⚠️ 공용 TEST_HARNESS 제외 어휘를 쓰면 안 된다 — 그 어휘의 `tests?/`가 `tests/gates/*.sh`를 통째로 지운다.
# 그 8개(ci.yaml이 직접 부르는 e2e 하네스)가 정확히 지금까지 회계 커버리지 0이던 대상이라,
# 지워지면 이 스코프가 존재 이유를 잃는다.
@test "guards includes the ci-invoked e2e harnesses under tests/gates" {
  run walk 'console.log(walkManifests("guards").map(e=>e.path).filter(p=>p.startsWith("tests/gates/")).length)'
  [ "$status" -eq 0 ]
  [ "$output" -ge 8 ]
}

# 하네스가 source하는 프리미티브는 진입점이 아니다 — 세면 "권위 경로 0"이 영원히 참인 항목이 생긴다.
# 이 성질은 명시 제외가 아니라 include의 `[^/]+`(하위 디렉토리를 못 넘는다)가 준다 — 명시 제외를
# 뒀다가 mutation이 초록이라 죽은 규칙임을 실측하고 지웠다. 단언은 메커니즘과 무관하게 성질을 지킨다.
# 역방향 — 규약 접두를 가진 추적 파일은 **반드시** 열거돼야 한다. 정방향만 두면 include가 좁아져도
# "규약 밖 파일 0건"은 계속 참이라 통과한다(실측: tools 쪽이 check-만 받아 verify-db-marker.ts가 빠져 있었다).
@test "guards enumerates every tracked file that follows the naming convention" {
  run walk 'const got=new Set(walkManifests("guards").map(e=>e.path)); const {execFileSync}=require("node:child_process"); const want=execFileSync("git",["ls-files"],{encoding:"utf8"}).split("\n").filter(p=>/^(scripts\/(check|verify)-[^/]+\.sh|tools\/(check|verify)-[^/]+\.ts|tests\/gates\/[^/]+\.sh)$/.test(p)); console.log(want.filter(p=>!got.has(p)).join(","))'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "guards excludes tests/gates/lib primitives that are sourced, not entrypoints" {
  run walk 'console.log(walkManifests("guards").map(e=>e.path).filter(p=>p.includes("/gates/lib/")).join(","))'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "guards enumerates the three declared families and nothing else" {
  run walk 'console.log(walkManifests("guards").map(e=>e.path).filter(p=>!/^(scripts\/(check|verify)-|tools\/(check|verify)-|tests\/gates\/)/.test(p)).join(","))'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
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

@test "CLI emits nothing and succeeds for an empty scope" {
  tmp="$(mktemp -d)"; mkdir -p "$tmp/platform"; git -C "$tmp" init -q
  run bun "$ROOT/tools/lib/repo-walk.ts" --manifests platform-manifests --root "$tmp"
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
  [ "$output" == "" ]
}

# 실 레포 스모크 — 픽스처가 증명하지 못하는 것 하나: 스코프가 실제 트리에서 붕괴하지 않는다.
@test "platform-manifests does not collapse against the real repository" {
  run walk 'console.log(walkManifests("platform-manifests", ROOT).length > 0)'
  [ "$status" -eq 0 ]
  [ "$output" == "true" ]
}

# ── 티켓 05: rules / producers 스코프 ──
# 별도 픽스처를 쓴다 — 위 _fixture에 rules 디렉토리를 넣으면 platform-manifests의 정확-일치 단언이
# 깨져 두 관심사가 결합된다.
_fixture_repo() {
  local t; t="$(mktemp -d)"
  mkdir -p "$t/platform/victoria-stack/prod/rules" "$t/platform/charts/app" \
           "$t/scripts" "$t/tools/tests" "$t/tests/gates" "$t/docs"
  echo 'groups: []'   > "$t/platform/victoria-stack/prod/rules/r1.yaml"
  echo 'groups: []'   > "$t/platform/victoria-stack/prod/rules/r2.yaml"
  echo 'notes'        > "$t/platform/victoria-stack/prod/rules/README.md"   # 룰 아님(확장자)
  echo 'echo push'    > "$t/scripts/push.sh"                                # producer 대상(.sh)
  echo 'x'            > "$t/docs/gen.py"                                    # producer 대상(.py)
  echo 'y'            > "$t/tools/tests/test_x.ts"                          # 제외 tests/
  echo 'z'            > "$t/tests/gates/e2e.sh"                             # 제외 tests/
  echo 'w'            > "$t/platform/charts/app/values.yaml"                # 제외 charts/
  echo 'v'            > "$t/scripts/test_helper.sh"                         # 제외 test_* 파일명
  echo 'u'            > "$t/scripts/thing.bats"                             # 제외 *.bats
  # ⚠️ platform **안쪽** 하네스 — platform 스코프의 root가 platform이라 밖에만 두면 그 스코프에
  # 대해 아무것도 증명하지 못한다(리뷰가 잡은 vacuous 테스트의 원인).
  echo 't'            > "$t/platform/victoria-stack/prod/test_probe.yaml"   # 제외 test_* 파일명
  mkdir -p "$t/platform/victoria-stack/prod/tests"
  echo 's'            > "$t/platform/victoria-stack/prod/tests/f.yaml"      # 제외 tests/
  echo 'readme'       > "$t/docs/x.md"                                      # 제외(확장자)
  git -C "$t" init -q; git -C "$t" add -A
  echo "$t"
}

@test "rules scope enumerates only the alert rule manifests" {
  tmp="$(_fixture_repo)"
  run walk 'console.log(walkManifests("rules", ROOT).map(e => e.path).join(","))' "$tmp"
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
  [ "$output" == "platform/victoria-stack/prod/rules/r1.yaml,platform/victoria-stack/prod/rules/r2.yaml" ]
}

# producers는 레포 전역이고 확장자가 넓다(.sh/.ts/.py 등). tracked 열거를 쓰므로 .git·node_modules·
# .terraform·dist는 **자동으로** 빠진다 — 구 SKIP_DIRS 6개 중 4개가 이렇게 사라진다(추적 파일 0건 실측).
# 남는 charts/·tests/만 명시 규칙으로 둔다.
@test "producers scope spans the repo and drops harness, charts and non-producer extensions" {
  tmp="$(_fixture_repo)"
  run walk 'console.log(walkManifests("producers", ROOT).map(e => e.path).sort().join(","))' "$tmp"
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
  [ "$output" == "docs/gen.py,platform/victoria-stack/prod/rules/r1.yaml,platform/victoria-stack/prod/rules/r2.yaml,scripts/push.sh" ]
}

# ⚠️ 룰 디렉토리와 린터 자신의 제외는 **소비자 몫**이다(의미론적 필터). 룰 디렉토리는 이 린터의
# *검사 대상*(소비자 표면)이지 "레포에 존재하지 않는 파일"이 아니다 — 스코프가 걸러버리면 다른
# 소비자가 그 파일을 볼 수 없게 된다(design-r1 R-1과 같은 함정).
@test "producers scope does not apply the linter's own semantic exemptions" {
  tmp="$(_fixture_repo)"
  run walk 'const p = walkManifests("producers", ROOT).map(e => e.path);
    console.log(p.some(x => x.includes("/rules/")))' "$tmp"
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
  [ "$output" == "true" ]
}

# 공유 어휘: 테스트 하네스 제외(tests?/ · fixtures*/ · test_* 파일 · *.bats)는 platform 스코프들과
# producers가 **같은 개념**을 쓴다. charts/·벤더 규칙은 스코프마다 다르므로 공유하지 않는다.
@test "platform scopes keep the shared test-harness vocabulary" {
  tmp="$(_fixture_repo)"
  run walk 'const p = walkManifests("platform-image-refs", ROOT).map(e => e.path);
    console.log([
      p.includes("platform/victoria-stack/prod/test_probe.yaml"),
      p.includes("platform/victoria-stack/prod/tests/f.yaml"),
      p.includes("platform/charts/app/values.yaml"),
    ].join(","))' "$tmp"
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
  # 하네스 둘은 빠지고(공유 어휘), 차트는 남는다(이 스코프만의 규칙) — 두 축을 한 번에 고정한다.
  [ "$output" == "false,false,true" ]
}
