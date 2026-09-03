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
  # untouched-e-2(5라운드) — 파일 어디든 리터럴 "lib/kustomization.ts" 문자열 1회면 참이라, import를
  # 주석으로 바꾸고 lib 본문을 로컬 function으로 복사해도 통과했다(무증인 재현). import 형태로 좁힌다
  # — 부재 단언의 피연산자 실재는 이 좁힌 import 루프가 그대로 증언한다(rc 2 오독 방지, L37 논리와 동형).
  # update-secrets도 같은 커널 소비처인데 루프 분모 밖이었다(tools/update-secrets.ts:8) — 편입.
  for f in teardown-resource provision-cache update-secrets; do
    run grep -qE '^import .*"\./lib/kustomization\.ts"' "$ROOT/tools/$f.ts"; [ "$status" -eq 0 ]
  done
  # provision-db는 doc-배치·lineWidth:0·entry-comment·flow→block 동작이라 string-기반 lib로 비이주(동작보존, plan Step5)
  run grep -q 'function addResource' "$ROOT/tools/provision-db.ts"; [ "$status" -eq 0 ]
}
