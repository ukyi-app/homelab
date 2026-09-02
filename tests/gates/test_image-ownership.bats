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

# ⚠️ **피연산자 실재 증인 + 거부 문구 양성 대조.** 두 뮤테이션이 같은 두 레인을 초록으로 남겼다
#    (실측 2026-09-02, 격리 트리): ① `tools/check-image-ownership.ts` 삭제 — bun의 rc가 **1**인데
#    이 가드의 **위반**도 1이라 `[ "$status" -eq 1 ]`이 둘을 구별하지 못한다. ② `renovate.json` 리네임 —
#    `_fixture`의 `cp`가 커맨드 치환 안이라 실패가 삼켜지고(bats는 `inherit_errexit` off), 도달성 판정
#    불가로 난 rc 1이 스키마/원장 거부로 읽힌다. 두 경우 모두 #8·#10이 `ok`였다.
#    ⇒ 처방 두 겹: setup의 실재 단언 + 각 거부 레인의 문구 대조, 그리고 팩토리의 조립 결과 단언.
setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  [ -f "$ROOT/tools/check-image-ownership.ts" ]
}

GUARD() { bun "$ROOT/tools/check-image-ownership.ts" "$@"; }

# 소유자 4클래스가 각각 최소 하나씩 등장하는 픽스처 레포.
_fixture() {
  local t="$BATS_TEST_TMPDIR/${1:-fx}"
  mkdir -p "$t/platform/comp/prod" "$t/platform/vendor" "$t/apps/demo/deploy/prod" "$t/platform/files/prod"
  cp "$ROOT/renovate.json" "$t/renovate.json"
  echo 'image: registry.example.com/thing:v1@sha256:1111111111111111111111111111111111111111111111111111111111111111' > "$t/platform/comp/prod/deploy.yaml"
  echo 'image: ghcr.io/ukyi-app/pg-tools:18-rclone@sha256:2222222222222222222222222222222222222222222222222222222222222222' > "$t/platform/comp/prod/job.yaml"
  # CATALOG 두 키를 **둘 다** 픽스처에 둔다 — 하나만 있으면 REPINNED_OPS 표기가 한쪽에서만 검증되고,
  # 실제로 착지 전 두 정규식은 경로 구분자 요구 여부가 근거 없이 갈려 있었다(pg-tools 미요구·skopeo 요구).
  echo 'image: ghcr.io/ukyi-app/skopeo:alpine@sha256:5555555555555555555555555555555555555555555555555555555555555555' > "$t/platform/comp/prod/skopeo.yaml"
  printf 'image:\n  repo: ghcr.io/ukyi-app/demo\n  tag: sha-abc\n  digest: sha256:3333333333333333333333333333333333333333333333333333333333333333\n' > "$t/apps/demo/deploy/prod/values.yaml"
  echo 'image: ghcr.io/ukyi-app/files:sha-x@sha256:4444444444444444444444444444444444444444444444444444444444444444' > "$t/platform/files/prod/deployment.yaml"
  printf '{"file":"deployment.yaml","path":["a"],"autoDeploy":true}\n' > "$t/platform/files/prod/.image-pin.json"
  printf '{\n  "unowned": []\n}\n' > "$t/policy/image-ownership.json" 2>/dev/null || { mkdir -p "$t/policy"; printf '{\n  "unowned": []\n}\n' > "$t/policy/image-ownership.json"; }
  git -C "$t" init -q
  git -C "$t" add -A
  # 픽스처 무결성 — `cp`의 실패는 커맨드 치환이 삼키므로(치환의 rc는 마지막 `echo`의 0이다) 여기서
  # 판정해 **`echo` 앞에서** 되돌린다. 그래야 호출부 `t="$(_fixture …)"`의 rc가 bats errexit에 닿는다
  # (선례: tests/test_dr-drill.bats · tests/gates/test_absence-assertion-witness.bats).
  [ -f "$t/renovate.json" ] || return 1
  echo "$t"
}

