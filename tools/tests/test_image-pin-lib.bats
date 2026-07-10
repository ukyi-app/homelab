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
