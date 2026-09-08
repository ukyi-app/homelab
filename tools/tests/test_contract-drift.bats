#!/usr/bin/env bats
# 동봉 계약 매니페스트·정규화 로직 가드 (CI-safe — 라이브 raw fetch는 contract-drift.yaml 워크플로 전용).
# ⚠️ 중간 부정 단언은 run+[ ]만.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; M="tools/vendored-contract.json"; }

@test "vendored-contract manifest is valid JSON with existing local sources" {
  jq -e '.vendored | length > 0' "$M"
  for s in $(jq -r '.vendored[].source' "$M"); do
    [ -f "$s" ] || { echo "누락 source: $s"; return 1; }
  done
}

@test "vendored roster covers exactly the two contract artifacts (targets non-empty, same repo set)" {
  # untouched-d-1(5라운드) — 위 @test는 하한(length>0)뿐이라 원소를 지워도(다운스트림 3 target
  # 동반 소멸) 초록이었다(실측: pem 항목 삭제 → 4/4). 원소 수·멤버십을 등식으로 잠근다.
  # target 축은 매직넘버(repo 3개 이름)를 쓰지 않는다 — 앱 레포 집합은 create-app/teardown으로
  # 변하고 in-repo 파생원이 없어 정당 변경마다 손 갱신 세금이 된다(va 판정 근거). 대신 두 계약
  # 항목의 target repo 집합이 서로 같다는 구조 불변식(정렬 집합의 unique 길이==1)만 잠근다.
  n=$(jq -r '[.vendored[].source] | length' "$M"); [ "$n" -eq 2 ]
  jq -e '[.vendored[].source] | index("tools/seal-secret.mts") != null' "$M"
  jq -e '[.vendored[].source] | index("tools/sealed-secrets-cert.pem") != null' "$M"
  jq -e 'all(.vendored[]; (.targets|length) > 0)' "$M"
  s=$(jq -r '[.vendored[] | [.targets[].repo] | sort] | unique | length' "$M"); [ "$s" -eq 1 ]
}

@test "vendored-contract excludes files repo (Rust — no vendored seal tooling)" {
  # ⚠️ 이 레인에서 `jq`는 원칙상 비대상이었다(rc 어휘가 grep과 달라 일괄 전환이 위험하다). 이 자리만
  #    예외인 이유: `jq -e`는 **술어 결과와 대상 부재를 서로 다른 rc로 가른다**.
  #    2026-08-29 실측(jq 1.8.1): 무매치(null)=**1** · 매치=0 · 파일 부재=**2** · 빈 파일=4 ·
  #    파싱 오류/스키마 밖(`.vendored` 부재)=5. 즉 `-eq 1`이 받는 것은 "index가 null" 하나뿐이다.
  #    예전 `-ne 0`은 $M 리네임(rc 2)도 "files repo 없음"으로 읽었고, 이 @test에는 형제 양성 단언이
  #    없다 — :7의 매니페스트 실재 단언은 **다른 @test**라 `bats -f` 단일 실행에서 증인이 못 된다.
  #    cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」③
  run jq -e '[.vendored[].targets[].repo] | index("files")' "$M"
  [ "$status" -eq 1 ]
}

@test "cert targets require exact normalization (public sealing cert must be byte-identical)" {
  n=$(jq -r '[.vendored[] | select(.source|endswith(".pem")) | .targets[] | select(.normalize!="exact")] | length' "$M")
  [ "$n" -eq 0 ]
}

@test "drift checker self-test passes (offline normalize unit — ts formatter-insensitive: ws/;/,, pem exact)" {
  run bun tools/contract-drift-check.ts --self-test
  [ "$status" -eq 0 ]
}

# ── (a) 로스터 파생·등식 대조(티켓 36) ────────────────────────────────────────
# 매니페스트의 앱 target은 손 열거였다 — 철거된 레포는 남고 새 앱은 영원히 미등재였다.
# 이제 앱 축은 `apps/*/deploy/prod/source-repo`(인레포 파생원)에서 파생하고 매니페스트와
# **등식**으로 대조한다(⊇가 아니다: 초과분도 드리프트다). 템플릿 행은 앱이 아니라 scaffoldRepos다.

