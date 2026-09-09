#!/usr/bin/env bats
# kustomization.yaml 멱등 편집 SSOT(tools/lib/kustomization.ts) — yaml 라운드트립·주석보존.
# ⚠️ 중간 단언은 [ ]만.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "addResource adds entry idempotently and preserves comments" {
  run bun -e '
    import { addResource } from "./tools/lib/kustomization.ts";
    const base = "# keep me\napiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources:\n  - a.yaml\n";
    let out = addResource(base, "b.yaml");
    out = addResource(out, "b.yaml");                          // 멱등 — 중복 추가 안 됨
    if (!/# keep me/.test(out)) { console.error("comment lost"); process.exit(1); }
    if ((out.match(/b\.yaml/g) || []).length !== 1) { console.error("dup"); process.exit(1); }
    console.log("ok");
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "ok"
}

@test "removeResource removes entry (trailing-slash normalized) and is idempotent" {
  run bun -e '
    import { removeResource } from "./tools/lib/kustomization.ts";
    const base = "kind: Kustomization\nresources:\n  - widget/\n  - keep.yaml\n";
    let out = removeResource(base, "widget");                  // name vs name/ 정규화 매칭
    if (/widget/.test(out)) { console.error("not removed"); process.exit(1); }
    if (!/keep.yaml/.test(out)) { console.error("over removed"); process.exit(1); }
    out = removeResource(out, "widget");                       // 멱등
    console.log("ok");
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "ok"
}

@test "callsites use kustomization lib (teardown removeResource, provision-cache addResource)" {
  # rc 2(teardown-resource.ts 리네임)를 "인라인 deregister 제거됨"으로 읽지 않는다 — 아래 루프가 같은
  # 파일을 양성으로 증언한다. cf. docs/traps-detail.md 「열거 붕괴 → vacuous green」③
  run grep -nE 'function deregister' "$ROOT/tools/teardown-resource.ts"; [ "$status" -eq 1 ]  # 인라인 deregister 제거
  # 파일 어디든 리터럴 "lib/kustomization.ts" 문자열 1회면 참이라, import를
  # 주석으로 바꾸고 lib 본문을 로컬 function으로 복사해도 통과했다(무증인 재현). import 형태로 좁힌다
  # — 부재 단언의 피연산자 실재는 이 좁힌 import 루프가 그대로 증언한다(rc 2 오독 방지, L37 논리와 동형).
  # update-secrets도 같은 커널 소비처인데 루프 분모 밖이었다(tools/update-secrets.ts:8) — 편입.
  for f in teardown-resource provision-cache update-secrets; do
    run grep -qE '^import .*"\./lib/kustomization\.ts"' "$ROOT/tools/$f.ts"; [ "$status" -eq 0 ]
  done
  # provision-db는 doc-배치·lineWidth:0·entry-comment·flow→block 동작이라 string-기반 lib로 비이주(동작보존, plan Step5)
  run grep -q 'function addResource' "$ROOT/tools/provision-db.ts"; [ "$status" -eq 0 ]
}

# purge cleanup이 두 kustomization을 `resources: []`(빈 flow)로 남긴다 — 그 뒤 provision(lib 경로)이
# 항목을 추가하면 flow가 되살아나 `resources: [a, b]`가 된다(렌더는 같아도 표기 drift·diff 노이즈).
# provision-db.ts의 자체 헬퍼는 `seq.flow = false`로 이미 block 정규화한다(tools/provision-db.ts:275) —
# lib만 비대칭이었다. 정확한 직렬화 문자열로 고정한다(스타일 단언이 정규식이면 flow도 통과한다).
@test "addResource normalizes an empty flow sequence to block style" {
  run bun -e '
    import { addResource } from "./tools/lib/kustomization.ts";
    const head = "apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\n";
    const fail = (label, got) => { console.error(label + ": " + JSON.stringify(got)); process.exit(1); };
    const one = addResource(head + "resources: []\n", "a.yaml");        // 1회 add
    if (one !== head + "resources:\n  - a.yaml\n") fail("empty-flow 1st add", one);
    const two = addResource(one, "b.yaml");                             // 2회 add
    if (two !== head + "resources:\n  - a.yaml\n  - b.yaml\n") fail("empty-flow 2nd add", two);
    const nonEmpty = addResource(head + "resources: [a.yaml]\n", "b.yaml");  // 항목 있는 flow도 정규화
    if (nonEmpty !== head + "resources:\n  - a.yaml\n  - b.yaml\n") fail("non-empty flow add", nonEmpty);
    console.log("ok");
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "ok"
}

# `resources` 키 자체가 없거나 값이 null인 문서에서도 block으로 만든다(요구 2).
@test "addResource creates a block sequence when the resources key is absent or null" {
  run bun -e '
    import { addResource } from "./tools/lib/kustomization.ts";
    const head = "apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\n";
    const fail = (label, got) => { console.error(label + ": " + JSON.stringify(got)); process.exit(1); };
    const missing = addResource(head, "a.yaml");                        // 키 부재
    if (missing !== head + "resources:\n  - a.yaml\n") fail("absent key", missing);
    const nullish = addResource("kind: Kustomization\nresources:\n", "a.yaml");  // 값 null
    if (nullish !== "kind: Kustomization\nresources:\n  - a.yaml\n") fail("null value", nullish);
    console.log("ok");
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "ok"
}

# 정규화가 기존 block 문서의 주석·꼬리주석·들여쓰기를 건드리지 않는다(요구 3) + 멱등은 원문 그대로(요구 4).
@test "addResource preserves comments and block formatting of an existing document" {
  run bun -e '
    import { addResource } from "./tools/lib/kustomization.ts";
    const base = "# 상위 kustomization이 포함한다\nkind: Kustomization\nresources:\n  # 인스턴스 디렉토리\n  - a.yaml # 꼬리주석\n";
    const fail = (label, got) => { console.error(label + ": " + JSON.stringify(got)); process.exit(1); };
    const out = addResource(base, "b.yaml");
    if (out !== base + "  - b.yaml\n") fail("block append", out);
    if (addResource(out, "a.yaml") !== out) fail("idempotent add", addResource(out, "a.yaml"));  // 멱등 — 원문 반환
    console.log("ok");
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "ok"
}

# `resources` 값이 falsy-비-nullish 스칼라(""/0/false)여도 block 시퀀스로 복구한다.
# 추가 경로의 두 술어(`seq || createNode` · `if (seq)`)가 갈리면 seqNode에 원시값이 들어가
# flow 대입이 TypeError를 던진다 — origin/main이 하던 self-heal의 회귀 가드다.
@test "addResource self-heals a falsy non-sequence resources value (predicate parity)" {
  run bun -e '
    import { addResource } from "./tools/lib/kustomization.ts";
    const head = "apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\n";
    const want = head + "resources:\n  - a.yaml\n";
    const fail = (label, got) => { console.error(label + ": " + JSON.stringify(got)); process.exit(1); };
    for (const [label, raw] of [["empty-string", "resources: \"\"\n"], ["zero", "resources: 0\n"], ["false", "resources: false\n"]]) {
      const out = addResource(head + raw, "a.yaml");
      if (out !== want) fail(label, out);
    }
    console.log("ok");
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "ok"
}
