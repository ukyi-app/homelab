#!/usr/bin/env bats
# bump 계약 module(tools/lib/bump-plan.ts, lib-convergence d3)의 계약 테스트.
# plan 항목은 런타임 디코드 판별 union(Change|Noop|Refusal — Lane은 Change 전용, design r1-1),
# target은 판별 신원 {kind: app|bespoke, name}(r1-2 — 두 레인의 인가 소스 분리를 interface가 보존),
# 명명(브랜치·커밋 문구·writer 신원)과 레인 인가 해소(resolveLane)를 이 module이 소유한다.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과. @test 이름은 영어(CJK 함정).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  FX="$BATS_TEST_TMPDIR/p.ts"
  # ⚠️ heredoc 비인용(EOF) — $ROOT 확장 필요. TS 본문은 ${} 템플릿 리터럴을 쓰지 않는다.
  cat > "$FX" <<EOF
import { decodePlan, encodePlan, branchFor, commitMessage, resolveLane, WRITER_NAME, WRITER_EMAIL } from "$ROOT/tools/lib/bump-plan.ts";
const mode = process.env.PX_MODE ?? "";
const t = { kind: "app", name: "demo" } as const;
if (mode === "roundtrip") {
  const items = [
    { action: "noop", target: t, reason: "배포 SHA == main tip", current: { tag: "sha-a", digest: "d" } },
    { action: "refuse", target: { kind: "bespoke", name: "files" }, reason: "조상 아님", current: null },
    { action: "bump", target: t, reason: "", current: { tag: "sha-a", digest: "d1" },
      candidate: { gitsha: "b", tag: "sha-b", digest: "d2" }, src: "ukyi-app/demo", writePath: "apps/demo/deploy/prod/values.yaml" },
  ];
  const back = decodePlan(encodePlan(items as never));
  console.log("n=" + back.length);
  console.log("a0=" + back[0].action + " a1=" + back[1].action + " a2=" + back[2].action);
  console.log("k1=" + back[1].target.kind + " wire-app=" + JSON.parse(encodePlan(items as never))[0].app);
} else if (mode === "appsplit") {
  try { decodePlan(JSON.stringify([{ app: "orders", action: "noop", target: { kind: "bespoke", name: "files" }, reason: "", current: null }])); }
  catch (e) { console.error("E " + (e as Error).message); process.exit(1); }
} else if (mode === "badaction") {
  try { decodePlan(JSON.stringify([{ action: "yolo", target: t, reason: "", current: null }])); }
  catch (e) { console.error("E " + (e as Error).message); process.exit(1); }
} else if (mode === "badkind") {
  try { decodePlan(JSON.stringify([{ action: "noop", target: { kind: "platformish", name: "x" }, reason: "", current: null }])); }
  catch (e) { console.error("E " + (e as Error).message); process.exit(1); }
} else if (mode === "lanefields") {
  try { decodePlan(JSON.stringify([{ action: "bump", target: t, reason: "", current: { tag: "sha-a", digest: null } }])); }
  catch (e) { console.error("E " + (e as Error).message); process.exit(1); }
} else if (mode === "naming") {
  console.log(branchFor(t, "sha-abc"));
  console.log(commitMessage(t, "sha-abc"));
  console.log(WRITER_NAME + " / " + WRITER_EMAIL);
} else if (mode === "lane") {
  const p = resolveLane(process.env.PX_ROOT ?? ".", process.env.PX_NAME ?? "demo");
  console.log("kind=" + (p.target ? p.target.kind : "none") + " lane=" + p.lane + " res=" + p.resolution);
}
EOF
}

@test "noop and refuse survive the decode roundtrip (no lane collapse)" {
  PX_MODE=roundtrip run bun "$FX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^n=3$'
  echo "$output" | grep -q '^a0=noop a1=refuse a2=bump$'
  # 와이어 호환: 구 소비자(run-bump-plan)가 읽는 app 필드를 함께 싣는다(08 전까지의 계약).
  echo "$output" | grep -q '^k1=bespoke wire-app=demo$'
}