# 픽스처 루트: mkroot <app>=<owner/repo> … (앱 0개면 인자 없이)
mkroot() {
  R="$(mktemp -d)"
  mkdir -p "$R/apps"
  for kv in "$@"; do
    a="${kv%%=*}"; v="${kv#*=}"
    mkdir -p "$R/apps/$a/deploy/prod"
    printf '%s\n' "$v" > "$R/apps/$a/deploy/prod/source-repo"
  done
}
# 픽스처 매니페스트: mkmanifest <repo…> — scaffoldRepos는 homelab-app-template 고정.
mkmanifest() {
  MF="$R/manifest.json"
  {
    printf '{ "owner": "ukyi-app", "scaffoldRepos": ["homelab-app-template"], "vendored": [ { "source": "tools/seal-secret.mts", "targets": [ { "repo": "homelab-app-template", "ref": "main", "path": "scaffold/common/tools/seal-secret.mts", "normalize": "typescript" }'
    for r in "$@"; do
      printf ', { "repo": "%s", "ref": "main", "path": "tools/seal-secret.mts", "normalize": "typescript" }' "$r"
    done
    printf ' ] } ] }\n'
  } > "$MF"
}

@test "roster reconciliation is an equality: a manifest target with no app dir is drift" {
  mkroot
  mkmanifest ghost
  run bun tools/contract-drift-check.ts --roster --root "$R" --manifest "$MF"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"status": "mismatch"'
  echo "$output" | grep -q '"stale"'
  echo "$output" | grep -q 'ghost'
  rm -rf "$R"
}

@test "roster reconciliation flags an app repo that the manifest never learned about" {
  mkroot orders=ukyi-app/orders
  mkmanifest
  run bun tools/contract-drift-check.ts --roster --root "$R" --manifest "$MF"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"status": "mismatch"'
  echo "$output" | grep -q 'orders'
  # 양성 대조 — 같은 앱을 매니페스트에 넣으면 등식이 성립한다(검출기가 상시 mismatch가 아니다).
  mkmanifest orders
  run bun tools/contract-drift-check.ts --roster --root "$R" --manifest "$MF"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"status": "matched"'
  rm -rf "$R"
}

@test "an app set of zero is an explicit signal, not a silent pass" {
  # apps/가 비어 있으면 등식은 공집합끼리 성립한다 — 그냥 두면 vacuous green이다.
  mkroot
  mkmanifest
  run bun tools/contract-drift-check.ts --roster --root "$R" --manifest "$MF"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"status": "greenfield"'
  # 신호는 JSON 필드에만 있지 않다 — 사람이 읽는 채널(stderr)에도 한 줄 나간다.
  echo "$output" | grep -q '^ROSTER:'
  # 양성 대조 — 앱이 하나라도 있으면 greenfield가 아니다(그린필드 판정이 상수가 아님).
  mkroot orders=ukyi-app/orders
  mkmanifest orders
  run bun tools/contract-drift-check.ts --roster --root "$R" --manifest "$MF"
  [ "$status" -eq 0 ]
  [ -z "$(echo "$output" | grep 'greenfield' || true)" ]
  rm -rf "$R"
}

@test "the shipped manifest no longer targets torn-down app repos" {
  # trip-mate-api는 철거됐다(#456) — 철거 레포 잔재 target은 알림 건수를 부풀려 자기 임계를 올린다.
  # page는 #455 철거 → 2026-09-08 재온보딩(create-app #691) → 같은 날 철거 드릴(teardown-app #698)로 다시 부재다 —
  # 손 열거 대신 위 roster 등식(apps/*/source-repo ↔ targets)이 권위이고, 여기서는 철거 레포의 부재만 고정한다.
  run jq -e '[.vendored[].targets[].repo] | index("trip-mate-api")' "$M"
  [ "$status" -eq 1 ]
  run jq -e '[.vendored[].targets[].repo] | index("page")' "$M"
  [ "$status" -eq 1 ]
  # 양성 대조 — 같은 질의가 템플릿에는 매치한다(로스터가 통째로 비지 않았다).
  run jq -e '[.vendored[].targets[].repo] | index("homelab-app-template")' "$M"
  [ "$status" -eq 0 ]
}

@test "the shipped manifest reconciles against this repo's real app set" {
  run bun tools/contract-drift-check.ts --roster --root . --manifest "$M"
  [ "$status" -eq 0 ]
  [ -z "$(echo "$output" | grep '"status": "mismatch"' || true)" ]
  # 양성 대조 — 판정이 실제로 났음을 같은 @test에서 확인한다(모드가 조용히 죽지 않았다).
  echo "$output" | grep -qE '"status": "(greenfield|matched)"'
}

@test "the scaffold repo is declared, not derived (a template is not an app)" {
  # scaffoldRepos가 없으면 템플릿 행이 매번 stale로 잡힌다 — 선언 축이 로스터 등식의 전제다.
  jq -e '.scaffoldRepos | index("homelab-app-template") != null' "$M"
}

