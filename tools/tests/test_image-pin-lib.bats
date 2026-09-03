#!/usr/bin/env bats
# 배포 핀 형식 커널(tools/lib/image-pin.ts) 단위 — lib 인터페이스를 직접 단언한다.
# 행위 보존 리팩터의 born-green 특성상 기대값은 현재 콜사이트(poll-ghcr/bump-tag) 행동에서 채취.
# 단언 규율: 중간 단언은 `run …; [ "$status" … ]` / `[ … ]`(단일 대괄호)로만(check-bats-style 강제).
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; }

# lib 함수를 bun -e로 로드해 $1(JS 본문)을 실행하고 stdout을 반환.
lib() { bun -e "
  import { TAG_RE, DIGEST_RE, parseInlinePin, formatInlinePin, parseDescriptor, descriptorAutoDeploy } from '$ROOT/tools/lib/image-pin.ts';
  $1
"; }

@test "TAG_RE accepts sha- + 7..40 lowercase hex and rejects 6/41 length and uppercase" {
  run lib 'console.log([
    TAG_RE.test("sha-1234567"),
    TAG_RE.test("sha-1234567890123456789012345678901234567890"),
    TAG_RE.test("sha-123456"),
    TAG_RE.test("sha-12345678901234567890123456789012345678901"),
    TAG_RE.test("sha-ABCDEF1"),
  ].join(","))'
  [ "$status" -eq 0 ]
  [ "$output" == "true,true,false,false,false" ]
}

@test "DIGEST_RE accepts sha256: + 64 lowercase hex and rejects 63/65 length and uppercase" {
  run lib 'console.log([
    DIGEST_RE.test("sha256:4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945"),
    DIGEST_RE.test("sha256:111111111111111111111111111111111111111111111111111111111111111"),
    DIGEST_RE.test("sha256:11111111111111111111111111111111111111111111111111111111111111111"),
    DIGEST_RE.test("sha256:AAAAcda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945"),
  ].join(","))'
  [ "$status" -eq 0 ]
  [ "$output" == "true,false,false,false" ]
}

@test "parseInlinePin splits a canonical scalar into repo/tag/digest" {
  run lib 'const p = parseInlinePin("ghcr.io/ukyi-app/files:sha-1234567@sha256:4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945");
    console.log([p.repo, p.tag, p.digest].join("|"))'
  [ "$status" -eq 0 ]
  [ "$output" == "ghcr.io/ukyi-app/files|sha-1234567|sha256:4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945" ]
}

@test "parseInlinePin keeps a colon-containing repo intact via non-greedy match" {
  run lib 'const p = parseInlinePin("reg.io:443/ukyi-app/files:sha-feedbee@sha256:1111111111111111111111111111111111111111111111111111111111111111");
    console.log(p.repo + "|" + p.tag)'
  [ "$status" -eq 0 ]
  [ "$output" == "reg.io:443/ukyi-app/files|sha-feedbee" ]
}

@test "parseInlinePin returns null on a malformed scalar without throwing" {
  run lib 'console.log([
    parseInlinePin("ghcr.io/ukyi-app/files:sha-aaa1111") === null,
    parseInlinePin("ghcr.io/ukyi-app/files:sha-ABCDEF1@sha256:1111111111111111111111111111111111111111111111111111111111111111") === null,
    parseInlinePin("") === null,
  ].join(","))'
  [ "$status" -eq 0 ]
  [ "$output" == "true,true,true" ]
}

@test "formatInlinePin is the inverse of parseInlinePin (roundtrip identity)" {
  run lib 'const s = "reg.io:443/ukyi-app/files:sha-feedbee@sha256:1111111111111111111111111111111111111111111111111111111111111111";
    console.log(formatInlinePin(parseInlinePin(s)) === s)'
  [ "$status" -eq 0 ]
  [ "$output" == "true" ]
}

@test "parseDescriptor parses a valid descriptor json with no normalization" {
  run lib 'const d = parseDescriptor(`{ "file": "deployment.yaml", "path": ["spec","template","spec","containers",0,"image"], "autoDeploy": true }`);
    console.log(d.file + "|" + d.path.length + "|" + d.path[4] + "|" + d.autoDeploy)'
  [ "$status" -eq 0 ]
  [ "$output" == "deployment.yaml|6|0|true" ]
}

