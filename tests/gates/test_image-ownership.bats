#!/usr/bin/env bats
# G2 이미지 소유권 회계(tools/check-image-ownership.ts + policy/image-ownership.json)의 gate 테스트.
#
# 병: `check-image-pins.sh`는 "digest로 핀됐는가"만 본다. **누가 그 digest를 갱신하는가**는 아무도
# 안 봤다. 실측(2026-07-28): `pg-tools:18-rclone`이 두 digest로 갈렸는데 핀 게이트는 둘 다 통과시켰고
# (핀의 존재만 보고 일치는 안 본다), 벤더 manifest의 사이드카 이미지는 base64로 Secret 안에 있어
# 핀 게이트·Renovate·grep 어디에도 안 걸린 채 커버리지가 정확히 0이었다.
#
# ⚠️ 실 레포 단언은 최소로 둔다(가드 통과 + 스캔 건수 + 근사의 센티넬). 나머지는 픽스처 mutation이다 —
#    실 레포로 계약을 박으면 원장이 바뀔 때마다 테스트가 깨지고 mutation이 아무것도 증명하지 못한다.
# ⚠️ @test 이름은 영어만 · 중간 단언은 [ ]만(bash 3.2 [[ ]] 침묵 통과).

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; }

GUARD() { bun "$ROOT/tools/check-image-ownership.ts" "$@"; }

# 소유자 4클래스가 각각 최소 하나씩 등장하는 픽스처 레포.
_fixture() {
  local t="$BATS_TEST_TMPDIR/${1:-fx}"
  mkdir -p "$t/platform/comp/prod" "$t/platform/vendor" "$t/apps/demo/deploy/prod" "$t/platform/files/prod"
  cp "$ROOT/renovate.json" "$t/renovate.json"
  echo 'image: registry.example.com/thing:v1@sha256:1111111111111111111111111111111111111111111111111111111111111111' > "$t/platform/comp/prod/deploy.yaml"
  echo 'image: ghcr.io/ukyi-app/pg-tools:18-rclone@sha256:2222222222222222222222222222222222222222222222222222222222222222' > "$t/platform/comp/prod/job.yaml"
  printf 'image:\n  repo: ghcr.io/ukyi-app/demo\n  tag: sha-abc\n  digest: sha256:3333333333333333333333333333333333333333333333333333333333333333\n' > "$t/apps/demo/deploy/prod/values.yaml"
  echo 'image: ghcr.io/ukyi-app/files:sha-x@sha256:4444444444444444444444444444444444444444444444444444444444444444' > "$t/platform/files/prod/deployment.yaml"
  printf '{"file":"deployment.yaml","path":["a"],"autoDeploy":true}\n' > "$t/platform/files/prod/.image-pin.json"
  printf '{\n  "unowned": []\n}\n' > "$t/policy/image-ownership.json" 2>/dev/null || { mkdir -p "$t/policy"; printf '{\n  "unowned": []\n}\n' > "$t/policy/image-ownership.json"; }
  git -C "$t" init -q
  git -C "$t" add -A
  echo "$t"
}

