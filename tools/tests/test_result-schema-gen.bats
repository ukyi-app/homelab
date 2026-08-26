#!/usr/bin/env bats
# 결과 계약 표화(cli-deepening 심화 3) — cli-result-schema.json은 기술자 행(catalog-rows
# CONTRACT_ROWS)과 플랫폼 좌표(platform ARCHETYPES)에서 생성기의 산출물이다. 드리프트 게이트(byte 동일)·
# 생성물 부재 재생성(의존 순환 부재 — 설계 게이트 r1 D3)·행 순서 손 앵커·판별성을 여기서 강제한다.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과 함정. @test 이름은 영어(인코딩 함정).

setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "the generator reproduces the committed schema byte-identically (drift gate)" {
  run bun tools/generate-result-schema.ts --write --out "$BATS_TEST_TMPDIR/gen.json"
  [ "$status" -eq 0 ]
  cmp tools/cli-result-schema.json "$BATS_TEST_TMPDIR/gen.json"
}

@test "check mode is green on identity and red on drift" {
  run bun tools/generate-result-schema.ts --check
  [ "$status" -eq 0 ]
  # 드리프트 주입은 사본에 — 작업 트리는 불변이다.
  sed "s|homelab-cli/1|homelab-cli/2|" tools/cli-result-schema.json > "$BATS_TEST_TMPDIR/drift.json"
  run bun tools/generate-result-schema.ts --check --out "$BATS_TEST_TMPDIR/drift.json"
  [ "$status" -eq 1 ]
}

@test "unknown arguments fail loud (exit 2 — no silent off-switch)" {
  run bun tools/generate-result-schema.ts --nonsense
  [ "$status" -eq 2 ]
  # --out의 값 자리에 플래그가 오면 값 누락으로 거부한다(--write라는 이름의 파일을 쓰지 않는다).
  run bun tools/generate-result-schema.ts --out --write
  [ "$status" -eq 2 ]
}

@test "regeneration succeeds in a tree WITHOUT the generated artifact (no dependency cycle)" {
  # 생성기 + 기술자만 복사한 격리 트리 — 생성물이 없어도(그리고 계약 독자가 없어도) 재생성이
  # 성립해야 한다: 생성기 → 기술자 외 어떤 참조도 없음의 실행 증명(설계 게이트 r1 D3).
  T="$BATS_TEST_TMPDIR/isolated"
  mkdir -p "$T/tools/lib"
  cp tools/generate-result-schema.ts "$T/tools/"
  cp tools/lib/catalog-rows.ts tools/lib/platform.ts "$T/tools/lib/"
  [ ! -f "$T/tools/cli-result-schema.json" ]
  # cwd도 격리 트리 안으로 — 실 레포가 cwd 상대 경로로 보이면 무참조 증명이 vacuous해진다.
  run bash -c "cd '$T' && exec bun tools/generate-result-schema.ts --write --out gen.json"
  [ "$status" -eq 0 ]
  cmp tools/cli-result-schema.json "$T/gen.json"
}

@test "the verb enum order derives from CONTRACT_ROWS (hand-pinned anchor)" {
  run bun -e '
    const root = process.argv[1];
    const { CONTRACT_ROWS } = await import(root + "/tools/lib/catalog-rows.ts");
    const verbs = CONTRACT_ROWS.map((r) => r.verb);
    const want = ["doctor", "status", "db create", "cache create", "app create", "app secrets", "app teardown", "app init", "db url", "cache url"];
    if (JSON.stringify(verbs) !== JSON.stringify(want)) { console.error(JSON.stringify(verbs)); process.exit(1); }
    console.log("ok:" + verbs.length);
  ' "$ROOT"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^ok:10$"
}

@test "a contract row edit changes the generated output (mutation discriminability)" {
  # 행이 산출물을 실제로 결정하는가 — chain 극성을 뒤집은 사본 기술자로 생성하면 byte가 달라진다.
  T="$BATS_TEST_TMPDIR/mut"
  mkdir -p "$T/tools/lib"
  cp tools/generate-result-schema.ts "$T/tools/"
  cp tools/lib/platform.ts "$T/tools/lib/"
  sed 's|chain: false|chain: true|' tools/lib/catalog-rows.ts > "$T/tools/lib/catalog-rows.ts"
  run bash -c "cd '$T' && exec bun tools/generate-result-schema.ts --write --out gen.json"
  [ "$status" -eq 0 ]
  run cmp -s tools/cli-result-schema.json "$T/gen.json"
  [ "$status" -eq 1 ]
}

@test "the archetype enum derives from platform ARCHETYPES (hand-pinned anchor, mutation discriminability)" {
  # 손 앵커 — 커밋된 생성물의 initSuccess·initFailure archetype enum을 리터럴로 핀한다(SSOT 축소 시 vacuous 차단).
  for d in initSuccess initFailure; do
    [ "$(jq -rc ".definitions.$d.properties.archetype.enum | join(\",\")" tools/cli-result-schema.json)" = "api,fullstack,site,worker" ]
  done
  # 리터럴 사본 소멸 — 생성기 소스에 아키타입 이름이 없다(양성 대조: 같은 술어가 SSOT에서는 매치).
  [ "$(grep -c '"fullstack"' tools/lib/platform.ts)" -ge 1 ]
  [ "$(grep -c '"fullstack"' tools/generate-result-schema.ts)" = "0" ]
  # 변이: platform.ts의 ARCHETYPES 줄 끝에만 "hexagon"을 덧붙인 격리 트리에서 생성하면 두 정의 모두에 반영된다.
  T="$BATS_TEST_TMPDIR/arch"
  mkdir -p "$T/tools/lib"
  cp tools/generate-result-schema.ts "$T/tools/"
  cp tools/lib/catalog-rows.ts "$T/tools/lib/"
  sed 's|^\(export const ARCHETYPES = \[.*\)\] as const;|\1, "hexagon"] as const;|' tools/lib/platform.ts > "$T/tools/lib/platform.ts"
  grep -q '^export const ARCHETYPES = .*"hexagon"\] as const;' "$T/tools/lib/platform.ts"
  run bash -c "cd '$T' && exec bun tools/generate-result-schema.ts --write --out gen.json"
  [ "$status" -eq 0 ]
  for d in initSuccess initFailure; do
    [ "$(jq -rc ".definitions.$d.properties.archetype.enum | join(\",\")" "$T/gen.json")" = "api,fullstack,site,worker,hexagon" ]
  done
  run cmp -s tools/cli-result-schema.json "$T/gen.json"
  [ "$status" -eq 1 ]
}
