#!/usr/bin/env bats
WF=".github/workflows/bump.yaml"

# 인-레포 앱이 없으므로(앱은 외부 레포 체제) fixture root에 임시 앱 values를 만들어 테스트한다.
setup() {
  FIX="$(mktemp -d)"
  mkdir -p "$FIX/apps/blog/deploy/prod"
  cat > "$FIX/apps/blog/deploy/prod/values.yaml" <<'EOF'
image:
  repo: ghcr.io/ukyi-app/blog
  tag: sha-0000000
kind: web
EOF
}
teardown() { rm -rf "$FIX"; }

@test "bump rewrites only image.tag in the app's values.yaml" {
  f="$FIX/apps/blog/deploy/prod/values.yaml"
  before=$(yq '.kind' "$f")
  bun tools/bump-tag.ts blog sha-deadbee --repo-root "$FIX"
  run yq '.image.tag' "$f"
  [[ "$output" == "sha-deadbee" ]]
  after=$(yq '.kind' "$f")
  [ "$before" == "$after" ] # 그 외에는 아무것도 안 바뀜
}

@test "bump is idempotent (second run is a no-op)" {
  bun tools/bump-tag.ts blog sha-deadbee --repo-root "$FIX"
  run bun tools/bump-tag.ts blog sha-deadbee --repo-root "$FIX"
  [[ "$output" == *"no-op"* || "$output" == *"unchanged"* ]]
}

DIG="sha256:4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945"

# 주의: 중간 assertion은 단순 명령 `[ ]`로 — bash 3.2의 set -e는 `[[ ]]`(compound command)
# 실패를 무시해 중간 실패가 조용히 통과한다 (macOS 기본 bash에서 검증된 함정).

@test "bump --digest records image.digest alongside the tag" {
  f="$FIX/apps/blog/deploy/prod/values.yaml"
  bun tools/bump-tag.ts blog sha-deadbee --digest "$DIG" --repo-root "$FIX"
  run yq '.image.digest' "$f"
  [ "$output" == "$DIG" ]
  # tag는 source SHA 추적용으로 함께 기록된다
  run yq '.image.tag' "$f"
  [ "$output" == "sha-deadbee" ]
}

@test "bump rejects a malformed digest with exit 2" {
  run bun tools/bump-tag.ts blog sha-deadbee --digest sha256:nothex --repo-root "$FIX"
  [ "$status" -eq 2 ]
}

@test "bump with same tag and digest is a no-op" {
  bun tools/bump-tag.ts blog sha-deadbee --digest "$DIG" --repo-root "$FIX"
  run bun tools/bump-tag.ts blog sha-deadbee --digest "$DIG" --repo-root "$FIX"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no-op"* ]]
}

@test "tag-only bump removes a stale digest (image must follow the new tag)" {
  f="$FIX/apps/blog/deploy/prod/values.yaml"
  bun tools/bump-tag.ts blog sha-deadbee --digest "$DIG" --repo-root "$FIX"
  # digest 없이 tag만 bump하면 차트 helper가 stale digest를 계속 우선하므로 digest를 제거해야 한다
  bun tools/bump-tag.ts blog sha-feedbee --repo-root "$FIX"
  run yq '.image.digest' "$f"
  [ "$output" == "null" ]
  run yq '.image.tag' "$f"
  [ "$output" == "sha-feedbee" ]
}

@test "bump refuses path traversal outside apps/" {
  run bun tools/bump-tag.ts ../../etc sha-deadbee --repo-root "$FIX"
  [ "$status" -ne 0 ]
}

@test "bump workflow joins the global homelab-mutation queue (no pending loss)" {
  # races-1/2: values-writeback는 queue:max가 없어 동시 3번째 write-back이 대기 건을 조용히 취소했다.
  # 문서화된 전역 직렬화(homelab-mutation + queue:max)에 합류시켜 인-repo bump 유실을 막는다.
  run yq '.concurrency.group' "$WF"
  [ "$output" == "homelab-mutation" ]
  run yq '.concurrency.queue' "$WF"
  [ "$output" == "max" ]
  run yq '.concurrency.cancel-in-progress' "$WF"
  [ "$output" == "false" ] # 반쯤 끝난 write-back은 절대 취소하지 않는다 (queue:max는 cancel:true와 병용 불가)
}

