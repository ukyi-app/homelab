#!/usr/bin/env bats
# bump 계약 module(tools/lib/bump-plan.ts, lib-convergence d3)의 계약 테스트.
# plan 항목은 런타임 디코드 판별 union(Change|Noop|Refusal — Lane은 Change 전용, design r1-1),
# target은 판별 신원 {kind: app|bespoke, name}(r1-2 — 두 레인의 인가 소스 분리를 interface가 보존),
# 명명(브랜치·커밋 문구·writer 신원)과 레인 인가 해소(resolveLane·laneFor)를 이 module이 소유한다.
# 08(design r2-1): 브랜치가 kind를 인코딩하고(branchFor), 역디코딩(parseBranch)·레거시 이행 판정
# (legacyAmbiguity — 동명 bespoke 실재 = 구형 브랜치의 app 해석 fail-closed)도 같은 module이 소유한다.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과. @test 이름은 영어(CJK 함정).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  FX="$BATS_TEST_TMPDIR/p.ts"
  # ⚠️ heredoc 비인용(EOF) — $ROOT 확장 필요. TS 본문은 ${} 템플릿 리터럴을 쓰지 않는다.
  cat > "$FX" <<EOF
import { decodePlan, encodePlan, branchFor, parseBranch, legacyAmbiguity, commitMessage, resolveLane, laneFor, WRITER_NAME, WRITER_EMAIL } from "$ROOT/tools/lib/bump-plan.ts";
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
  // 08: 와이어 호환 app 필드는 사라졌다 — 신원은 target 하나로만 흐른다.
  console.log("k1=" + back[1].target.kind + " wire-app=" + typeof JSON.parse(encodePlan(items as never))[0].app);
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
} else if (mode === "pinlessbespoke") {
  try {
    decodePlan(JSON.stringify([{ action: "bump", target: { kind: "bespoke", name: "files" }, reason: "", current: { tag: "sha-a", digest: "d" },
      candidate: { gitsha: "b", tag: "sha-b", digest: "d2" }, src: "ukyi-app/files", writePath: "platform/files/prod/deployment.yaml" }]));
  } catch (e) { console.error("E " + (e as Error).message); process.exit(1); }
} else if (mode === "pinnedapp") {
  try {
    decodePlan(JSON.stringify([{ action: "bump", target: t, reason: "", current: { tag: "sha-a", digest: "d" },
      candidate: { gitsha: "b", tag: "sha-b", digest: "d2" }, src: "ukyi-app/demo", writePath: "apps/demo/deploy/prod/values.yaml",
      pin: "platform/demo/prod/.image-pin.json" }]));
  } catch (e) { console.error("E " + (e as Error).message); process.exit(1); }
} else if (mode === "naming") {
  console.log(branchFor(t, "sha-abc1234"));
  console.log(branchFor({ kind: "bespoke", name: "files" }, "sha-abc1234"));
  console.log(commitMessage(t, "sha-abc1234"));
  console.log(WRITER_NAME + " / " + WRITER_EMAIL);
} else if (mode === "parse") {
  // 왕복: branchFor 산출을 parseBranch가 복원한다 — kind·이름·tag 전부(레거시 아님).
  const cases = [t, { kind: "bespoke", name: "files" }, { kind: "app", name: "x-sha-abc1234" }] as const;
  for (const c of cases) {
    const p = parseBranch(branchFor(c, "sha-abc1234"));
    if (p === null) { console.log("rt=null"); continue; }
    console.log("rt=" + p.target.kind + "/" + p.target.name + "@" + p.tag + " legacy=" + p.legacy);
  }
  // 레거시(구형 무한정 브랜치): app으로만 해석하고 legacy 표식을 단다.
  const l = parseBranch("bump-poll/demo-sha-abc1234");
  console.log("legacy=" + (l === null ? "null" : l.target.kind + "/" + l.target.name + "@" + l.tag + " legacy=" + l.legacy));
  // 우리 문법이 아닌 것들 — 전부 null(관용 해석 금지: 잘못 읽으면 남의 ref를 소유했다고 믿는다).
  for (const b of ["bump-poll/junk/x-sha-abc1234", "bump-poll/app/x", "bump-poll/app/UPPER-sha-abc1234", "other/x-sha-abc1234", "bump-poll/x-sha-zzz"]) {
    console.log("bad=" + String(parseBranch(b)));
  }
} else if (mode === "legacy") {
  console.log("amb=" + String(legacyAmbiguity(process.env.PX_ROOT ?? ".", process.env.PX_NAME ?? "demo")));
} else if (mode === "lanefor") {
  const kind = (process.env.PX_KIND ?? "app") as "app" | "bespoke";
  const p = laneFor(process.env.PX_ROOT ?? ".", { kind: kind, name: process.env.PX_NAME ?? "demo" });
  console.log("kind=" + (p.target ? p.target.kind : "none") + " lane=" + p.lane + " res=" + p.resolution);
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
  # 08: 와이어에 app 필드가 더 이상 실리지 않는다(구 소비자가 전부 target으로 이관 완료).
  echo "$output" | grep -q '^k1=bespoke wire-app=undefined$'
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

@test "a bespoke Lane item without pin is rejected (the runner would fall into apps mode)" {
  # 러너는 pin 유무로 bump-tag 모드를 가른다 — bespoke 항목이 pin 없이 통과하면 apps 경로를 편집하려 든다.
  PX_MODE=pinlessbespoke run bun "$FX"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'pin'
}

@test "an app Lane item carrying pin is rejected (kind and pin must cohere)" {
  PX_MODE=pinnedapp run bun "$FX"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'pin'
}

@test "the naming contract encodes kind into the branch and keeps the commit message byte-identical" {
  # 커밋 문구·writer 신원은 03의 라이브 문자열 그대로(레거시 브랜치의 소유 증명이 계속 성립해야 한다).
  # 브랜치만 08에서 kind 세그먼트를 얻는다 — 동명 app/bespoke가 브랜치를 공유하지 못하게(design r2-1).
  PX_MODE=naming run bun "$FX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^bump-poll/app/demo-sha-abc1234$'
  echo "$output" | grep -q '^bump-poll/bespoke/files-sha-abc1234$'
  echo "$output" | grep -q '^chore: demo 이미지를 sha-abc1234(digest 핀)로 갱신 (GHCR 폴링)$'
  echo "$output" | grep -q '^ukyi-homelab-writer\[bot\] / 293311924+ukyi-homelab-writer\[bot\]@users.noreply.github.com$'
}

@test "parseBranch restores what branchFor encodes, reads legacy names as app, and rejects foreign grammar" {
  PX_MODE=parse run bun "$FX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^rt=app/demo@sha-abc1234 legacy=false$'
  echo "$output" | grep -q '^rt=bespoke/files@sha-abc1234 legacy=false$'
  # 앱 이름이 tag 모양을 품어도(x-sha-abc1234) 마지막 -sha- 분기점 하나로 정확히 갈린다.
  echo "$output" | grep -q '^rt=app/x-sha-abc1234@sha-abc1234 legacy=false$'
  echo "$output" | grep -q '^legacy=app/demo@sha-abc1234 legacy=true$'
  n="$(echo "$output" | grep -c '^bad=null$')"
  [ "$n" = "5" ]
}

@test "legacyAmbiguity flags a legacy name shadowed by a bespoke surface (app reading would be a lie)" {
  R="$BATS_TEST_TMPDIR/l1"; mkdir -p "$R/platform/files/prod" "$R/apps"
  printf '{ "file": "deployment.yaml", "path": ["a"], "autoDeploy": false }' > "$R/platform/files/prod/.image-pin.json"
  PX_MODE=legacy PX_ROOT="$R" PX_NAME=files run bun "$FX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^amb=.*bespoke'
  # 동명 bespoke가 없으면 구형 이름의 app 해석은 유효하다 — null(이행 소음 0).
  PX_MODE=legacy PX_ROOT="$R" PX_NAME=demo run bun "$FX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^amb=null$'
}

@test "laneFor reads only the target kind's SSOT (same-name surfaces stay separated by identity)" {
  # 동명 app/bespoke가 **둘 다** 실재해도, kind가 확정된 target은 자기 인가 소스만 본다(08 e2e의 축).
  R="$BATS_TEST_TMPDIR/f1"; mkdir -p "$R/apps/files/deploy/prod" "$R/platform/files/prod"
  printf '{ "autoDeploy": true }' > "$R/apps/files/deploy/prod/.bindings.json"
  printf '{ "file": "deployment.yaml", "path": ["a"], "autoDeploy": false }' > "$R/platform/files/prod/.image-pin.json"
  PX_MODE=lanefor PX_KIND=app PX_ROOT="$R" PX_NAME=files run bun "$FX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^kind=app lane=bump res=present$'
  PX_MODE=lanefor PX_KIND=bespoke PX_ROOT="$R" PX_NAME=files run bun "$FX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^kind=bespoke lane=propose-pr res=present$'
}

@test "laneFor never borrows the other kind's surface (absent means absent for THIS kind)" {
  R="$BATS_TEST_TMPDIR/f2"; mkdir -p "$R/apps/demo/deploy/prod"
  printf '{ "autoDeploy": true }' > "$R/apps/demo/deploy/prod/.bindings.json"
  PX_MODE=lanefor PX_KIND=bespoke PX_ROOT="$R" PX_NAME=demo run bun "$FX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^kind=bespoke lane=propose-pr res=absent$'
}

@test "laneFor folds an unreadable SSOT to propose-pr and says so" {
  R="$BATS_TEST_TMPDIR/f3"; mkdir -p "$R/platform/files/prod"
  printf '{ broken' > "$R/platform/files/prod/.image-pin.json"
  PX_MODE=lanefor PX_KIND=bespoke PX_ROOT="$R" PX_NAME=files run bun "$FX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^kind=bespoke lane=propose-pr res=unreadable$'
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
  # (kind 미확정 진입점의 어휘다 — kind가 확정된 소비자는 laneFor로 자기 SSOT만 본다.)
  R="$BATS_TEST_TMPDIR/r5"; mkdir -p "$R/apps/files/deploy/prod" "$R/platform/files/prod"
  printf '{ "autoDeploy": true }' > "$R/apps/files/deploy/prod/.bindings.json"
  printf '{ "file": "deployment.yaml", "path": ["a"], "autoDeploy": true }' > "$R/platform/files/prod/.image-pin.json"
  PX_MODE=lane PX_ROOT="$R" PX_NAME=files run bun "$FX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^kind=none lane=propose-pr res=conflict$'
}
