#!/usr/bin/env bats
# M0 부트스트랩(scripts/bootstrap.sh)의 helm 실패 fail-closed 회귀를 오프라인에서 강제한다.
# ⚠️ 이 파일은 스크립트를 실제로 실행한다 — 그러나 helm·kubectl은 PATH 스텁으로 대체돼 라이브
#    클러스터엔 절대 닿지 않는다(destroy-node.sh 테스트의 argv 기록기 관용구와 동형: 실 저장소
#    파일(CHART_VERSION 등)은 그대로 읽되 PATH만 스텁 디렉토리를 앞에 둔다).
# ⚠️ **회귀 배경(:24 주석):** "helm 실패가 grep 파이프라인+|| true에 삼켜져 exit 0으로 위장됐던
#    라이브 버그" — 이 가드가 없던 시절, helm install 실패가 `... | grep ... || true`에 먹혀 rc 0으로
#    "bootstrap complete"까지 찍혔다. 지금은 :29-30이 명시적으로 fail-closed지만, 이를 실행-검증하는
#    @test가 레포에 0개였다(git grep이 찾는 test_makefile·test_check-doc-index·test_make-ops-targets는
#    전부 `make -n`(dry-run) 또는 문서 인덱스만 본다; infra/_tests/test_bootstrap.bats는 tests/.ci-exclude
#    manual venue의 라이브 DR idempotency 드릴이라 helm 실패 경로 자체를 원리적으로 못 본다).
sh=scripts/bootstrap.sh

_fixture() {
  FX="$BATS_TEST_TMPDIR/fx$RANDOM"
  mkdir -p "$FX/bin"
  # 실 sops age 키를 요구하지 않는다 — SOPS_AGE_KEY_FILE만 이 더미로 오버라이드.
  printf 'dummy-age-key-fixture\n' > "$FX/keys.txt"
  # helm 스텁 — repo add/update는 성공(그래야 :25의 목표 줄까지 도달한다, va.corrected_fix 경고:
  # `helm repo update`에 `|| true`가 없어 여기서 실패하면 set -e가 먼저 죽는다), upgrade --install만
  # HELM_INSTALL_RC로 제어한다.
  cat > "$FX/bin/helm" <<'HELM'
#!/usr/bin/env bash
case "$*" in
  *"repo add"*|*"repo update"*) exit 0 ;;
  *"upgrade --install"*)        exit "${HELM_INSTALL_RC:-0}" ;;
  *"status"*)                   echo "STATUS: deployed"; exit 0 ;;
  *)                             exit 0 ;;
esac
HELM
  chmod +x "$FX/bin/helm"
  # kubectl 스텁 — no-op(destroy-node.sh 테스트의 kubectl 무해화 관용구). ns/secret/apply 전부
  # 인자를 무시하고 성공만 낸다 — 라이브 클러스터에 어떤 요청도 나가지 않는다.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$FX/bin/kubectl"
  chmod +x "$FX/bin/kubectl"
  PATH="$FX/bin:$PATH"
  export FX PATH
}

@test "bootstrap exists, is executable, and passes shellcheck" {
  [ -x "$sh" ]
  run shellcheck "$sh"
  [ "$status" -eq 0 ]
}

@test "bootstrap FAILS CLOSED when helm install fails (no swallowed exit 0 — regression guard)" {
  _fixture
  run env -u KUBECONFIG HELM_INSTALL_RC=1 SOPS_AGE_KEY_FILE="$FX/keys.txt" bash "$sh"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | grep -qF -- 'FATAL: argo-cd helm install failed'
  # 옛 버그 패턴의 증상: 실패했는데도 뒷단계까지 흘러 "bootstrap complete"가 찍히면 회귀다.
  run bash -c "printf '%s' \"\$1\" | grep -qF -- 'bootstrap complete'" _ "$output"
  [ "$status" -eq 1 ]
}

@test "bootstrap completes when helm install succeeds (positive control — not an always-fail stub)" {
  _fixture
  run env -u KUBECONFIG HELM_INSTALL_RC=0 SOPS_AGE_KEY_FILE="$FX/keys.txt" bash "$sh"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF -- 'bootstrap complete'
}
