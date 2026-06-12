#!/usr/bin/env bats
# provision-cache CLI — 앱별 경량 Valkey 인스턴스 산출 + prod conn SealedSecret 핸들 + 메모리
# 원장 게이트. DB 체인과 대칭: 비밀번호/URL 비노출, dry-run 무쓰기, 중복/예산 거부.
# kubeseal은 PATH 스텁(평문 stdin을 버리고 SealedSecret 모양만 출력)으로 대체한다.
# 주의: macOS bash 3.2에서 mid-test `[[ ]]`/`! cmd` 실패는 bats가 못 잡는다 —
# 단언은 전부 grep 파이프라인/`[ ]`/카운트 비교로 쓴다.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  TMP="$(mktemp -d)"
  FIX="$TMP/root"
  mkdir -p "$FIX/docs" "$FIX/platform/cache/prod" "$TMP/bin"
  # 원장 픽스처: 예산 8704Mi, 현재 limit 8000Mi — 기본(64Mi) 캐시는 들어가고 512Mi는 초과
  cat > "$FIX/docs/memory-ledger.md" <<'EOF'
# Memory Ledger (fixture)

<!-- ledger:meta VM_ALLOCATABLE_MIB=11264 LIMIT_BUDGET_MIB=8704 -->

| component                          | namespace      | req_mi | limit_mi |
|------------------------------------|----------------|-------:|---------:|
| <!-- ledger:row --> base           | kube-system    |   1000 |     8000 |

**합계:** req ≈ 1000 Mi · limit ≈ 8000 Mi (반드시 ≤ 8704 Mi 유지).
EOF
  # kubeseal 스텁: stdin(평문 Secret)을 전부 버리고 SealedSecret 모양만 출력 — 평문 비유출 단언용
  cat > "$TMP/bin/kubeseal" <<'EOF'
#!/bin/sh
cat > /dev/null
printf 'apiVersion: bitnami.com/v1alpha1\nkind: SealedSecret\nmetadata:\n  name: STUB\nspec:\n  encryptedData: {}\n'
EOF
  chmod +x "$TMP/bin/kubeseal"
  : > "$TMP/cert.pem"
}
teardown() { rm -rf "$TMP"; }

provision() {
  PATH="$TMP/bin:$PATH" run node "$ROOT/tools/provision-cache.mjs" \
    --repo-root "$FIX" --cert "$TMP/cert.pem" "$@"
}

@test "provision-cache renders a pinned valkey instance with cache semantics" {
  provision --name demo
  [ "$status" -eq 0 ]
  d="$FIX/platform/cache/prod/demo"
  grep -q "image: valkey/valkey:" "$d/deployment.yaml"                # 버전 핀
  [ "$(grep -c "valkey:latest" "$d/deployment.yaml")" -eq 0 ]         # latest 금지
  grep -q "maxmemory 64mb" "$d/configmap.yaml"                        # 기본 64Mi
  grep -q "maxmemory-policy allkeys-lru" "$d/configmap.yaml"
  grep -q "appendonly no" "$d/configmap.yaml"
  grep -qE "^[[:space:]]*save [0-9]+ [0-9]+" "$d/configmap.yaml"      # RDB 스냅샷 — 백업 체인의 전제
  grep -q "port: 6379" "$d/service.yaml"
  grep -q "storage: 1Gi" "$d/pvc.yaml"
}

@test "valkey pod is hardened (nonroot, no privilege escalation, read-only rootfs)" {
  provision --name demo
  [ "$status" -eq 0 ]
  d="$FIX/platform/cache/prod/demo/deployment.yaml"
  grep -q "runAsNonRoot: true" "$d"
  grep -q "allowPrivilegeEscalation: false" "$d"   # valkey는 setcap 바이너리가 아님 — 양립 가능
  grep -q "readOnlyRootFilesystem: true" "$d"
}

@test "memory limit keeps headroom above maxmemory and lands as a ledger row" {
  provision --name demo --maxmemory-mi 100
  [ "$status" -eq 0 ]
  row="$(grep 'ledger:row --> cache-demo' "$FIX/docs/memory-ledger.md")"
  [ -n "$row" ]
  echo "$row" | grep -q "| cache"
  limit="$(echo "$row" | awk -F'|' '{gsub(/ /,"",$5); print $5}')"
  [ "$limit" -gt 100 ]                              # limit > maxmemory (BGSAVE COW/단편화 여유)
  grep -q "limit ≈ $((8000 + limit)) Mi" "$FIX/docs/memory-ledger.md"  # 합계 프로즈 갱신
}

