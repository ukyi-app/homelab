#!/usr/bin/env bats
# image-pin charlock — arch-deepen-2026-07-09 리팩터(tools/lib/image-pin.ts 커널 추출)의 behavior lock 백필.
# plan-gate P-1 수용분. 기존 5 스위트(test_poll-ghcr/test_bump/test_create-app 등) 무수정 원칙에 따라
# 이 파일은 **추가 전용**이다. characterization: 기대 문자열/바이트는 전부 현재(un-refactored) 코드의
# 실제 출력에서 채취했다(born-green이 정상). 리팩터 후에도 이 스위트는 무수정 green을 유지해야 한다.
# 커버: poll-ghcr refuse 사유(B2)·bump-tag stderr+exit(B4)·인라인 핀 파일 바이트(B6)·
#        digest-exporter 동기 로그(B8)·create-app tag/digest 거부(B9)·형식 경계+non-greedy 파싱(B10).
#
# 단언 규율: 중간 단언은 전부 `run …; [ "$status" … ]` / `[ … ]`(단일 대괄호) / `… | grep -Fq`로만.
# bash 3.2 set -e는 중간 `[[ ]]`·negated 파이프라인 실패를 침묵 통과시킨다(check-bats-style 강제).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  P="$ROOT/tools/poll-ghcr.ts"   # GHCR 폴링 플래너(읽기 전용)
  B="$ROOT/tools/bump-tag.ts"    # tag/digest bump(apps values + 베스포크 인라인 핀)
  C="$ROOT/tools/create-app.ts"  # 앱 생성기
  TMP="$(mktemp -d)"
  mkdir -p "$TMP/fx"             # 빈 fixtures 디렉토리(라이브 gh/docker 대체 — refuse는 조회 전 발생)
  # 유효 64-hex digest 3종(리팩터 커널이 검증 경계를 바꾸지 못하게 고정값 사용)
  DIG="sha256:4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945"
  DIG2="sha256:2222222222222222222222222222222222222222222222222222222222222222"
  NEWDIG="sha256:1111111111111111111111111111111111111111111111111111111111111111"
}
teardown() { rm -rf "$TMP"; }

run_poll() { run bun "$P" --root "$TMP" --fixtures "$TMP/fx" --dry-run; }

# apps 레인 픽스처: apps/blog/deploy/prod/values.yaml(tag=sha-0000000, digest 없음)
seed_app_blog() {
  mkdir -p "$TMP/apps/blog/deploy/prod"
  cat > "$TMP/apps/blog/deploy/prod/values.yaml" <<'EOF'
image:
  repo: ghcr.io/ukyi-app/blog
  tag: sha-0000000
kind: web
EOF
}

# 베스포크 레인 픽스처: platform/files/prod/{source-repo,.image-pin.json,deployment.yaml}. $1 = image 스칼라.
seed_bespoke_pin() {
  PD="$TMP/platform/files/prod"
  mkdir -p "$PD"
  printf 'ukyi-app/files' > "$PD/source-repo"
  cat > "$PD/.image-pin.json" <<'JSON'
{ "file": "deployment.yaml", "path": ["spec","template","spec","containers",0,"image"], "autoDeploy": true }
JSON
  cat > "$PD/deployment.yaml" <<YAML
spec:
  template:
    spec:
      containers:
        - name: files
          image: $1
YAML
}

# digest-exporter 픽스처: victoria-stack/prod/digest-exporter.yaml, APPS env = $1(공백구분 name=repo:tag 목록).
seed_exporter() {
  mkdir -p "$TMP/platform/victoria-stack/prod"
  cat > "$TMP/platform/victoria-stack/prod/digest-exporter.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
spec:
  template:
    spec:
      containers:
        - name: digest-exporter
          env:
            - name: APPS
              value: "$1"
EOF
}

# ─────────────────────────── B2: poll-ghcr 정확 refuse 사유 ───────────────────────────

@test "poll-ghcr B2: bespoke inline pin missing @digest refuses with exact format reason" {
  seed_bespoke_pin "ghcr.io/ukyi-app/files:sha-aaa1111000000000000000000000000000000000"
  run_poll
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[] | select(.app=="files") | .action == "refuse"'
  echo "$output" | jq -e '.[] | select(.app=="files") | .reason == "인라인 핀 형식 불량(repo:sha-*@sha256:*): ghcr.io/ukyi-app/files:sha-aaa1111000000000000000000000000000000000"'
}

@test "poll-ghcr B2: inline pin repo not matching source-repo refuses with exact mismatch reason" {
  seed_bespoke_pin "ghcr.io/ukyi-app/other:sha-aaa1111000000000000000000000000000000000@$DIG2"
  run_poll
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[] | select(.app=="files") | .action == "refuse"'
  echo "$output" | jq -e '.[] | select(.app=="files") | .reason == "핀 repo(ghcr.io/ukyi-app/other)가 source-repo(ukyi-app/files)와 불일치"'
}

