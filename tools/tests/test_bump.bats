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
kind: service
EOF
}
teardown() { rm -rf "$FIX"; }

@test "bump rewrites only image.tag in the app's values.yaml" {
  f="$FIX/apps/blog/deploy/prod/values.yaml"
  before=$(yq '.kind' "$f")
  node tools/bump-tag.mjs blog sha-deadbee --repo-root "$FIX"
  run yq '.image.tag' "$f"
  [[ "$output" == "sha-deadbee" ]]
  after=$(yq '.kind' "$f")
  [ "$before" == "$after" ] # 그 외에는 아무것도 안 바뀜
}

@test "bump is idempotent (second run is a no-op)" {
  node tools/bump-tag.mjs blog sha-deadbee --repo-root "$FIX"
  run node tools/bump-tag.mjs blog sha-deadbee --repo-root "$FIX"
  [[ "$output" == *"no-op"* || "$output" == *"unchanged"* ]]
}

DIG="sha256:4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945"

# 주의: 중간 assertion은 단순 명령 `[ ]`로 — bash 3.2의 set -e는 `[[ ]]`(compound command)
# 실패를 무시해 중간 실패가 조용히 통과한다 (macOS 기본 bash에서 검증된 함정).

@test "bump --digest records image.digest alongside the tag" {
  f="$FIX/apps/blog/deploy/prod/values.yaml"
  node tools/bump-tag.mjs blog sha-deadbee --digest "$DIG" --repo-root "$FIX"
  run yq '.image.digest' "$f"
  [ "$output" == "$DIG" ]
  # tag는 source SHA 추적용으로 함께 기록된다
  run yq '.image.tag' "$f"
  [ "$output" == "sha-deadbee" ]
}

@test "bump rejects a malformed digest with exit 2" {
  run node tools/bump-tag.mjs blog sha-deadbee --digest sha256:nothex --repo-root "$FIX"
  [ "$status" -eq 2 ]
}

@test "bump with same tag and digest is a no-op" {
  node tools/bump-tag.mjs blog sha-deadbee --digest "$DIG" --repo-root "$FIX"
  run node tools/bump-tag.mjs blog sha-deadbee --digest "$DIG" --repo-root "$FIX"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no-op"* ]]
}

@test "tag-only bump removes a stale digest (image must follow the new tag)" {
  f="$FIX/apps/blog/deploy/prod/values.yaml"
  node tools/bump-tag.mjs blog sha-deadbee --digest "$DIG" --repo-root "$FIX"
  # digest 없이 tag만 bump하면 차트 helper가 stale digest를 계속 우선하므로 digest를 제거해야 한다
  node tools/bump-tag.mjs blog sha-feedbee --repo-root "$FIX"
  run yq '.image.digest' "$f"
  [ "$output" == "null" ]
  run yq '.image.tag' "$f"
  [ "$output" == "sha-feedbee" ]
}

@test "bump refuses path traversal outside apps/" {
  run node tools/bump-tag.mjs ../../etc sha-deadbee --repo-root "$FIX"
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
  node tools/bump-tag.mjs blog sha-deadbee --digest "$DIG" --repo-root "$FIX"
  run yq '.image.digest' "$f"
  [ "$output" == "$DIG" ]
  # --diges 오타: 가드가 없으면 takeOpt가 못 떼어내 digest=undefined → image.digest 삭제 + exit 0
  run node tools/bump-tag.mjs blog sha-feedbee --diges "$DIG" --repo-root "$FIX"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "알 수 없는 옵션"
  # 거부됐으므로 핀은 그대로여야 한다 (격하 없음)
  run yq '.image.digest' "$f"
  [ "$output" == "$DIG" ]
}

@test "bump --expect-current aborts when current tag differs (races-4 TOCTOU)" {
  # 현재 tag는 sha-0000000 (setup fixture). 기대값을 sha-aaaaaaa로 주면 불일치 → abort
  run node tools/bump-tag.mjs blog sha-feedbee --expect-current sha-aaaaaaa --repo-root "$FIX"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "expect-current"
}

@test "bump --expect-current proceeds when current tag matches" {
  f="$FIX/apps/blog/deploy/prod/values.yaml"
  run node tools/bump-tag.mjs blog sha-feedbee --expect-current sha-0000000 --repo-root "$FIX"
  [ "$status" -eq 0 ]
  run yq '.image.tag' "$f"
  [ "$output" == "sha-feedbee" ]
}

@test "bump rejects a value-flag with no value (arity, F2 digest-pin downgrade class)" {
  # ⚠️ codex pass5 F2: --digest가 값 없이 끝에 오면 digest=undefined로 떨어져 digest 핀을 조용히 격하했다.
  # arity 파서는 값 누락을 exit 2로 거부해야 한다(핀 격하 방지).
  run node tools/bump-tag.mjs blog sha-feedbee --digest --repo-root "$FIX"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "arity"
}

@test "bump rejects a value-flag whose value is another --flag (arity)" {
  # --digest 다음이 또 다른 플래그면 값이 누락된 것 — 그 플래그를 값으로 삼키지 말고 거부.
  run node tools/bump-tag.mjs blog sha-feedbee --digest --expect-current sha-0000000 --repo-root "$FIX"
  [ "$status" -eq 2 ]
}

# ── bump.yaml 워크플로 보안 불변식 (test_onboard.bats에서 이관 — v1 폐기 전 보존) ──
@test "bump: dispatch path shares serial group; legacy job scoped to workflow_run" {
  f="$WF"
  grep -q 'repository_dispatch' "$f"
  grep -q 'app-image' "$f"
  grep -qE "event_name == 'workflow_run'" "$f"
  grep -qE "event_name == 'repository_dispatch'" "$f"
  # 직렬 그룹은 하나만 (양 경로 공유) — Phase 6 races-1/2로 전역 homelab-mutation 큐에 합류
  [ "$(grep -c 'group: homelab-mutation' "$f")" -eq 1 ]
}

@test "bump dispatch: untrusted payload env-only + source-repo binding + digest verify" {
  f="$WF"
  grep -q 'source-repo' "$f"
  grep -q 'docker manifest inspect' "$f"
  # client_payload 참조는 env 할당(APP:/TAG:/SRC:) 또는 주석에만 등장해야 한다 — run 인라인 보간 금지
  # (BSD grep은 \s 미지원 — POSIX [[:space:]] 사용)
  bad=$(grep -n 'client_payload' "$f" | grep -vE '^[0-9]+:[[:space:]]*(#|(APP|TAG|SRC):)' || true)
  [ -z "$bad" ]
}