# ── dry-3: allowed-flag 가드 (오타 플래그가 digest 핀을 침묵 삭제하는 것 차단) ──
@test "bump rejects an unknown flag with exit 2 (typo'd --digest must not silently drop the pin)" {
  f="$FIX/apps/blog/deploy/prod/values.yaml"
  # 먼저 digest 핀을 심는다
  bun tools/bump-tag.ts blog sha-deadbee --digest "$DIG" --repo-root "$FIX"
  run yq '.image.digest' "$f"
  [ "$output" == "$DIG" ]
  # --diges 오타: 가드가 없으면 takeOpt가 못 떼어내 digest=undefined → image.digest 삭제 + exit 0
  run bun tools/bump-tag.ts blog sha-feedbee --diges "$DIG" --repo-root "$FIX"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "알 수 없는 옵션"
  # 거부됐으므로 핀은 그대로여야 한다 (격하 없음)
  run yq '.image.digest' "$f"
  [ "$output" == "$DIG" ]
}

@test "bump --expect-current aborts when current tag differs (races-4 TOCTOU)" {
  # 현재 tag는 sha-0000000 (setup fixture). 기대값을 sha-aaaaaaa로 주면 불일치 → abort
  run bun tools/bump-tag.ts blog sha-feedbee --expect-current sha-aaaaaaa --repo-root "$FIX"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "expect-current"
}

@test "bump --expect-current proceeds when current tag matches" {
  f="$FIX/apps/blog/deploy/prod/values.yaml"
  run bun tools/bump-tag.ts blog sha-feedbee --expect-current sha-0000000 --repo-root "$FIX"
  [ "$status" -eq 0 ]
  run yq '.image.tag' "$f"
  [ "$output" == "sha-feedbee" ]
}

@test "bump rejects a value-flag with no value (arity, F2 digest-pin downgrade class)" {
  # ⚠️ codex pass5 F2: --digest가 값 없이 끝에 오면 digest=undefined로 떨어져 digest 핀을 조용히 격하했다.
  # arity 파서는 값 누락을 exit 2로 거부해야 한다(핀 격하 방지).
  run bun tools/bump-tag.ts blog sha-feedbee --digest --repo-root "$FIX"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "arity"
}

@test "bump rejects a value-flag whose value is another --flag (arity)" {
  # --digest 다음이 또 다른 플래그면 값이 누락된 것 — 그 플래그를 값으로 삼키지 말고 거부.
  run bun tools/bump-tag.ts blog sha-feedbee --digest --expect-current sha-0000000 --repo-root "$FIX"
  [ "$status" -eq 2 ]
}

# ── v1 dispatch 경로 폐기 가드 (이전엔 존재를 단언 — 이제 부재를 단언) ──
@test "bump: v1 repository_dispatch path fully removed (writeback-dispatch gone)" {
  f="$WF"
  run grep -E 'repository_dispatch:|app-image|writeback-dispatch|client_payload|source-repo' "$f"
  [ "$status" -ne 0 ]
  # workflow_run write-back 경로 + digest 검증은 유지된다
  grep -qE "event_name == 'workflow_run'" "$f"
  grep -q 'docker manifest inspect' "$f"
}

# ── 인라인 핀 편집 모드(베스포크 platform 컴포넌트: deployment.yaml repo:tag@digest 단일 스칼라) ──
seed_pin() {
  mkdir -p "$FIX/platform/files/prod"
  cat > "$FIX/platform/files/prod/.image-pin.json" <<'JSON'
{ "file": "deployment.yaml", "path": ["spec","template","spec","containers",0,"image"], "autoDeploy": true }
JSON
  cat > "$FIX/platform/files/prod/deployment.yaml" <<EOF
spec:
  template:
    spec:
      containers:
        - name: files
          image: ghcr.io/ukyi-app/files:sha-0000000@$DIG # sha-0000000 + digest 인라인 핀(불변)
EOF
}
NEWDIG="sha256:1111111111111111111111111111111111111111111111111111111111111111"