@test "poll-ghcr B2: apps lane non-sha tag refuses with exact ancestry-proof reason" {
  mkdir -p "$TMP/apps/orders/deploy/prod"
  printf 'ukyi-app/orders' > "$TMP/apps/orders/deploy/prod/source-repo"
  cat > "$TMP/apps/orders/deploy/prod/values.yaml" <<'EOF'
image:
  repo: ghcr.io/ukyi-app/orders
  tag: latest
EOF
  run_poll
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[] | select(.app=="orders") | .action == "refuse"'
  echo "$output" | jq -e '.[] | select(.app=="orders") | .reason == "배포 tag가 sha-* 형식이 아니라 조상 증명 불가: latest"'
}

@test "poll-ghcr B2: malformed image-pin json refuses via outer catch with plan-failure prefix" {
  PD="$TMP/platform/files/prod"
  mkdir -p "$PD"
  printf 'ukyi-app/files' > "$PD/source-repo"
  printf '{ not valid json' > "$PD/.image-pin.json"
  run_poll
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[] | select(.app=="files") | .action == "refuse"'
  echo "$output" | jq -e '.[] | select(.app=="files") | (.reason | startswith("플랜 실패: "))'
}

# ─────────────────────────── B4: bump-tag 정확 stderr + exit 2 ───────────────────────────

@test "bump-tag B4: malformed app name prints exact stderr and exits 2" {
  run bun "$B" Bad_App sha-deadbee --repo-root "$TMP"
  [ "$status" -eq 2 ]
  echo "$output" | grep -Fq "bad app name: Bad_App"
}

@test "bump-tag B4: malformed tag prints the exact usage string and exits 2" {
  seed_app_blog
  run bun "$B" blog sha-xyz --repo-root "$TMP"
  [ "$status" -eq 2 ]
  echo "$output" | grep -Fq "usage: bump-tag <app> sha-<gitsha> [--digest sha256:<64hex>] [--expect-current sha-<gitsha>] [--repo-root <dir>]"
}

@test "bump-tag B4: malformed digest prints exact stderr and exits 2" {
  seed_app_blog
  run bun "$B" blog sha-deadbee --digest sha256:nothex --repo-root "$TMP"
  [ "$status" -eq 2 ]
  echo "$output" | grep -Fq "bad digest: sha256:nothex"
}

# ─────────────────────────── B6: bump-tag 인라인 모드 파일 바이트 ───────────────────────────

@test "bump-tag B6: inline pin rewrite yields byte-exact deployment.yaml (scalar + lineComment, rest unchanged)" {
  PD="$TMP/platform/files/prod"
  mkdir -p "$PD"
  cat > "$PD/.image-pin.json" <<'JSON'
{ "file": "deployment.yaml", "path": ["spec","template","spec","containers",0,"image"], "autoDeploy": true }
JSON
  cat > "$PD/deployment.yaml" <<EOF
spec:
  template:
    spec:
      containers:
        - name: files
          image: ghcr.io/ukyi-app/files:sha-0000000@$DIG # sha-0000000 + digest 인라인 핀(불변)
EOF
  run bun "$B" files sha-feedbee --digest "$NEWDIG" --pin platform/files/prod/.image-pin.json --repo-root "$TMP"
  [ "$status" -eq 0 ]
  # 골든: 새 스칼라 repo:sha-feedbee@새digest + lineComment ` sha-feedbee + digest 인라인 핀(불변)`.
  # 나머지 라인/들여쓰기/후행개행 전부 무변경(diff rc=0 = 바이트 동일).
  cat > "$TMP/expected.yaml" <<EOF
spec:
  template:
    spec:
      containers:
        - name: files
          image: ghcr.io/ukyi-app/files:sha-feedbee@$NEWDIG # sha-feedbee + digest 인라인 핀(불변)
EOF
  run diff "$TMP/expected.yaml" "$PD/deployment.yaml"
  [ "$status" -eq 0 ]
}

@test "bump-tag B6: apps lane tag-only bump removes stale digest with exact stdout detail" {
  seed_app_blog
  run bun "$B" blog sha-deadbee --digest "$DIG" --repo-root "$TMP"
  [ "$status" -eq 0 ]
  run bun "$B" blog sha-feedbee --repo-root "$TMP"
  [ "$status" -eq 0 ]
  echo "$output" | grep -Fq "(stale image.digest $DIG removed)"
  run yq '.image.digest' "$TMP/apps/blog/deploy/prod/values.yaml"
  [ "$output" == "null" ]
  run yq '.image.tag' "$TMP/apps/blog/deploy/prod/values.yaml"
  [ "$output" == "sha-feedbee" ]
}

# ─────────────────────────── B8: digest-exporter 동기 로그 정확 문구 ───────────────────────────

@test "bump-tag B8: app absent from digest-exporter APPS logs exact skip line" {
  seed_app_blog
  seed_exporter "page=ghcr.io/ukyi-app/page:sha-cd4815ca409992f56bf72d324d0806acb97010e2"
  run bun "$B" blog sha-deadbee --digest "$DIG" --repo-root "$TMP"
  [ "$status" -eq 0 ]
  echo "$output" | grep -Fq "digest-exporter: APPS에 blog 없음(또는 이미 최신) — 동기 skip"
}