_ledger() { python3 -c "
import json,sys
p=sys.argv[1]
d=json.load(open(p,encoding='utf-8'))
exec(sys.argv[2])
json.dump(d,open(p,'w',encoding='utf-8'),ensure_ascii=False,indent=2)
" "$1/policy/image-ownership.json" "$2"; }

FIXTURE_ARGS="--floor refs=1"

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
  # ⚠️ **비-도달 센티넬은 ignore 분기를 실제로 밟아야 증인이다.** 착지 전 no 4개 중 둘
  #    (`tools/templates/x.yaml`·`docs/plans/x.yaml`)은 include 자체에 미도달이라(:179-182의 첫 줄을
  #    지워도 여전히 false) ignorePaths를 증언하지 않는 vacuous 샘플이었다 — 실측(bareReach=false).
  #    그래서 각 no에 대해 "**ignore를 비우면 도달한다**"를 함께 단언한다(VACUOUS 레인). 그 대조가
  #    샘플의 자격을 스스로 증명하므로, 이 목록은 손으로 관리해도 조용히 썩지 않는다.
  # ⚠️ tools/templates·docs/plans에 닿는 include는 dockerfile manager(`(^|/)Dockerfile$`) **하나뿐**이라
  #    (yaml 패턴은 전부 `^platform/`·`^apps/` 접두다 — 실측) 그 둘의 샘플이 Dockerfile인 것은 의도다.
  #    누가 dockerfile manager를 끄면 VACUOUS 레인이 **loud red**를 낸다(조용한 vacuity로 되돌아가지 않는다).
  # ⚠️ UNCOVERED 레인 — ignorePaths 항목이 늘었는데 센티넬이 없으면 그 항목은 무증인이다.
  run bun -e '
    import { loadRenovate, renovateReaches } from "'"$ROOT"'/tools/check-image-ownership.ts";
    const r = loadRenovate("'"$ROOT"'");
    const bare = { include: r.include, ignore: [] };   // ignorePaths만 뺀 같은 설정(vacuity 대조군)
    const yes = ["platform/victoria-stack/prod/vmagent.yaml", "apps/page/deploy/prod/values.yaml",
                 "platform/argocd/root/apps/cnpg-operator.yaml", "platform/traefik/prod/helmrelease.yaml"];
    const no  = ["platform/traefik/prod/charts/traefik/values.yaml", "platform/cnpg/barman-plugin/manifest.yaml",
                 "tools/templates/Dockerfile", "docs/plans/Dockerfile"];
    const bad = [...yes.filter((p) => !renovateReaches(p, r)).map((p) => "MISS " + p),
                 ...no.filter((p) => renovateReaches(p, r)).map((p) => "FALSE " + p),
                 ...no.filter((p) => !renovateReaches(p, bare)).map((p) => "VACUOUS " + p),
                 ...r.ignore.filter((re) => !no.some((p) => re.test(p))).map((re) => "UNCOVERED " + re.source)];
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
  # 두 ops 이미지 각각이 이 소유자로 분류되는지 — 집합이 아니라 원소별로 본다.
  # 하나만 보면 REPINNED_OPS의 한 정규식이 깨져도 다른 하나가 클래스를 채워 초록이 된다.
  echo "$output" | grep -q '^repin-ops-image .*pg-tools'
  echo "$output" | grep -q '^repin-ops-image .*skopeo'
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
    # 거부 **사유**를 문다 — rc 1만 보면 도달성 판정 불가·원장 부재 등 다른 실패와 구별되지 않는다.
    printf '%s' "$output" | grep -qF -- '원장 항목 검증 실패'
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
  # 형제 레인(missing renovate.json)과 같은 규율 — rc가 아니라 **문구**로 원인을 가른다.
  printf '%s' "$output" | grep -qF -- '정책 원장 읽기 실패'
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
  run GUARD --repo-root "$ROOT" --floor refs=99999
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "열거 붕괴"
}