_ledger() { python3 -c "
import json,sys
p=sys.argv[1]
d=json.load(open(p,encoding='utf-8'))
exec(sys.argv[2])
json.dump(d,open(p,'w',encoding='utf-8'),ensure_ascii=False,indent=2)
" "$1/policy/image-ownership.json" "$2"; }

FIXTURE_ARGS="--min-refs 1"

# ── 실 레포 (최소 단언) ───────────────────────────────────────────────────────

@test "the guard passes on the real tree and reaches its domain" {
  run GUARD --repo-root "$ROOT"
  [ "$status" -eq 0 ]
  # 스캔 건수를 함께 단언한다 — 열거가 무너져 0건이어도 '위반 0'과 같은 초록이기 때문.
  echo "$output" | grep -qE '^SCAN: check-image-ownership:refs: [0-9]{2,}$'
}

@test "the Renovate reachability approximation still classifies known match and non-match paths" {
  # 도달성은 **근사**다(실제 Renovate dry-run이 아니다). 근사가 조용히 무너지면 무소유가 소유로
  # 뒤집혀 stale-pin이 초록이 된다 — 알려진 양쪽 샘플을 센티넬로 박아 그 붕괴를 감지한다.
  run bun -e '
    import { loadRenovate, renovateReaches } from "'"$ROOT"'/tools/check-image-ownership.ts";
    const r = loadRenovate("'"$ROOT"'");
    const yes = ["platform/victoria-stack/prod/vmagent.yaml", "apps/page/deploy/prod/values.yaml",
                 "platform/argocd/root/apps/cnpg-operator.yaml", "platform/traefik/prod/helmrelease.yaml"];
    const no  = ["platform/cnpg/barman-plugin/manifest.yaml", "platform/traefik/prod/charts/traefik/values.yaml",
                 "tools/templates/x.yaml", "docs/plans/x.yaml"];
    const bad = [...yes.filter((p) => !renovateReaches(p, r)).map((p) => "MISS " + p),
                 ...no.filter((p) => renovateReaches(p, r)).map((p) => "FALSE " + p)];
    console.log(bad.join(",") || "ok");
  '
  [ "$status" -eq 0 ]
  [ "$output" == "ok" ]
}

# ── 픽스처: 소유자 4클래스 ────────────────────────────────────────────────────

@test "a clean fixture resolves an owner for every reference" {
  t="$(_fixture clean)"
  run GUARD --repo-root "$t" $FIXTURE_ARGS
  [ "$status" -eq 0 ]
}

@test "each owner class is actually populated (a class with zero members is not proof, it is blindness)" {
  t="$(_fixture classes)"
  run bun "$ROOT/tools/check-image-ownership.ts" --repo-root "$t" $FIXTURE_ARGS --report
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^repin-pgtools'
  echo "$output" | grep -q '^bump-poll .*apps/demo'
  echo "$output" | grep -q '^bump-poll .*platform/files'
  echo "$output" | grep -q '^renovate'
}

# ── D-1 클래스: 같은 태그 = 같은 digest ───────────────────────────────────────

@test "the same repo:tag pinned to two digests is rejected (D-1, invisible to the pin gate)" {
  t="$(_fixture skew)"
  echo 'image: registry.example.com/thing:v1@sha256:9999999999999999999999999999999999999999999999999999999999999999' \
    > "$t/platform/comp/prod/other.yaml"
  git -C "$t" add -A
  run GUARD --repo-root "$t" $FIXTURE_ARGS
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "digest 2종으로 갈렸다"
}

# ── D-3 클래스: base64 안에 숨은 참조 ─────────────────────────────────────────

@test "an image hidden inside a base64 Secret value is found and requires an owner (D-3)" {
  t="$(_fixture hidden)"
  # `ghcr.io/x/sidecar:v1.2.3` — YAML 블록 스칼라로 **줄바꿈**해 둔다(실제 벤더 manifest와 같은 형태).
  {
    echo 'apiVersion: v1'
    echo 'kind: Secret'
    echo 'data:'
    echo '  SIDECAR_IMAGE: |'
    echo '    Z2hjci5pby94L3NpZGVjYXI6djEu'
    echo '    Mi4z'
  } > "$t/platform/vendor/manifest.yaml"
  git -C "$t" add -A
  run GUARD --repo-root "$t" $FIXTURE_ARGS
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "base64 안에 숨음"
  # 값이 **온전히** 디코드돼야 한다 — 줄바꿈 조각을 못 이으면 `…sidecar:v`로 잘려 원장 대조가 어긋난다.
  echo "$output" | grep -q "ghcr.io/x/sidecar:v1.2.3"
}

@test "a declared hidden reference passes (declaration is accounting, not exemption)" {
  t="$(_fixture hidden-ok)"
  {
    echo 'data:'
    echo '  SIDECAR_IMAGE: |'
    echo '    Z2hjci5pby94L3NpZGVjYXI6djEu'
    echo '    Mi4z'
  } > "$t/platform/vendor/manifest.yaml"
  git -C "$t" add -A
  _ledger "$t" "d['unowned'].append({'artifact':'platform/vendor/manifest.yaml#ghcr.io/x/sidecar:v1.2.3','why':'벤더','freshness':'수동 re-vendor','since':'2026-07-28','owner_action':'재벤더 시 digest'})"
  run GUARD --repo-root "$t" $FIXTURE_ARGS
  [ "$status" -eq 0 ]
}

# ── 원장 스키마 · 죽은 선언 ───────────────────────────────────────────────────

@test "a declaration missing why or freshness or since or owner_action is rejected" {
  for field in why freshness since owner_action; do
    t="$(_fixture "decl-$field")"
    {
      echo 'data:'
      echo '  SIDECAR_IMAGE: |'
      echo '    Z2hjci5pby94L3NpZGVjYXI6djEu'
      echo '    Mi4z'
    } > "$t/platform/vendor/manifest.yaml"
    git -C "$t" add -A
    _ledger "$t" "e={'artifact':'platform/vendor/manifest.yaml','why':'벤더','freshness':'수동','since':'2026-07-28','owner_action':'x'}; e['$field']='' ; d['unowned'].append(e)"
    run GUARD --repo-root "$t" $FIXTURE_ARGS
    [ "$status" -eq 1 ] || { echo "빈 $field 가 통과했다"; false; }
  done
}

@test "a declaration that matches nothing is rejected (dead claim)" {
  t="$(_fixture dead)"
  _ledger "$t" "d['unowned'].append({'artifact':'platform/ghost.yaml','why':'없는 파일','freshness':'없음','since':'2026-07-28','owner_action':'x'})"
  run GUARD --repo-root "$t" $FIXTURE_ARGS
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "죽은 선언"
}

@test "a missing ledger is a loud failure, not an empty exemption list (fail-open direction)" {
  t="$(_fixture nopolicy)"
  rm "$t/policy/image-ownership.json"
  run GUARD --repo-root "$t" $FIXTURE_ARGS
  [ "$status" -eq 1 ]
}

@test "a missing renovate.json is a loud failure (reachability cannot silently become false)" {
  # ⚠️ `[ "$status" -eq 1 ]`만 두면 **vacuous**하다: 조용히 빈 설정으로 폴백해도 도달성이 전부 false가
  # 되어 모든 참조가 '무소유'로 뒤집히고 어차피 exit 1이 된다 — 두 원인이 같은 빨강이라 구별이 안 된다
  # (mutation이 실제로 이 자리를 죽은 검사로 지목했다). 그래서 **메시지**로 가른다.
  t="$(_fixture norenovate)"
  rm "$t/renovate.json"
  run GUARD --repo-root "$t" $FIXTURE_ARGS
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "renovate.json을 읽을 수 없다"
  out="$output"
  # 진단이 '무소유'로 새면 원인이 정반대로 읽힌다.
  run grep -q "무소유 이미지 참조" <<<"$out"
  [ "$status" -ne 0 ]
}

# ── D-2 클래스: 차트 내부 이미지(레포에 파일이 없다) ──────────────────────────

@test "a helm chart declaration with no ledger entry is rejected (D-2, unreachable by construction)" {
  t="$(_fixture chart)"
  mkdir -p "$t/platform/newthing/prod"
  printf 'apiVersion: builtin\nkind: HelmChartInflationGenerator\nname: newthing\nrepo: https://example.com/charts\nversion: 1.0.0\n' \
    > "$t/platform/newthing/prod/helmrelease.yaml"
  git -C "$t" add -A
  run GUARD --repo-root "$t" $FIXTURE_ARGS
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "chart:newthing"
}

@test "a chart ledger entry for a chart the repo no longer has is rejected" {
  t="$(_fixture chartgone)"
  _ledger "$t" "d['unowned'].append({'artifact':'chart:removed','why':'x','freshness':'x','since':'2026-07-28','owner_action':'x'})"
  run GUARD --repo-root "$t" $FIXTURE_ARGS
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "그런 차트 선언이 레포에 없다"
}

# ── 바닥값 ────────────────────────────────────────────────────────────────────

@test "the reference enumeration floor fires when the domain collapses" {
  run GUARD --repo-root "$ROOT" --min-refs 99999
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "열거 붕괴"
}

@test "the floor value must be a non-negative integer (never a silently disabled floor)" {
  run GUARD --repo-root "$ROOT" --min-refs ""
  [ "$status" -eq 2 ]
  run GUARD --repo-root "$ROOT" --min-refs abc
  [ "$status" -eq 2 ]
}

@test "an unknown flag is rejected with the usage exit code" {
  run GUARD --bogus x
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "알 수 없는 옵션"
}
