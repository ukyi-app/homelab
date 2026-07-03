#!/usr/bin/env bats
# seal-batch — 선언 테이블 기반 단일 봉인 도구. kubeseal/docker/gh 스텁으로 CI-safe(gate 수집).
# preflight(secret-cert-check.sh)는 실 스크립트를 돌리되 kubeseal --fetch-cert 스텁으로 오프라인/일치 분기.
# ⚠️ 중간 단언은 [ ]만 — bash 3.2 [[ ]] 침묵 통과. 평문/해시/토큰은 어떤 경로로도 미노출.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1
  TMP="$(mktemp -d)"; mkdir -p "$TMP/bin"
  openssl req -x509 -newkey rsa:2048 -keyout /dev/null -out "$TMP/certA.pem" -days 1 -nodes -subj "/CN=a" 2>/dev/null
  # kubeseal 스텁: --fetch-cert → certA(preflight 일치), 그 외(--format yaml) → SealedSecret 모양
  cat > "$TMP/bin/kubeseal" <<EOF
#!/bin/sh
case "\$*" in
  *--fetch-cert*) cat "$TMP/certA.pem" ;;
  *) printf 'apiVersion: bitnami.com/v1alpha1\nkind: SealedSecret\nmetadata:\n  name: STUB\nspec:\n  encryptedData:\n    STUB: xxx\n' ;;
esac
EOF
  chmod +x "$TMP/bin/kubeseal"
  # docker 스텁(bcrypt): htpasswd 출력 형식 'x:$2y$10$...' 모사(평문 미반영)
  printf '#!/bin/sh\nprintf "x:$2y$10$abcdefghijklmnopqrstuv\\n"\n' > "$TMP/bin/docker"; chmod +x "$TMP/bin/docker"
  printf '#!/bin/sh\necho testuser\n' > "$TMP/bin/gh"; chmod +x "$TMP/bin/gh"
}
teardown() { rm -rf "$TMP"; }

@test "dry-run lists targeted secrets and keys without invoking kubeseal or leaking values" {
  export ADGUARD_PASSWORD="p-secret-xyz"
  run bun tools/seal-batch.ts --only adguard-auth --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "adguard-auth"
  echo "$output" | grep -q "PASSWORD_HASH"
  [ "$(printf '%s' "$output" | grep -c "p-secret-xyz")" -eq 0 ]   # 부정 단언은 카운트 패턴(B3 lint-safe)
}

@test "unknown flag exits 2 (usage/parse per cli convention)" {
  run bun tools/seal-batch.ts --bogus
  [ "$status" -eq 2 ]
}

@test "missing env var fails closed with exit 1 (no partial seal)" {
  unset ADGUARD_PASSWORD
  run bun tools/seal-batch.ts --only adguard-auth --dry-run
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "ADGUARD_PASSWORD"
}

@test "seals a bcrypt secret through kubeseal, writing under --out-dir, never printing plaintext/hash" {
  export ADGUARD_PASSWORD="p-secret-xyz"
  PATH="$TMP/bin:$PATH" run bun tools/seal-batch.ts --only adguard-auth --cert "$TMP/certA.pem" --out-dir "$TMP"
  [ "$status" -eq 0 ]
  [ -f "$TMP/platform/adguard/prod/adguard-auth.sealed.yaml" ]
  grep -q "kind: SealedSecret" "$TMP/platform/adguard/prod/adguard-auth.sealed.yaml"
  [ "$(grep -c "p-secret-xyz" "$TMP/platform/adguard/prod/adguard-auth.sealed.yaml")" -eq 0 ]
  [ "$(printf '%s' "$output" | grep -c "p-secret-xyz")" -eq 0 ]
  [ "$(printf '%s' "$output" | grep -c '\$2y\$10')" -eq 0 ]
}

@test "dockerconfig transform builds a dockerconfigjson secret without leaking the token" {
  export GHCR_PULL_TOKEN="dummy-ghcr-pull"
  PATH="$TMP/bin:$PATH" run bun tools/seal-batch.ts --only prod-ghcr-pull --cert "$TMP/certA.pem" --out-dir "$TMP"
  [ "$status" -eq 0 ]
  [ -f "$TMP/platform/ghcr-pull/prod/ghcr-pull.sealed.yaml" ]
  [ "$(grep -c "dummy-ghcr-pull" "$TMP/platform/ghcr-pull/prod/ghcr-pull.sealed.yaml")" -eq 0 ]
  [ "$(printf '%s' "$output" | grep -c "dummy-ghcr-pull")" -eq 0 ]
}