@test "conn handles are sealed into data-conn (prod ns) and acl into the instance dir" {
  provision --name demo
  [ "$status" -eq 0 ]
  grep -q "kind: SealedSecret" "$FIX/platform/data-conn/prod/cache-demo-conn.sealed.yaml"
  grep -q "kind: SealedSecret" "$FIX/platform/data-conn/prod/cache-demo-ro-conn.sealed.yaml"
  grep -q "kind: SealedSecret" "$FIX/platform/cache/prod/demo/acl.sealed.yaml"
  # *.enc.yaml(KSOPS) 산출 금지 — 캐시 체인은 SealedSecret만
  [ -z "$(find "$FIX" -name '*.enc.yaml')" ]
}

@test "raw passwords and redis URLs never reach stdout or the repo tree" {
  provision --name demo
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | grep -ci "redis://")" -eq 0 ]
  [ "$(grep -rli "redis://" "$FIX" | wc -l)" -eq 0 ]
  # 평문 Secret manifest는 kubeseal stdin으로만 흐른다 — 디스크에 stringData가 남으면 실패
  [ "$(grep -rl "stringData" "$FIX" | wc -l)" -eq 0 ]
}

@test "dry-run writes nothing but prints the plan json" {
  cp "$FIX/docs/memory-ledger.md" "$TMP/ledger.before"
  provision --name demo --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '"name": "demo"'
  [ ! -d "$FIX/platform/cache/prod/demo" ]
  [ ! -d "$FIX/platform/data-conn" ]
  cmp -s "$FIX/docs/memory-ledger.md" "$TMP/ledger.before"
}

@test "duplicate cache names are rejected" {
  provision --name demo
  [ "$status" -eq 0 ]
  provision --name demo
  [ "$status" -ne 0 ]
}

@test "ledger budget overrun is rejected before any write" {
  provision --name demo --maxmemory-mi 512
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "예산"
  [ ! -d "$FIX/platform/cache/prod/demo" ]
  [ "$(grep -c "cache-demo" "$FIX/docs/memory-ledger.md")" -eq 0 ]
}

@test "maxmemory outside 16..1024 and bad names are rejected" {
  provision --name demo --maxmemory-mi 8
  [ "$status" -ne 0 ]
  provision --name demo --maxmemory-mi 2048
  [ "$status" -ne 0 ]
  provision --name Demo
  [ "$status" -ne 0 ]
}

@test "instances register idempotently in the cache kustomization" {
  provision --name demo
  [ "$status" -eq 0 ]
  provision --name demo2
  [ "$status" -eq 0 ]
  k="$FIX/platform/cache/prod/kustomization.yaml"
  grep -q "namespace: cache" "$k"
  [ "$(grep -c -- "- demo$" "$k")" -eq 1 ]
  [ "$(grep -c -- "- demo2$" "$k")" -eq 1 ]
}

@test "existing data-conn kustomization gains entries; a missing one becomes a checklist item" {
  # 없는 경우: 등록하지 않고(kustomization 생성은 다른 작업자 소유) checklist에만 기재
  provision --name demo
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "data-conn"
  [ ! -f "$FIX/platform/data-conn/prod/kustomization.yaml" ]
  # 있는 경우: resources에 두 sealed 파일을 멱등 추가
  printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nnamespace: prod\nresources: []\n' \
    > "$FIX/platform/data-conn/prod/kustomization.yaml"
  provision --name demo2
  [ "$status" -eq 0 ]
  grep -q "cache-demo2-conn.sealed.yaml" "$FIX/platform/data-conn/prod/kustomization.yaml"
  grep -q "cache-demo2-ro-conn.sealed.yaml" "$FIX/platform/data-conn/prod/kustomization.yaml"
}

@test "provisioned instance renders via kustomize and passes kubeconform" {
  command -v kustomize >/dev/null || skip "kustomize not installed"
  command -v kubeconform >/dev/null || skip "kubeconform not installed"
  provision --name demo
  [ "$status" -eq 0 ]
  run bash -c "kustomize build '$FIX/platform/cache/prod' | kubeconform -strict -ignore-missing-schemas -summary"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF "Invalid: 0"
  run bash -c "kustomize build '$FIX/platform/cache/prod' | yq 'select(.kind==\"Deployment\") | .metadata.namespace'"
  [ "$output" = "cache" ]
}