# ── (b) PR 시점 오프라인 체크리스트 ──────────────────────────────────────────
# 라이브 대조는 SSOT 편집 PR에서 상시 red다(그 PR이 만드는 drift가 정상 상태다).
# 그래서 PR 신호는 fetch가 아니라 **변경 파일 ∩ 매니페스트 source**의 정적 교집합이다.

@test "the downstream checklist renders offline from a changed-file list" {
  R="$(mktemp -d)"
  printf 'tools/seal-secret.mts\nREADME.md\n' > "$R/changed.txt"
  run bun tools/contract-drift-check.ts --checklist --changed "$R/changed.txt" --manifest "$M"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'homelab-app-template'
  echo "$output" | grep -q 'scaffold/common/tools/seal-secret.mts'
  n=$(printf '%s\n' "$output" | grep -c '^- \[ \]' || true)
  [ "$n" -ge 1 ]
  rm -rf "$R"
}

@test "a changed-file list that misses every SSOT renders an explicit zero, not silence" {
  R="$(mktemp -d)"
  printf 'README.md\n' > "$R/changed.txt"
  run bun tools/contract-drift-check.ts --checklist --changed "$R/changed.txt" --manifest "$M"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '0건'
  [ -z "$(printf '%s\n' "$output" | grep '^- \[ \]' || true)" ]
  # 양성 대조 — 같은 호출이 SSOT를 포함한 목록에서는 체크리스트 줄을 낸다.
  printf 'README.md\ntools/sealed-secrets-cert.pem\n' > "$R/changed.txt"
  run bun tools/contract-drift-check.ts --checklist --changed "$R/changed.txt" --manifest "$M"
  [ "$status" -eq 0 ]
  n=$(printf '%s\n' "$output" | grep -c '^- \[ \]' || true)
  [ "$n" -ge 1 ]
  rm -rf "$R"
}

@test "the contract-drift workflow renders the checklist on pull_request without any live fetch" {
  W=".github/workflows/contract-drift.yaml"
  # PR 트리거 + SSOT paths 한정.
  grep -q 'pull_request:' "$W"
  grep -q 'tools/vendored-contract.json' "$W"
  # 체크리스트 잡은 --checklist만 부른다(라이브 fetch 모드를 PR에서 부르지 않는다).
  grep -q -- '--checklist' "$W"
  # 라이브 fetch 잡은 PR에서 돌지 않는다 — 그 조건이 워크플로에 문자로 있어야 한다.
  grep -qF "github.event_name != 'pull_request'" "$W"
}

# ── (c) errors 사유 축 ────────────────────────────────────────────────────────

@test "the error classifier is a pure function exercised by --self-test" {
  run bun tools/contract-drift-check.ts --self-test
  [ "$status" -eq 0 ]
  # 케이스 수 바닥값 — self-test가 케이스를 잃어도 rc 0이던 자리(단일 boolean)를 막는다.
  echo "$output" | grep -qE '^SELFTEST: [0-9]+ cases ok$'
  n=$(printf '%s\n' "$output" | sed -n 's/^SELFTEST: \([0-9]*\) cases ok$/\1/p')
  [ "$n" -ge 10 ]
}

@test "a self-test with a case forced to fail names the case (the runner is not a constant zero)" {
  # 양성 대조 — 위 @test의 rc 0이 "케이스가 하나도 안 돌았다"와 구별된다.
  run bun tools/contract-drift-check.ts --self-test --self-test-mutate
  [ "$status" -eq 1 ]
  echo "$output" | grep -q '^SELFTEST FAIL:'
}

@test "the workflow ident carries per-reason error counts (404/403 vs transient)" {
  W=".github/workflows/contract-drift.yaml"
  grep -q 'absent-or-private' "$W"
  grep -q 'transient' "$W"
  # 양성 대조 — ident 줄 자체가 살아 있다(문자열이 다른 데 흩어진 게 아니다).
  grep -q 'ident:' "$W"
}

# ── (d) typescript 정규화의 줄 주석 경계 ────────────────────────────────────

@test "typescript normalization keeps the comment/code boundary (code moved into a comment differs)" {
  run bun -e '
    import { normalize } from "./tools/contract-drift-check.ts";
    const a = normalize("// a\nb();", "typescript");
    const b = normalize("// a b();", "typescript");
    if (a === b) { console.error("주석/코드 경계 소실: " + JSON.stringify(a)); process.exit(1); }
    // 양성 대조 — 포매터 재줄바꿈에는 여전히 둔감해야 한다(과잉 민감으로 뒤집히지 않았다).
    if (normalize("type A = {\n  a: string;\n};", "typescript") !== normalize("type A = { a: string };", "typescript")) {
      console.error("포매터 무감각 소실"); process.exit(1);
    }
    console.log("ok");
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^ok$'
}