@test "bump-tag B8: app present in digest-exporter APPS logs exact sync line and rewrites the tag" {
  seed_app_blog
  seed_exporter "blog=ghcr.io/ukyi-app/blog:sha-0000000 page=ghcr.io/ukyi-app/page:sha-cd4815ca409992f56bf72d324d0806acb97010e2"
  run bun "$B" blog sha-deadbee --digest "$DIG" --repo-root "$TMP"
  [ "$status" -eq 0 ]
  echo "$output" | grep -Fq "digest-exporter: APPS blog 태그 동기 → sha-deadbee"
  run grep -c "blog=ghcr.io/ukyi-app/blog:sha-deadbee" "$TMP/platform/victoria-stack/prod/digest-exporter.yaml"
  [ "$output" -eq 1 ]
}

# ─────────────────────────── B9: create-app 불량 tag/digest 정확 문구 ───────────────────────────

@test "create-app B9: malformed tag fails with exact ::error:: message and non-zero exit" {
  run bun "$C" --config "$TMP/nope.yml" --app orders --repo ukyi-app/orders --domain example.com \
    --tag sha-xyz --digest "$NEWDIG"
  [ "$status" -ne 0 ]
  echo "$output" | grep -Fq "::error::create-app: tag 형식 불량: 'sha-xyz'"
}

@test "create-app B9: malformed digest fails with exact ::error:: message and non-zero exit" {
  run bun "$C" --config "$TMP/nope.yml" --app orders --repo ukyi-app/orders --domain example.com \
    --tag sha-aaa1111000000000000000000000000000000000 --digest sha256:nothex
  [ "$status" -ne 0 ]
  echo "$output" | grep -Fq "::error::create-app: digest 형식 불량(불변 핀 필수): 'sha256:nothex'"
}

# ─────────────────────────── B10: 형식 경계 수용/거부 + non-greedy 파싱 ───────────────────────────

@test "bump-tag B10: tag format boundary — sha-+7/40 hex accept, sha-+6/41 hex and uppercase reject" {
  seed_app_blog
  # 수용(exit 0)
  run bun "$B" blog sha-1234567 --repo-root "$TMP"
  [ "$status" -eq 0 ]
  run bun "$B" blog sha-1234567890123456789012345678901234567890 --repo-root "$TMP"
  [ "$status" -eq 0 ]
  # 거부(exit 2)
  run bun "$B" blog sha-123456 --repo-root "$TMP"
  [ "$status" -eq 2 ]
  run bun "$B" blog sha-12345678901234567890123456789012345678901 --repo-root "$TMP"
  [ "$status" -eq 2 ]
  run bun "$B" blog sha-ABCDEF1 --repo-root "$TMP"
  [ "$status" -eq 2 ]
}

@test "bump-tag B10: digest format boundary — sha256:+64 hex accept, 63/65 hex and uppercase reject" {
  seed_app_blog
  run bun "$B" blog sha-deadbee --digest "$DIG" --repo-root "$TMP"
  [ "$status" -eq 0 ]
  seed_app_blog
  run bun "$B" blog sha-deadbee --digest sha256:111111111111111111111111111111111111111111111111111111111111111 --repo-root "$TMP"
  [ "$status" -eq 2 ]
  run bun "$B" blog sha-deadbee --digest sha256:11111111111111111111111111111111111111111111111111111111111111111 --repo-root "$TMP"
  [ "$status" -eq 2 ]
  run bun "$B" blog sha-deadbee --digest sha256:AAAAcda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945 --repo-root "$TMP"
  [ "$status" -eq 2 ]
}

@test "poll-ghcr B10: inline pin non-greedy (.+?) fixes current.tag/current.digest at the :sha- boundary" {
  seed_bespoke_pin "ghcr.io/ukyi-app/files:sha-1234567@$DIG2"
  run_poll
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.[] | select(.app=="files") | .current.tag == "sha-1234567"'
  echo "$output" | jq -e --arg d "$DIG2" '.[] | select(.app=="files") | .current.digest == $d'
}

@test "bump-tag B10: inline non-greedy (.+?) preserves a colon-containing repo across the rewrite" {
  PD="$TMP/platform/files/prod"
  mkdir -p "$PD"
  cat > "$PD/.image-pin.json" <<'JSON'
{ "file": "deployment.yaml", "path": ["spec","template","spec","containers",0,"image"], "autoDeploy": true }
JSON
  cat > "$PD/deployment.yaml" <<EOF
spec:
  template:
    spec:
      containers:
        - name: files
          image: reg.io:443/ukyi-app/files:sha-0000000@$DIG2
EOF
  run bun "$B" files sha-feedbee --digest "$NEWDIG" --pin platform/files/prod/.image-pin.json --repo-root "$TMP"
  [ "$status" -eq 0 ]
  run yq '.spec.template.spec.containers[0].image' "$PD/deployment.yaml"
  [ "$output" == "reg.io:443/ukyi-app/files:sha-feedbee@$NEWDIG" ]
}
