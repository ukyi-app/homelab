#!/usr/bin/env bats
# kubeseal 봉인 SSOT(tools/lib/seal.ts) — 평문은 stdin으로만, 디스크/stdout 비기록.
# ⚠️ 중간 단언은 [ ]만.
# ⚠️ 부재 단언 규약(`-eq 1`)은 docs/traps-detail.md 「열거 붕괴 → vacuous green」③·③-a가 SSOT다.
#    이 파일 고유 사정: 이관 경계(어느 파일이 lib를 쓰고 어느 파일이 안 쓰는가)를 **소스 형태**로
#    재는 파일이라, 그 소스 파일이 리네임되면 경계 단언이 통째로 vacuous해진다.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "seal.ts exports sealManifest and fails loud on missing cert" {
  run bun -e '
    import { sealManifest } from "./tools/lib/seal.ts";
    try { sealManifest({ kind: "Secret" }, "/nonexistent/cert.pem"); console.log("DID-NOT-THROW"); }
    catch (e) { console.log("threw"); }
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^threw$"
}

@test "provision callsites use sealManifest (no inline kubeseal spawnSync left)" {
  # 다중 파일 피연산자 — 하나만 사라져도 무매치면 rc 2다(SSOT ③-a 표). 아래 루프가 같은 두
  # 파일에 lib/seal.ts import를 요구하는 양성 형제다.
  run grep -nE 'spawnSync\("kubeseal"' tools/provision-db.ts tools/provision-cache.ts
  [ "$status" -eq 1 ]
  # ⚠️ 양성 형제도 **import 줄**로 좁힌다 — 두 파일 다 본문 주석에 `봉인 SSOT = lib/seal.ts`를
  #    담고 있어 맨 매치는 sealManifest를 안 써도 참이다(실측 2026-09-04: provision-db.ts의
  #    직수입을 lib 본문의 로컬 사본으로 바꿔도 이 파일 + 형제 2파일 28/28 그대로 초록).
  #    좁혀도 위 부재 단언의 피연산자 실재는 이 루프가 그대로 증언한다(rc 2 오독 방지).
  for f in provision-db.ts provision-cache.ts; do
    run grep -qE '^import .*"\./lib/seal\.ts"' "tools/$f"
    [ "$status" -eq 0 ]
  done
}

@test "app-shared seal-secret.mts keeps its own kubeseal block (NOT migrated, F3)" {
  # 외부 앱 레포 배포 self-contained — homelab lib import 금지
  run grep -nE 'spawnSync\("kubeseal"' tools/seal-secret.mts
  [ "$status" -eq 0 ]
  # 바로 위가 같은 파일의 양성 형제라 리네임은 거기서 먼저 red다 — 이 줄의 `-eq 1`이 더 잡는 것은
  # 두 줄의 경로가 갈리는 드리프트와, 위 형제가 지워졌을 때의 단독 vacuous green이다.
  run grep -q "lib/seal" tools/seal-secret.mts
  [ "$status" -eq 1 ]
}

@test "a kubeseal failure surfaces the exit code but never the child stderr (plaintext echo defence)" {
  # d6④ 이관면의 성질 고정 — 실패 메시지에 stderr(res.err)를 싣지 않는다. kubeseal이 평문을 stderr로
  # 에코하는 최악 상황을 스텁으로 재현해, 그 평문이 throw 메시지에 실리지 않음을 실측한다
  # (15행 분기에 ${res.err}를 붙이는 mutation이 이 단언에서 red가 된다).
  S="$BATS_TEST_TMPDIR/bin"; mkdir -p "$S"
  printf '#!/bin/sh\necho "PLAINTEXT-ECHO-9d2c $(cat)" >&2\nexit 1\n' > "$S/kubeseal"
  chmod +x "$S/kubeseal"
  run env PATH="$S:$PATH" bun -e '
    import { sealManifest } from "./tools/lib/seal.ts";
    try { sealManifest({ kind: "Secret", stringData: { K: "PLAINTEXT-ECHO-9d2c" } }, "/tmp/cert.pem"); console.log("DID-NOT-THROW"); }
    catch (e) { console.log("threw: " + (e as Error).message); }
  '
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^threw: '
  echo "$output" | grep -q '종료 코드 1'
  run grep -q 'PLAINTEXT-ECHO-9d2c' <<<"$output"
  [ "$status" -ne 0 ]
}