@test "bump --pin edits the inline repo:tag@digest scalar in a bespoke deployment.yaml" {
  seed_pin
  f="$FIX/platform/files/prod/deployment.yaml"
  run bun tools/bump-tag.ts files sha-feedbee --digest "$NEWDIG" --pin platform/files/prod/.image-pin.json --repo-root "$FIX"
  [ "$status" -eq 0 ]
  run yq '.spec.template.spec.containers[0].image' "$f"
  [ "$output" == "ghcr.io/ukyi-app/files:sha-feedbee@$NEWDIG" ]
}

@test "bump --pin without --digest is refused (bespoke pins are always digest-pinned)" {
  seed_pin
  run bun tools/bump-tag.ts files sha-feedbee --pin platform/files/prod/.image-pin.json --repo-root "$FIX"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "인라인 핀 모드는 --digest 필수"
}

@test "bump --pin --expect-current aborts on a tag mismatch (TOCTOU, exit 3)" {
  seed_pin
  run bun tools/bump-tag.ts files sha-feedbee --digest "$NEWDIG" --expect-current sha-aaaaaaa --pin platform/files/prod/.image-pin.json --repo-root "$FIX"
  [ "$status" -eq 3 ]
  echo "$output" | grep -q "expect-current"
}

@test "bump --pin is idempotent (same tag+digest is a no-op)" {
  seed_pin
  bun tools/bump-tag.ts files sha-feedbee --digest "$NEWDIG" --pin platform/files/prod/.image-pin.json --repo-root "$FIX"
  run bun tools/bump-tag.ts files sha-feedbee --digest "$NEWDIG" --pin platform/files/prod/.image-pin.json --repo-root "$FIX"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no-op"* ]]
}

@test "bump --pin refuses a descriptor outside platform/ (path traversal guard)" {
  seed_pin
  run bun tools/bump-tag.ts files sha-feedbee --digest "$NEWDIG" --pin ../outside.json --repo-root "$FIX"
  [ "$status" -eq 2 ]
}

# ── digest-exporter APPS 신선도 동기(codex pass2 P2-2): bump 시 같은 앱의 APPS 태그도 함께 갱신 ──
# APPS는 "name=ghcr.io/owner/name:tag" 공백 구분 목록. sha-* 태그 불변이라 배포 핀만 갱신하면
# digest-exporter가 stale 참조로 거짓 ImageDigestDrift(B2)를 낸다 — bump-tag가 같은 커밋에서 동기.
seed_exporter() {  # $1 = APPS value 문자열
  mkdir -p "$FIX/platform/victoria-stack/prod"
  cat > "$FIX/platform/victoria-stack/prod/digest-exporter.yaml" <<EOF
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

@test "bump also refreshes the digest-exporter APPS tag for an app already listed" {
  seed_exporter "blog=ghcr.io/ukyi-app/blog:sha-0000000 page=ghcr.io/ukyi-app/page:sha-cd4815ca409992f56bf72d324d0806acb97010e2"
  bun tools/bump-tag.ts blog sha-deadbee --digest "$DIG" --repo-root "$FIX"
  ex="$FIX/platform/victoria-stack/prod/digest-exporter.yaml"
  # 배포 핀(values.yaml)과 APPS 태그가 같은 값으로 동시 갱신
  run yq '.image.tag' "$FIX/apps/blog/deploy/prod/values.yaml"
  [ "$output" == "sha-deadbee" ]
  run grep -c "blog=ghcr.io/ukyi-app/blog:sha-deadbee" "$ex"
  [ "$output" -eq 1 ]
  # page 항목은 불변(교차 오염 없음)
  run grep -c "page=ghcr.io/ukyi-app/page:sha-cd4815ca409992f56bf72d324d0806acb97010e2" "$ex"
  [ "$output" -eq 1 ]
}

@test "bump leaves the digest-exporter byte-identical for an app not listed in APPS" {
  seed_exporter "page=ghcr.io/ukyi-app/page:sha-cd4815ca409992f56bf72d324d0806acb97010e2"
  ex="$FIX/platform/victoria-stack/prod/digest-exporter.yaml"
  before=$(shasum "$ex" | awk '{print $1}')
  bun tools/bump-tag.ts blog sha-deadbee --digest "$DIG" --repo-root "$FIX"
  after=$(shasum "$ex" | awk '{print $1}')
  [ "$before" == "$after" ]
}
