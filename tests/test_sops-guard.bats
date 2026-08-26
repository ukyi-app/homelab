#!/usr/bin/env bats

setup() {
  export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"
  TMP="apps/_guardtest/prod"
  mkdir -p "$TMP"
}
teardown() { rm -rf apps/_guardtest; }

@test "guard BLOCKS a plaintext *.enc.yaml" {
  cp tests/fixtures/sample-secret.yaml apps/_guardtest/prod/leak.enc.yaml
  run ./scripts/sops-guard.sh apps/_guardtest/prod/leak.enc.yaml
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'BLOCKED'
}

@test "guard ALLOWS a properly encrypted *.enc.yaml" {
  cp tests/fixtures/sample-secret.yaml apps/_guardtest/prod/ok.enc.yaml
  sops --encrypt --in-place apps/_guardtest/prod/ok.enc.yaml
  run ./scripts/sops-guard.sh apps/_guardtest/prod/ok.enc.yaml
  [ "$status" -eq 0 ]
}

@test "guard ignores non-secret yaml" {
  echo "kind: ConfigMap" > apps/_guardtest/prod/plain.yaml
  run ./scripts/sops-guard.sh apps/_guardtest/prod/plain.yaml
  [ "$status" -eq 0 ]
}

@test "guard BLOCKS a plaintext *.enc.yaml carrying a sops_mac decoy token" {
  # 부분문자열 grep 우회: 평문인데 'sops_mac' 리터럴만 박힌 파일은 차단돼야 한다.
  cat > apps/_guardtest/prod/decoy.enc.yaml <<'YAML'
apiVersion: v1
kind: Secret
metadata:
  name: evil
stringData:
  TOKEN: super-secret-plaintext
# sops_mac
YAML
  run ./scripts/sops-guard.sh apps/_guardtest/prod/decoy.enc.yaml
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'BLOCKED'
}

@test "guard BLOCKS a file with sops metadata but a plaintext data leaf (partial enc)" {
  # sops 블록은 있으나 stringData 리프가 평문이면 차단(부분 암호화 누출 방지).
  cp tests/fixtures/sample-secret.yaml apps/_guardtest/prod/partial.enc.yaml
  sops --encrypt --in-place apps/_guardtest/prod/partial.enc.yaml
  # 암호화 후 한 리프를 평문으로 되돌린다(누출 시뮬레이션).
  yq -i '.stringData.URL = "postgres://user:pw@db:5432/app"' apps/_guardtest/prod/partial.enc.yaml
  run ./scripts/sops-guard.sh apps/_guardtest/prod/partial.enc.yaml
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'BLOCKED'
}

@test "a --floor argument is refused until the migration lands (no fake-green file mode)" {
  # 리뷰 실측(kernel-followups 02): 인자 모드가 --floor를 파일로 오인해 0건 검사 + 초록 + 거짓
  # SCAN을 냈다 — 03 이관 전까지 명시 거부가 방어선이다.
  run ./scripts/sops-guard.sh --floor sops-guard=99999
  [ "$status" -eq 2 ]
  echo "$output" | grep -q -- "--floor 미지원"
  out="$output"
  run grep -q "^SCAN:" <<<"$out"
  [ "$status" -ne 0 ]
}
