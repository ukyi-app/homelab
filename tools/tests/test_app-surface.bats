#!/usr/bin/env bats
# 앱 표면 module(tools/lib/app-surface.ts, lib-convergence d4)의 계약 테스트.
# "앱은 어떤 파일들로 이루어지는가"의 유일 선언 — 경로 SSOT(appRel/appPaths) + 읽기/쓰기/제거 함수 API.
# 집합 동일성 단언(기록 목록 ↔ 디스크 실측)의 이빨은 writeAppSurface **본문**이다: 거기서 쓰고 목록에
# 안 올리면(또는 반대) red. 철거 대칭은 removeAppSurface의 디렉토리 통째 rm이 구조로 보장한다.
# autoDeploy 값 해석은 descriptorAutoDeploy(image-pin) 하나를 재사용한다.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과. @test 이름은 영어(CJK 함정).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  FX="$BATS_TEST_TMPDIR/s.ts"
  # ⚠️ heredoc 비인용(EOF) — $ROOT 확장 필요. TS 본문은 ${} 템플릿 리터럴을 쓰지 않는다.
  cat > "$FX" <<EOF
import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import path from "node:path";
import { appRel, appPaths, readAppSurface, writeAppSurface, removeAppSurface } from "$ROOT/tools/lib/app-surface.ts";
const mode = process.env.PX_MODE ?? "";
const root = process.env.PX_ROOT ?? ".";
const app = process.env.PX_NAME ?? "demo";
function walk(dir) {
  const out = [];
  for (const e of readdirSync(dir)) {
    const p = path.join(dir, e);
    if (statSync(p).isDirectory()) out.push(...walk(p));
    else out.push(p);
  }
  return out;
}
if (mode === "rel") {
  const r = appRel(app);
  console.log("dir=" + r.dir);
  console.log("prod=" + r.prod);
  console.log("values=" + r.values);
  console.log("sourceRepo=" + r.sourceRepo);
  console.log("bindings=" + r.bindings);
  console.log("kustomization=" + r.kustomization);
  console.log("activation=" + r.activation);
  console.log("sealed=" + r.sealed("demo-secrets.sealed.yaml"));
  const a = appPaths("/r", app);
  console.log("abs=" + a.values);
} else if (mode === "write-full") {
  const written = writeAppSurface(root, app, {
    values: { image: { repo: "ghcr.io/ukyi-app/demo", tag: "sha-0000000" }, kind: "web" },
    sourceRepo: "ukyi-app/demo",
    bindings: { autoDeploy: true },
    sealed: { file: "demo-secrets.sealed.yaml", bytes: "sealed-bytes\n" },
    // 콜백형 — 다른 표면 **기록 후** 평가된다(마커 해시가 디스크 실측이어야 하는 create-app 계약).
    // 평가 시점의 values 실재 여부를 마커에 실어 그 순서를 직접 잰다.
    activation: () => ({ app: "demo", valuesOnDisk: existsSync(appPaths(root, app).values) }),
  });
  console.log("written=" + written.sort().join(","));
  console.log("marker-values-on-disk=" + String(JSON.parse(readFileSync(appPaths(root, app).activation, "utf8")).valuesOnDisk));
  // 실측: 디스크에 생긴 파일 집합 == 선언된 표면 집합(한쪽에만 추가하면 여기서 갈린다)
  const actual = walk(appPaths(root, app).dir).map((p) => path.relative(root, p)).sort();
  console.log("actual=" + actual.join(","));
} else if (mode === "write-min") {
  // 선택 표면(sealed·activation) 없는 최소형 — kustomization은 sealed 유무와 무관하게 항상 실재
  // (appset kustomize 렌더 전제)하고, resources는 sealed 있을 때만 실린다.
  const written = writeAppSurface(root, app, {
    values: { kind: "worker" },
    sourceRepo: "ukyi-app/demo",
    bindings: { autoDeploy: false },
  });
  console.log("written=" + written.sort().join(","));
  console.log("kust-has-resources=" + String(readFileSync(appPaths(root, app).kustomization, "utf8").includes("resources")));
} else if (mode === "remove") {
  writeAppSurface(root, app, {
    values: { kind: "web" }, sourceRepo: "ukyi-app/demo", bindings: { autoDeploy: true },
    sealed: { file: "demo-secrets.sealed.yaml", bytes: "b\n" }, activation: { app: "demo" },
  });
  const removed = removeAppSurface(root, app);
  const again = removeAppSurface(root, app); // 멱등 — 이미 없어도 조용
  console.log("removed=" + removed + " again=" + again);
  console.log("exists=" + String(existsSync(appPaths(root, app).dir)));
} else if (mode === "read") {
  const s = readAppSurface(root, app);
  console.log("tag=" + String((s.values as any)?.image?.tag ?? null));
  console.log("autoDeploy=" + String(s.autoDeploy));
  console.log("sourceRepo=" + String(s.sourceRepo));
}
EOF
}

