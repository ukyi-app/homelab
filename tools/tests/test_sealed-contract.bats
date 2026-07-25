#!/usr/bin/env bats
# 봉인 계약 커널(tools/lib/sealed-contract.ts) 단위 — lib 인터페이스를 직접 단언한다.
# readSealed가 봉인 계약 정책·checksum·이름 규약·디스크 바이트를 소유(create-app/update-secrets 공용).
# 단언 규율: 중간 단언은 `run …; [ "$status" … ]` / `[ … ]`(단일 대괄호)로만(check-bats-style 강제).
# 각 `run rs` 뒤에 `[ "$status" -eq 0 ]`을 병기한다 — bun이 import 실패 등으로 죽으면(비-0) $output이
# 비어 우연히 통과할 여지를 막는다(test_image-pin-lib.bats 선례).
setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  LIB="$ROOT/tools/lib/sealed-contract.ts"
}

# 봉인본을 파일로 쓰고 readSealed(raw, app)를 돌려 $3(JS 표현식)의 결과를 stdout으로 반환.
rs() {  # $1=봉인본파일 $2=app $3=JS표현식(r 사용 가능, raw도 사용 가능)
  bun -e "
    import { readSealed } from '$LIB';
    import { readFileSync } from 'node:fs';
    const raw = readFileSync('$1','utf8');
    const r = readSealed(raw, '$2');
    console.log($3);
  "
}

# 유효 봉인본 픽스처를 파일로 조립. keys-block은 %b라 \n(줄바꿈)을 확장한다.
valid_sealed() {  # $1=파일 $2=name $3=keys-block(YAML, \n 허용)
  printf 'apiVersion: bitnami.com/v1alpha1\nkind: SealedSecret\nmetadata:\n  name: %s\n  namespace: prod\nspec:\n  encryptedData:\n' "$2" > "$1"
  printf '%b\n' "$3" >> "$1"
}

@test "readSealed accepts a valid sealed secret and reports sorted keys" {
  f="$BATS_TEST_TMPDIR/s.yaml"
  valid_sealed "$f" myapp-secrets '    ZED: AgA\n    ABC: AgB'
  run rs "$f" myapp 'r.ok'
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
  run rs "$f" myapp 'r.ok ? r.facts.keys.join(",") : r.why'
  [ "$status" -eq 0 ]
  [ "$output" = "ABC,ZED" ]
}

@test "readSealed: checksum is sha256(raw) first 16 hex chars" {
  f="$BATS_TEST_TMPDIR/s.yaml"
  valid_sealed "$f" myapp-secrets '    FOO: AgABC'
  want="$(if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$f" | cut -c1-16; else sha256sum "$f" | cut -c1-16; fi)"
  run rs "$f" myapp 'r.ok ? r.facts.checksum : r.why'
  [ "$status" -eq 0 ]
  [ "$output" = "$want" ]
}

@test "readSealed: bytes equals raw verbatim (#299 regression lock — hashed == written)" {
  f="$BATS_TEST_TMPDIR/s.yaml"
  valid_sealed "$f" myapp-secrets '    FOO: AgABC'
  run rs "$f" myapp 'r.ok ? String(r.facts.bytes === raw) : r.why'
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "readSealed: secretName and sealedFile follow the <app>-secrets convention" {
  f="$BATS_TEST_TMPDIR/s.yaml"
  valid_sealed "$f" myapp-secrets '    FOO: AgABC'
  run rs "$f" myapp 'r.ok ? r.facts.secretName + "|" + r.facts.sealedFile : r.why'
  [ "$status" -eq 0 ]
  [ "$output" = "myapp-secrets|myapp-secrets.sealed.yaml" ]
}

@test "readSealed rejects a non-SealedSecret kind" {
  f="$BATS_TEST_TMPDIR/s.yaml"
  printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: myapp-secrets\n  namespace: prod\n' > "$f"
  run rs "$f" myapp 'r.ok ? "OK" : r.why'
  [ "$status" -eq 0 ]
  [ "$output" = "sealed 파일이 kind: SealedSecret이 아니다" ]
}

@test "readSealed rejects a non-prod namespace (strict-scope), echoing the actual value" {
  f="$BATS_TEST_TMPDIR/s.yaml"
  printf 'apiVersion: bitnami.com/v1alpha1\nkind: SealedSecret\nmetadata:\n  name: myapp-secrets\n  namespace: default\nspec:\n  encryptedData:\n    FOO: AgA\n' > "$f"
  run rs "$f" myapp 'r.ok ? "OK" : r.why'
  [ "$status" -eq 0 ]
  [ "$output" = "sealed namespace는 prod여야 한다(strict-scope): default" ]
}

@test "readSealed rejects a name that is not <app>-secrets, echoing the actual value" {
  f="$BATS_TEST_TMPDIR/s.yaml"
  valid_sealed "$f" wrong-name '    FOO: AgABC'
  run rs "$f" myapp 'r.ok ? "OK" : r.why'
  [ "$status" -eq 0 ]
  [ "$output" = "sealed name은 myapp-secrets여야 한다: wrong-name" ]
}

@test "readSealed rejects empty encryptedData" {
  f="$BATS_TEST_TMPDIR/s.yaml"
  printf 'apiVersion: bitnami.com/v1alpha1\nkind: SealedSecret\nmetadata:\n  name: myapp-secrets\n  namespace: prod\nspec:\n  encryptedData: {}\n' > "$f"
  run rs "$f" myapp 'r.ok ? "OK" : r.why'
  [ "$status" -eq 0 ]
  [ "$output" = "sealed encryptedData가 비어 있다" ]
}

@test "readSealed rejects non-UPPER_SNAKE keys, naming the offenders" {
  f="$BATS_TEST_TMPDIR/s.yaml"
  valid_sealed "$f" myapp-secrets '    bad-key: AgA'
  run rs "$f" myapp 'r.ok ? "OK" : r.why'
  [ "$status" -eq 0 ]
  [ "$output" = "sealed encryptedData 키는 UPPER_SNAKE여야 한다: bad-key" ]
}

@test "readSealed accepts DATABASE_ADMIN_URL (valid UPPER_SNAKE)" {
  f="$BATS_TEST_TMPDIR/s.yaml"
  valid_sealed "$f" myapp-secrets '    DATABASE_ADMIN_URL: AgA'
  run rs "$f" myapp 'r.ok'
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}
