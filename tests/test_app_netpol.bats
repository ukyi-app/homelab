#!/usr/bin/env bats
# app-owned NetworkPolicy app-scoped 셀렉터 가드 (blast radius 차단). @test 이름은 영어(CJK 함정).
# CI-safe(yq만, 라이브/age/docker 불요) → run-bats.sh gate 도메인에 자동 수집.
# ⚠️ 거부 레인의 `-ne 0`은 「가드가 셀렉터를 거부했다」와 「가드가 없어 bash가 죽었다」를 구별하지
#    못한다(실측: 스크립트 삭제 시 5레인 중 3개가 그대로 초록). 각 레인이 거부 문구
#    (check-app-netpol.sh의 `FAIL: app-owned NetworkPolicy는 app-scoped 셀렉터` 방출)를 물고,
#    setup이 피연산자 실재를 닫는다. 같은 fail-open은 그 스크립트의 `--root` 규약 주석이 이미
#    기록했지만 처방이 없었다.
# ⚠️ 강제하는 키는 **차트 SSOT에서 파생**된다(가드의 「인스턴스 라벨 키 파생」 절) — 이 파일은
#    그 파생값이 차트 selectorLabels와 같은지까지 본다. 리터럴을 여기 다시 적으면 그 사본이
#    갈라지는 것이 정확히 2026-09-03에 실측된 병이다(가드는 app.kubernetes.io/instance를 강제했고
#    차트는 app.homelab/instance를 냈다).
setup() { [ -f "${BATS_TEST_DIRNAME}/../scripts/check-app-netpol.sh" ]; }