@test "parseDescriptor propagates a throw on malformed json (no swallow)" {
  run lib 'try { parseDescriptor(`{ not valid json`); console.log("NO-THROW"); } catch { console.log("threw"); }'
  [ "$status" -eq 0 ]
  [ "$output" == "threw" ]
}

@test "descriptorAutoDeploy is fail-closed: only boolean true yields true" {
  run lib 'console.log([
    descriptorAutoDeploy({ autoDeploy: true }),
    descriptorAutoDeploy({ autoDeploy: false }),
    descriptorAutoDeploy({}),
    descriptorAutoDeploy(null),
    descriptorAutoDeploy(undefined),
    descriptorAutoDeploy({ autoDeploy: "true" }),
    descriptorAutoDeploy({ autoDeploy: 1 }),
  ].join(","))'
  [ "$status" -eq 0 ]
  [ "$output" == "true,false,false,false,false,false,false" ]
}

@test "pin format literals live only in the kernel, never in its consumers" {
  # 커널 채택 콜사이트에 핀 형식 리터럴이 재출현하면 FAIL — SSOT 우회 오배포 표면 회귀
  # 가드(test_ledger-budget.bats:64-68 선례).
  # 검사 리터럴 3종: 인라인 파서 몸통 `(.+?):(sha-` · tag 몸통 · digest 몸통.
  # ⚠️ tag/digest 몸통은 **언앵커드**로 센다. 착지 전 이 로스터는 앵커드 철자(`/^sha-…`)만 봤고,
  #    그래서 bump-tag.ts가 손으로 재유도하던 언앵커드 tag 몸통이 판정 밖이었다 — 그 면제 주석이
  #    바로 이 자리에 있었다. 12번이 그 재유도를 커널로 라우팅해 리터럴이 사라졌으므로, 이제 넓은
  #    철자로 세어 **재유입까지** 막는다(재유도가 주석이든 코드든 파일 바이트로는 같다).
  # ⚠️ untouched-e-1(5라운드) — 손 로스터(poll-ghcr·bump-tag·create-app 3개 하드코딩)는 실 소비처
  #    ensure-bump-pr.ts(:191 `import { TAG_RE } from "./lib/image-pin.ts"`)를 못 봤다(재유도 뮤테이션
  #    10/10 그대로 통과 실측). `git grep -l 'lib/image-pin' -- 'tools/*.ts'`로 열거해 신규 소비처를
  #    자동 편입한다 — 열거 붕괴 바닥값(-ge 4)이 글롭 붕괴를 막는다.
  # ⚠️ `tools/lib/digest-exporter.ts`가 로스터에 새로 들어온다(오늘 0건이라 무비용) — 커널을
  #    import하지 않으므로(bump-tag의 APPS 편집만 거친다) 열거 밖 명시 항목으로 유지한다.
  # ⚠️ `tools/lib/image-pin.ts`는 로스터에 **넣지 않는다**(자기참조 0이라 열거에서 자동 제외) —
  #    커널이 이 형식의 유일한 소재지라 거기 리터럴이 있는 것이 정상이다. 대신 아래 **양성
  #    대조**로 쓴다: 커널에서 매치가 사라지면 술어가 죽은 것이고 위의 0건은 공허하다(바닥값
  #    2 = TAG_BODY·DIGEST_BODY 두 상수). 세 번째 리터럴 `(.+?):(sha-`는 커널이 템플릿
  #    보간으로 조립하므로 커널에도 0건이다.
  LITERALS="-e '(.+?):(sha-' -e 'sha-[0-9a-f]' -e 'sha256:[0-9a-f]'"
  run bash -c "cd '$ROOT' && git grep -l 'lib/image-pin' -- 'tools/*.ts' | wc -l | tr -d ' '"
  [ "$status" -eq 0 ]
  [ "$output" -ge 4 ]   # 열거 붕괴 바닥값(아래 커널 -ge 2와 같은 관용구)
  run bash -c "cd '$ROOT' && grep -hoF $LITERALS \$(git grep -l 'lib/image-pin' -- 'tools/*.ts') tools/lib/digest-exporter.ts | wc -l | tr -d ' '"
  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
  run bash -c "grep -hoF $LITERALS '$ROOT/tools/lib/image-pin.ts' | wc -l | tr -d ' '"
  [ "$status" -eq 0 ]
  [ "$output" -ge 2 ]
}