# 이 가드는 커널 이행 **전에도** 빈 입력을 거부했다(자체 positiveInt). 파서를 커널로 옮기면서
# 그 거부가 사라지면 회귀다 — 설계 게이트 r2가 지목한 자리라 소수·음수까지 넓혀 잠근다.
@test "the floor value must be a non-negative integer (never a silently disabled floor)" {
  for bad in "" abc 1.5 -1; do
    run GUARD --repo-root "$ROOT" --floor "refs=$bad"
    [ "$status" -eq 2 ]
    # 바닥값이 꺼진 채 초록이 되면 마커가 나간다 — 나가면 안 된다.
    # ⚠️ `grep -q … && false`로 쓰면 매치 **안 될 때** rc=1이라 set -e가 통과 경로를 죽인다.
    if printf '%s\n' "$output" | grep -q '^SCAN:'; then echo "예상 밖 SCAN 마커: $output"; false; fi
  done
}

# 0은 정당한 바닥값이다(빈 문자열과 갈려야 한다) — 금지하면 "앱이 0개인 동안" 같은 자리를 막는다.
@test "an explicit zero floor is accepted (it is a legitimate value, unlike empty)" {
  run GUARD --repo-root "$ROOT" --floor refs=0
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qE '^SCAN: check-image-ownership:refs: [0-9]+$'
}

@test "an unknown flag is rejected with the usage exit code" {
  run GUARD --bogus x
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "알 수 없는 옵션"
}

@test "a Dockerfile FROM is extracted and owned, and a stage alias is not mistaken for an image" {
  # 스코프에 들어오는 것과 **참조를 실제로 뽑는 것**은 다르다 — mutation이 추출기에 증인이 없음을 드러냈다.
  # 멀티스테이지의 `FROM builder`(앞 스테이지 별칭)는 이미지가 아니므로 잡으면 안 된다.
  t="$(_fixture dockerfile)"
  mkdir -p "$t/ops/thing"
  printf 'FROM debian:bookworm-slim@sha256:7777777777777777777777777777777777777777777777777777777777777777 AS builder\nRUN true\nFROM builder\nCOPY --from=builder /x /x\n' \
    > "$t/ops/thing/Dockerfile"
  git -C "$t" add -A
  run bun "$ROOT/tools/check-image-ownership.ts" --repo-root "$t" $FIXTURE_ARGS --report
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'ops/thing/Dockerfile — debian:bookworm-slim@sha256:7777'
  out="$output"
  # 스테이지 별칭이 참조로 새면 안 된다.
  run grep -qE 'Dockerfile — builder$' <<<"$out"
  [ "$status" -ne 0 ]
}

# ── 적대 재검토 확정 결함의 증인 (PR #388 후속) ──────────────────────────────