@test "appRel and appPaths declare the app surface paths from one source (rel is the wire form)" {
  PX_MODE=rel PX_NAME=demo run bun "$FX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^dir=apps/demo$'
  echo "$output" | grep -q '^prod=apps/demo/deploy/prod$'
  echo "$output" | grep -q '^values=apps/demo/deploy/prod/values.yaml$'
  echo "$output" | grep -q '^sourceRepo=apps/demo/deploy/prod/source-repo$'
  echo "$output" | grep -q '^bindings=apps/demo/deploy/prod/.bindings.json$'
  echo "$output" | grep -q '^kustomization=apps/demo/deploy/prod/kustomization.yaml$'
  echo "$output" | grep -q '^activation=apps/demo/deploy/prod/.activation$'
  echo "$output" | grep -q '^sealed=apps/demo/deploy/prod/demo-secrets.sealed.yaml$'
  echo "$output" | grep -q '^abs=/r/apps/demo/deploy/prod/values.yaml$'
}

@test "writeAppSurface writes exactly the declared surface set (adding a file only to write goes red here)" {
  R="$BATS_TEST_TMPDIR/w1"; mkdir -p "$R"
  PX_MODE=write-full PX_ROOT="$R" PX_NAME=demo run bun "$FX"
  [ "$status" -eq 0 ]
  # 기록 목록 == 실측 디스크 목록 — 같은 실행의 두 관측이 글자 그대로 같아야 한다(집합 동일성).
  w="$(echo "$output" | sed -n 's/^written=//p')"
  a="$(echo "$output" | sed -n 's/^actual=//p')"
  [ -n "$w" ]
  [ "$w" = "$a" ]
  # 전 표면(선택 포함) 실재 — values·source-repo·bindings·kustomization·sealed·activation.
  echo "$w" | grep -q 'apps/demo/deploy/prod/values.yaml'
  echo "$w" | grep -q 'apps/demo/deploy/prod/source-repo'
  echo "$w" | grep -q 'apps/demo/deploy/prod/.bindings.json'
  echo "$w" | grep -q 'apps/demo/deploy/prod/kustomization.yaml'
  echo "$w" | grep -q 'apps/demo/deploy/prod/demo-secrets.sealed.yaml'
  echo "$w" | grep -q 'apps/demo/deploy/prod/.activation'
  # 콜백은 다른 표면 기록 **뒤**에 평가됐다 — 평가 시점에 values가 이미 디스크에 있었다.
  echo "$output" | grep -q '^marker-values-on-disk=true$'
}

@test "the minimal surface still carries kustomization (kustomize render precondition) without sealed resources" {
  R="$BATS_TEST_TMPDIR/w2"; mkdir -p "$R"
  PX_MODE=write-min PX_ROOT="$R" PX_NAME=demo run bun "$FX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'apps/demo/deploy/prod/kustomization.yaml'
  echo "$output" | grep -q '^kust-has-resources=false$'
  w="$(echo "$output" | sed -n 's/^written=//p')"
  [ -n "$w" ]   # 라벨 드리프트로 빈 문자열이 되면 아래 0-카운트가 무조건 통과한다(fail-open 봉쇄)
  run grep -c 'sealed' <<<"$w"
  [ "$output" = "0" ]
}

@test "removeAppSurface removes the whole app dir and is idempotent (create set == teardown set)" {
  R="$BATS_TEST_TMPDIR/r1"; mkdir -p "$R"
  PX_MODE=remove PX_ROOT="$R" PX_NAME=demo run bun "$FX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^removed=true again=false$'
  echo "$output" | grep -q '^exists=false$'
}

@test "readAppSurface folds absence to null and resolves autoDeploy via the one interpreter (exact boolean true)" {
  R="$BATS_TEST_TMPDIR/r2"; mkdir -p "$R/apps/demo/deploy/prod"
  printf 'image:\n  tag: sha-1234567\n' > "$R/apps/demo/deploy/prod/values.yaml"
  printf '{ "autoDeploy": "yes" }' > "$R/apps/demo/deploy/prod/.bindings.json"
  printf 'ukyi-app/demo\n' > "$R/apps/demo/deploy/prod/source-repo"
  PX_MODE=read PX_ROOT="$R" PX_NAME=demo run bun "$FX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^tag=sha-1234567$'
  # 값 해석은 descriptorAutoDeploy 하나 — 정확히 boolean true만 true("yes"는 false로 접힌다).
  echo "$output" | grep -q '^autoDeploy=false$'
  echo "$output" | grep -q '^sourceRepo=ukyi-app/demo$'
}

@test "readAppSurface reports a missing or broken bindings file as null (absence, not a value)" {
  R="$BATS_TEST_TMPDIR/r3"; mkdir -p "$R/apps/demo/deploy/prod"
  printf '{ broken' > "$R/apps/demo/deploy/prod/.bindings.json"
  PX_MODE=read PX_ROOT="$R" PX_NAME=demo run bun "$FX"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^tag=null$'
  echo "$output" | grep -q '^autoDeploy=null$'
  echo "$output" | grep -q '^sourceRepo=null$'
}