# 차트 SSOT — 강제 키의 유일한 출처. 픽스처도 이 값에서 만든다(테스트가 리터럴을 들지 않는다).
_instance_key() {
  awk '
    /^\{\{- define "app\.selectorLabels"/ { inblk = 1; next }
    inblk && /^\{\{- end/                 { inblk = 0 }
    inblk && index($0, "{{ .Release.Name }}") > 0 { sub(/:.*/, "", $0); print $0; exit }
  ' "${BATS_TEST_DIRNAME}/../platform/charts/app/templates/_helpers.tpl"
}

@test "current repo passes (in-repo apps own no broad NetworkPolicy)" {
  run bash "${BATS_TEST_DIRNAME}/../scripts/check-app-netpol.sh"
  echo "$output"
  [ "$status" -eq 0 ]
}

# 헬퍼: 임시 트리에 apps/<app>/deploy/prod/netpol.yaml(주어진 podSelector) 구성.
# 스크립트를 복사하지 않는다 — 실 스크립트를 `--root <픽스처>`로 부른다. 가드가 공유 워커를 자기
# 실제 위치 기준으로 찾기 때문에, 복사본은 워커를 못 찾는다(스캔 대상 트리와 도구 위치의 분리).
_seed() {
  local root="$1" app="$2" selector="$3" kindline="${4:-kind: NetworkPolicy}"
  mkdir -p "$root/apps/$app/deploy/prod"
  cat > "$root/apps/$app/deploy/prod/netpol.yaml" <<YAML
apiVersion: networking.k8s.io/v1
$kindline
metadata: { name: $app-egress, namespace: prod }
spec:
  podSelector: $selector
  policyTypes: [Egress]
YAML
  # 워커의 apps-manifests 스코프는 tracked 열거다 — 픽스처도 추적 파일이어야 한다.
  git -C "$root" init -q; git -C "$root" add -A
}

@test "guard fails on empty podSelector (selects all pods in shared ns)" {
  tmp="$(mktemp -d)"
  _seed "$tmp" foo '{}'
  run bash "${BATS_TEST_DIRNAME}/../scripts/check-app-netpol.sh" --root "$tmp"
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- 'FAIL: app-owned NetworkPolicy는 app-scoped 셀렉터'
}

@test "guard fails on empty podSelector even when kind is quoted (kind: \"NetworkPolicy\")" {
  # grep-a-4 — 프리필터가 리터럴 `^kind:[[:space:]]*NetworkPolicy`라 인용 표기 파일은 후보에서
  # 통째로 빠져 뒤의 yq 판정에 도달 못 했다(도달 못 하면 빈 podSelector도 초록). 합법 YAML이고
  # kustomize/ArgoCD는 정상 적용하므로 프리필터가 관용해야 한다(check-app-deploy.sh 표기와 동형).
  tmp="$(mktemp -d)"
  _seed "$tmp" foo '{}' 'kind: "NetworkPolicy"'
  run bash "${BATS_TEST_DIRNAME}/../scripts/check-app-netpol.sh" --root "$tmp"
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- 'FAIL: app-owned NetworkPolicy는 app-scoped 셀렉터'
}

@test "guard fails on name-only selector (chart name is shared, non-unique)" {
  tmp="$(mktemp -d)"
  _seed "$tmp" foo '{ matchLabels: { "app.kubernetes.io/name": app } }'
  run bash "${BATS_TEST_DIRNAME}/../scripts/check-app-netpol.sh" --root "$tmp"
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- 'FAIL: app-owned NetworkPolicy는 app-scoped 셀렉터'
}

@test "guard fails when instance label does not match the app directory" {
  key="$(_instance_key)"
  [ -n "$key" ]
  tmp="$(mktemp -d)"
  _seed "$tmp" foo "{ matchLabels: { \"$key\": bar } }"
  run bash "${BATS_TEST_DIRNAME}/../scripts/check-app-netpol.sh" --root "$tmp"
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- 'FAIL: app-owned NetworkPolicy는 app-scoped 셀렉터'
}

@test "guard passes when instance label equals the app directory (unique app-scoped)" {
  key="$(_instance_key)"
  [ -n "$key" ]
  tmp="$(mktemp -d)"
  _seed "$tmp" foo "{ matchLabels: { \"$key\": foo } }"
  run bash "${BATS_TEST_DIRNAME}/../scripts/check-app-netpol.sh" --root "$tmp"
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -eq 0 ]
}

# ── 키 정렬(2026-09-03) ────────────────────────────────────────────────────────────────────────
@test "the enforced key is the chart selector key, not the ArgoCD-reserved standard one" {
  # 병의 두 얼굴: ① 차트 실제 키를 쓴 netpol이 거부됐다 ② 차트가 내지 않는 표준 키를 쓴 netpol이
  # 통과했다(그 셀렉터는 라이브에서 아무 파드도 선택하지 못한다 — 거짓 안심).
  key="$(_instance_key)"
  [ "$key" = "app.homelab/instance" ]   # 오늘의 실측값 — 파생이 무너지면 여기서 먼저 죽는다
  tmp="$(mktemp -d)"
  _seed "$tmp" foo '{ matchLabels: { "app.kubernetes.io/instance": foo } }'
  run bash "${BATS_TEST_DIRNAME}/../scripts/check-app-netpol.sh" --root "$tmp"
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- 'FAIL: app-owned NetworkPolicy는 app-scoped 셀렉터'
}

@test "the guard reports the derived key in its diagnostic (the fix is nameable)" {
  key="$(_instance_key)"
  tmp="$(mktemp -d)"
  _seed "$tmp" foo '{}'
  run bash "${BATS_TEST_DIRNAME}/../scripts/check-app-netpol.sh" --root "$tmp"
  echo "$output"
  rm -rf "$tmp"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- "$key"
}

@test "the derived key follows a chart rename (the anchor is the value, not the key name)" {
  # 앵커가 키 이름이면 차트 개명 한 번에 파생이 조용히 0건이 된다 — 값 `{{ .Release.Name }}`이
  # 앵커라는 사실은 개명 픽스처로만 증인이 선다(오늘 키를 그대로 쓰는 레인은 이 조건을 밟지 못한다).
  fake="$(mktemp -d)"
  mkdir -p "$fake/scripts" "$fake/platform/charts/app/templates"
  cp "${BATS_TEST_DIRNAME}/../scripts/check-app-netpol.sh" "$fake/scripts/"
  ln -s "$(cd "${BATS_TEST_DIRNAME}/../scripts/lib" && pwd)" "$fake/scripts/lib"
  ln -s "$(cd "${BATS_TEST_DIRNAME}/../tools" && pwd)" "$fake/tools"
  printf '%s\n' '{{- define "app.selectorLabels" -}}' 'app.kubernetes.io/name: x' \
    'app.homelab/release: {{ .Release.Name }}' '{{- end -}}' \
    > "$fake/platform/charts/app/templates/_helpers.tpl"
  tmp="$(mktemp -d)"
  _seed "$tmp" foo '{ matchLabels: { "app.homelab/release": foo } }'
  run bash "$fake/scripts/check-app-netpol.sh" --root "$tmp"
  echo "$output"
  [ "$status" -eq 0 ]
  # 대조군 — 개명 전 키를 쓴 netpol은 같은 트리에서 거부된다(파생이 실제로 옮겨갔다).
  rm -rf "$tmp"; tmp="$(mktemp -d)"
  _seed "$tmp" foo '{ matchLabels: { "app.homelab/instance": foo } }'
  run bash "$fake/scripts/check-app-netpol.sh" --root "$tmp"
  echo "$output"
  rm -rf "$tmp" "$fake"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- 'app.homelab/release'
}

@test "a chart helper whose instance line is gone fails closed instead of enforcing nothing" {
  # 파생이 0건이면 "강제할 키가 없다"가 아니라 판정 불가다 — 빈 키로 계속 돌면 전건 위반이거나
  # 전건 통과가 되고, 어느 쪽이든 그 판정은 근거가 없다.
  fake="$(mktemp -d)"
  mkdir -p "$fake/scripts" "$fake/platform/charts/app/templates" "$fake/tools/lib"
  cp "${BATS_TEST_DIRNAME}/../scripts/check-app-netpol.sh" "$fake/scripts/"
  cp -r "${BATS_TEST_DIRNAME}/../scripts/lib" "$fake/scripts/lib"
  printf '%s\n' '{{- define "app.selectorLabels" -}}' 'app.kubernetes.io/name: x' '{{- end -}}' \
    > "$fake/platform/charts/app/templates/_helpers.tpl"
  run bash "$fake/scripts/check-app-netpol.sh"
  echo "$output"
  rm -rf "$fake"
  [ "$status" -eq 1 ]
  printf '%s' "$output" | grep -qF -- '인스턴스 라벨 키를 파생하지 못했다'
}