@test "a manager disabled with enabled:false loses ownership (not just a missing pattern)" {
  # `enabled: false`는 패턴을 지우는 것과 **의미가 같다**. 모델하지 않으면 한 줄로 수십 건의
  # 소유자가 유령이 된다 — 실측: kubernetes manager를 끄고도 26건이 renovate 소유로 보고되며 exit 0이었다.
  t="$(_fixture disabled)"
  python3 - "$t/renovate.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
d["kubernetes"]["enabled"] = False
json.dump(d, open(p, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PY
  git -C "$t" add -A
  run GUARD --repo-root "$t" $FIXTURE_ARGS
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "무소유 이미지 참조"
}

@test "an imageName: reference is never counted as Renovate-owned (the repo already proved this live)" {
  # kubernetes manager는 표준 `image:`만 추출한다 — 커밋 ba9bc2a(#373)가 라이브로 증명했다:
  # "Renovate #362는 표준 image: 키인 basebackup만 갱신하고 CNPG imageName:를 누락해 digest 드리프트를 유발".
  # 경로만 보고 판정하면 이 참조가 거짓으로 소유돼 stale-pin이 초록으로 통과한다.
  t="$(_fixture imagename)"
  printf 'imageName: registry.example.com/db:v1@sha256:5555555555555555555555555555555555555555555555555555555555555555\n' \
    > "$t/platform/comp/prod/cr.yaml"
  git -C "$t" add -A
  run GUARD --repo-root "$t" $FIXTURE_ARGS
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "cr.yaml"
}

@test "a shell script embedding a manifest is in scope (extension filters reproduce D-1)" {
  # `.yaml`만 보던 동안 heredoc으로 매니페스트를 임베드한 .sh가 통째로 빠졌다 — 그 안의 digest를
  # 바꿔도 어떤 게이트도 red가 되지 않았다(같은 repo:tag 두 digest = D-1 클래스의 확장자 재현).
  t="$(_fixture shellembed)"
  printf 'imageName: registry.example.com/thing:v1@sha256:8888888888888888888888888888888888888888888888888888888888888888\n' \
    > "$t/platform/comp/prod/drill.sh"
  git -C "$t" add -A
  run GUARD --repo-root "$t" $FIXTURE_ARGS
  [ "$status" -eq 1 ]
  # 같은 태그가 두 digest로 갈린 것도 함께 잡혀야 한다(픽스처의 thing:v1은 1111…이다).
  echo "$output" | grep -q "digest 2종으로 갈렸다"
}

@test "an ArgoCD Application outside root/apps is enumerated (kind, not filename)" {
  # 경로 패턴으로 좁히면 실존하는 모양이 빠진다 — root-app이 recurse로 **실제 싱크하는** 경로에
  # Application을 두면 예전 가드는 못 봤다(refs 수도 안 변해 바닥값도 무력).
  t="$(_fixture appshape)"
  printf 'apiVersion: argoproj.io/v1alpha1\nkind: Application\nmetadata: { name: x }\nspec:\n  source:\n    chart: some-chart\n' \
    > "$t/platform/elsewhere.yaml"
  git -C "$t" add -A
  run GUARD --repo-root "$t" $FIXTURE_ARGS
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "chart:some-chart"
}

@test "operator-injected declarations are exempt from the dead-claim check (no repo string exists)" {
  # operator가 런타임에 주입하는 이미지는 레포에 문자열이 없다 — 참조 스캔으로 원리적으로 매치될 수
  # 없으므로 죽은-선언 검사에서 면제해야 한다. 면제가 없으면 정당한 선언이 red가 된다(실증됨).
  t="$(_fixture opinj)"
  _ledger "$t" "d['unowned'].append({'artifact':'operator-injected:demo/sidecar','why':'operator 주입','freshness':'operator 버전 종속','since':'2026-07-28','owner_action':'오버라이드'})"
  run GUARD --repo-root "$t" $FIXTURE_ARGS
  [ "$status" -eq 0 ]
}

@test "the pin gate no longer claims chart internals are Renovate-owned (header and success message)" {
  # 이 PR이 거짓이라 문서화한 주장이 **원래 자리**에 남으면 서술 불일치다. 헤더 10행이 "성공 메시지도
  # 이 경계를 반영"을 계약으로 걸고 있으므로 둘을 함께 본다.
  # ⚠️ **인용된 기록은 살아 있는 주장이 아니다.** 헤더는 무엇이 왜 틀렸는지 설명하려고 옛 문구를
  #    따옴표로 인용하는데(지우면 재발 방지 근거가 사라진다), 단순 grep은 그것도 매치한다 —
  #    `repin-ops-image` 헤더에서 이미 같은 경계를 그었다. 따옴표 없는 줄만 본다.
  # ⚠️ `-ne 0`은 grep rc **2**(대상 파일 부재/읽기불가)도 통과로 읽는다 — 무매치는 정확히 rc 1이다.
  #    (파이프 자리는 2단 grep이 stdin을 읽어 rc 2가 1로 눌리지만, 이 @test 끝의 양성 대조가
  #     같은 파일에 `-eq 0`을 걸고 있어 파일 부재는 그쪽에서 red가 된다.)
  run bash -c "grep -n 'Renovate pinDigests 관할' '$ROOT/scripts/check-image-pins.sh' | grep -v '\"'"
  [ "$status" -eq 1 ]
  run grep -n 'helm 차트 내부=Renovate' "$ROOT/scripts/check-image-pins.sh"
  [ "$status" -eq 1 ]   # rc 2(대상 부재)를 통과로 읽지 않는다
  # 그리고 실제 소유 모델(원장 선언)을 가리켜야 한다.
  run grep -q 'image-ownership.json' "$ROOT/scripts/check-image-pins.sh"
  [ "$status" -eq 0 ]
}