@test "file transform rejects a FILES_KEYS_JSON that violates the contract" {
  export FILES_KEYS_JSON='{"not":"an-array"}'
  PATH="$TMP/bin:$PATH" run bun tools/seal-batch.ts --only files-keys --cert "$TMP/certA.pem" --out-dir "$TMP"
  [ "$status" -eq 1 ]
  echo "$output" | grep -qi "FILES_KEYS_JSON"
}

@test "file transform accepts a valid keys registry and never prints its contents" {
  export FILES_KEYS_JSON='[{"id":"admin","sha256":"deadbeef","service":"files"}]'
  PATH="$TMP/bin:$PATH" run bun tools/seal-batch.ts --only files-keys --cert "$TMP/certA.pem" --out-dir "$TMP"
  [ "$status" -eq 0 ]
  [ -f "$TMP/platform/files/prod/files-keys.sealed.yaml" ]
  [ "$(printf '%s' "$output" | grep -c "deadbeef")" -eq 0 ]
}

@test "group ghcr-pull seals BOTH prod and files planes (single rotation target)" {
  export GHCR_PULL_TOKEN="dummy-ghcr-pull"
  PATH="$TMP/bin:$PATH" run bun tools/seal-batch.ts --group ghcr-pull --cert "$TMP/certA.pem" --out-dir "$TMP"
  [ "$status" -eq 0 ]
  [ -f "$TMP/platform/ghcr-pull/prod/ghcr-pull.sealed.yaml" ]
  [ -f "$TMP/platform/files/prod/ghcr-pull.sealed.yaml" ]
}

@test "all seals every declared owner-local secret (rotation drill scope)" {
  export ADGUARD_PASSWORD="p1"; export TELEGRAM_BOT_TOKEN="t1"
  export GHCR_PULL_TOKEN="g1"; export FILES_KEYS_JSON='[{"id":"a","sha256":"b","service":"files"}]'
  PATH="$TMP/bin:$PATH" run bun tools/seal-batch.ts --all --cert "$TMP/certA.pem" --out-dir "$TMP"
  [ "$status" -eq 0 ]
  [ -f "$TMP/platform/adguard/prod/adguard-auth.sealed.yaml" ]
  [ -f "$TMP/platform/argocd/extras/argocd-notifications-secret.sealed.yaml" ]
  [ -f "$TMP/platform/files/prod/files-keys.sealed.yaml" ]
  [ -f "$TMP/platform/files/prod/ghcr-pull.sealed.yaml" ]
  [ -f "$TMP/platform/ghcr-pull/prod/ghcr-pull.sealed.yaml" ]
}

@test "preflight fails closed when the live cert cannot be fetched (offline exit 2 -> abort)" {
  export ADGUARD_PASSWORD="p1"
  # --fetch-cert가 실패(빈 출력)하도록 kubeseal 스텁 교체 → secret-cert-check exit 2
  printf '#!/bin/sh\ncase "$*" in *--fetch-cert*) exit 1;; *) cat;; esac\n' > "$TMP/bin/kubeseal"; chmod +x "$TMP/bin/kubeseal"
  PATH="$TMP/bin:$PATH" run bun tools/seal-batch.ts --only adguard-auth --cert "$TMP/certA.pem" --out-dir "$TMP"
  [ "$status" -ne 0 ]
  [ ! -f "$TMP/platform/adguard/prod/adguard-auth.sealed.yaml" ]
  echo "$output" | grep -qiE "preflight|중단|offline-ok"
}

@test "break-glass --offline-ok proceeds despite an offline preflight" {
  export ADGUARD_PASSWORD="p1"
  printf '#!/bin/sh\ncase "$*" in *--fetch-cert*) exit 1;; *) printf "apiVersion: bitnami.com/v1alpha1\\nkind: SealedSecret\\nmetadata:\\n  name: STUB\\nspec:\\n  encryptedData:\\n    STUB: xxx\\n";; esac\n' > "$TMP/bin/kubeseal"; chmod +x "$TMP/bin/kubeseal"
  PATH="$TMP/bin:$PATH" run bun tools/seal-batch.ts --only adguard-auth --cert "$TMP/certA.pem" --out-dir "$TMP" --offline-ok
  [ "$status" -eq 0 ]
  [ -f "$TMP/platform/adguard/prod/adguard-auth.sealed.yaml" ]
}
