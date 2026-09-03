#!/usr/bin/env bats
# 고아 Released PV 감사 — fail-closed(깨진 감사 ≠ 고아 없음, F7). ⚠️ 중간 단언 [ ]만.
setup() { ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"; cd "$ROOT" || exit 1; }

@test "orphan storage audit surfaces Released PVs + PVCs no pod mounts and is fail-closed (broken audit != no orphans)" {
  S="$ROOT/scripts/audit-orphan-pv.sh"
  [ -x "$S" ]
  run grep -Eq 'status\.phase.*Released|"Released"' "$S"; [ "$status" -eq 0 ]      # Released 선택
  run grep -Eq 'command -v kubectl|command -v yq' "$S"; [ "$status" -eq 0 ]        # preflight
  run grep -Eq 'exit [23]' "$S"; [ "$status" -eq 0 ]                               # 실패는 비-0
  # 클러스터 없는 환경(CI)서 실행 → 비-0 + '고아 없음' 미출력(깨진 감사를 깨끗한 결과로 위장 안 함)
  run bash "$S"
  [ "$status" -ne 0 ]
  run grep -q '고아 없음' <<< "$output"
  [ "$status" -ne 0 ]   # 클러스터 부재 출력에 '고아 없음'이 있으면 실패(혼동 방지)
}

@test "an unreachable cluster is the skip convention, not a hard failure (kernel-followups 03)" {
  # 의미론 전환의 증인 — 접근·도구 부재는 red(2/3)가 아니라 skip(4 + 마커)이다. 로스터 등식
  # 게이트가 이 가드를 SKIP 대칭으로 제외하는 근거가 바로 이 rc다(venue 갈림 방지).
  run env KUBECONFIG=/nonexistent/kubeconfig bash "$ROOT/scripts/audit-orphan-pv.sh"
  [ "$status" -eq 4 ]
  echo "$output" | grep -q "^SKIP: audit-orphan-pv:"
  out="$output"
  run grep -q "^SCAN:" <<<"$out"
  [ "$status" -ne 0 ]
}

@test "a retired ORPHAN_PVC env floor is inert and --floor is the only override (vocabulary witness)" {
  # 폐지 env가 되살아나도 skip 경로 앞에서는 관측 불가지만, 오타 키 fail-closed는 라이브 무관하게
  # 파싱 시점에 검증된다 — 어휘 증인으로 이 축을 못박는다.
  run bash "$ROOT/scripts/audit-orphan-pv.sh" --floor bogus=1
  [ "$status" -eq 2 ]
  echo "$output" | grep -q "조용히 꺼진 바닥값"
}

# ── ② 소비-여부 축(cascade=orphan) — 위 3레인은 전부 클러스터 부재 skip(rc 4)에서 갈려 ①만
#    증언하고 :46-72(소비-여부 판정 본체)에 원리적으로 도달하지 못한다. 뮤테이션 실측
#    (2026-09-03): :63 `grep -qxF "$key" <<<"$used" || unconsumed=…`를 `grep -qxF "$key" <<<"$used"
#    || true`로 죽여도(shellcheck-clean — `used` 미사용 SC2034를 피한 형태) 위 3레인은 그대로 3 ok.
#    PATH kubectl 스텁으로 실제 판정 경로를 밟는다(형제 관용구: infra/k3s-bootstrap/tests/
#    test_08-bulk-gate.bats:24-49). yq는 스텁하지 않는다 — gate venue에 실물이 설치돼 있다.
stub_kubectl() {
  # $1 = 1: PVC 3건 전건이 파드에 마운트됨(양성 대조) / 0: obs/vlogs-0만 어떤 파드도 마운트하지
  # 않음(cascade=orphan 재현).
  B="$BATS_TEST_TMPDIR/bin"; mkdir -p "$B"
  if [ "$1" = "1" ]; then
    pod_json='{"items":[{"metadata":{"namespace":"obs"},"spec":{"volumes":[{"persistentVolumeClaim":{"claimName":"vlogs-0"}}]}},{"metadata":{"namespace":"obs"},"spec":{"volumes":[{"persistentVolumeClaim":{"claimName":"vmsingle-0"}}]}},{"metadata":{"namespace":"cache"},"spec":{"volumes":[{"persistentVolumeClaim":{"claimName":"valkey-0"}}]}}]}'
  else
    pod_json='{"items":[{"metadata":{"namespace":"obs"},"spec":{"volumes":[{"persistentVolumeClaim":{"claimName":"vmsingle-0"}}]}},{"metadata":{"namespace":"cache"},"spec":{"volumes":[{"persistentVolumeClaim":{"claimName":"valkey-0"}}]}}]}'
  fi
  cat > "$B/kubectl" <<EOF
#!/usr/bin/env bash
case "\$*" in
  "cluster-info") exit 0 ;;
  "get pv -o json") echo '{"items":[]}' ;;
  "get pvc -A -o json") echo '{"items":[{"metadata":{"namespace":"obs","name":"vlogs-0"}},{"metadata":{"namespace":"obs","name":"vmsingle-0"}},{"metadata":{"namespace":"cache","name":"valkey-0"}}]}' ;;
  "get pod -A -o json") echo '$pod_json' ;;
  *) echo "unstubbed kubectl call: \$*" >&2; exit 1 ;;
esac
EOF
  chmod +x "$B/kubectl"
}

@test "the consumer-check flags a Bound PVC that no pod mounts (cascade=orphan class)" {
  stub_kubectl 0
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run bash "$ROOT/scripts/audit-orphan-pv.sh"
  [ "$status" -eq 1 ]
  printf '%s' "$output" | grep -qF -- 'obs/vlogs-0'
}

@test "the consumer-check passes clean when every PVC is mounted by some pod" {
  stub_kubectl 1
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run bash "$ROOT/scripts/audit-orphan-pv.sh"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -qF -- '전건이 파드에 마운트됨'
}