@test "a wire app field that disagrees with target.name is rejected (identity split cannot ride the wire)" {
  PX_MODE=appsplit run bun "$FX"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q "orders"
  echo "$output" | grep -q "갈린다"
}

@test "an unknown action is a fail-closed decode error, not a silent skip" {
  PX_MODE=badaction run bun "$FX"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'yolo'
}

@test "an unknown target kind is rejected (identity is a closed discriminant)" {
  PX_MODE=badkind run bun "$FX"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'platformish'
}

@test "an actionable item without candidate or writePath is rejected (Lane needs its evidence)" {
  PX_MODE=lanefields run bun "$FX"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'candidate\|writePath'
}

@test "the naming contract matches the live strings byte for byte" {
  # 이 문자열들이 곧 소유 증명 계약이다 — 소비자(run-bump-plan·ensure-bump-pr)가 08에서 이관해도
  # 동작이 변하지 않으려면 module이 오늘의 문자열을 그대로 소유해야 한다.
  PX_MODE=naming run bun "$FX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^bump-poll/demo-sha-abc$'
  echo "$output" | grep -q '^chore: demo 이미지를 sha-abc(digest 핀)로 갱신 (GHCR 폴링)$'
  echo "$output" | grep -q '^ukyi-homelab-writer\[bot\] / 293311924+ukyi-homelab-writer\[bot\]@users.noreply.github.com$'
}

@test "resolveLane reads the app lane from .bindings.json and folds autoDeploy into the lane" {
  R="$BATS_TEST_TMPDIR/r1"; mkdir -p "$R/apps/demo/deploy/prod"
  printf '{ "autoDeploy": true }' > "$R/apps/demo/deploy/prod/.bindings.json"
  PX_MODE=lane PX_ROOT="$R" PX_NAME=demo run bun "$FX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^kind=app lane=bump res=present$'
}

@test "resolveLane reads the bespoke lane from .image-pin.json (autoDeploy false folds to propose-pr)" {
  R="$BATS_TEST_TMPDIR/r2"; mkdir -p "$R/platform/files/prod"
  printf '{ "file": "deployment.yaml", "path": ["a"], "autoDeploy": false }' > "$R/platform/files/prod/.image-pin.json"
  PX_MODE=lane PX_ROOT="$R" PX_NAME=files run bun "$FX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^kind=bespoke lane=propose-pr res=present$'
}

@test "resolveLane folds an absent SSOT to propose-pr (planner contract: absence is not authorization)" {
  R="$BATS_TEST_TMPDIR/r3"; mkdir -p "$R/apps"
  PX_MODE=lane PX_ROOT="$R" PX_NAME=ghost run bun "$FX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^kind=none lane=propose-pr res=absent$'
}

@test "resolveLane folds an unreadable SSOT to propose-pr and says so" {
  R="$BATS_TEST_TMPDIR/r4"; mkdir -p "$R/apps/demo/deploy/prod"
  printf '{ broken' > "$R/apps/demo/deploy/prod/.bindings.json"
  PX_MODE=lane PX_ROOT="$R" PX_NAME=demo run bun "$FX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^kind=app lane=propose-pr res=unreadable$'
}

@test "a same-name app and bespoke target is a conflict that never authorizes (fail-closed)" {
  # r1-2의 사고 경로 — 동명 충돌이 다른 target의 autoDeploy를 적용해 승인 요구 PR을 자동 arm하는 것.
  R="$BATS_TEST_TMPDIR/r5"; mkdir -p "$R/apps/files/deploy/prod" "$R/platform/files/prod"
  printf '{ "autoDeploy": true }' > "$R/apps/files/deploy/prod/.bindings.json"
  printf '{ "file": "deployment.yaml", "path": ["a"], "autoDeploy": true }' > "$R/platform/files/prod/.image-pin.json"
  PX_MODE=lane PX_ROOT="$R" PX_NAME=files run bun "$FX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^kind=none lane=propose-pr res=conflict$'
}
