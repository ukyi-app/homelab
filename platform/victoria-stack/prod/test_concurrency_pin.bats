#!/usr/bin/env bats
# D-e 동시성 핀 가드 (2026-08-14 NUC 콜드스타트 OOM 루프에서 나온 것).
#
# vector(tokio)와 VictoriaLogs(Go)는 **노드 코어 수에 비례해 메모리를 잡는다** — 워커별 버퍼,
# P별 mcache/스택 캐시. 그런데 이 컴포넌트들의 memory limit은 **라이브 Mac(6코어) 실측**으로
# 산정됐다. 코어가 더 많은 노드에 그대로 얹으면 limit이 그대로 OOM 선이 된다.
# 2026-08-14 NUC(14코어) 실측 — 커널 OOM 기록의 anon-rss:
#   vector       ~325MiB (limit 320Mi) · worker 스레드 15개 · 2시간에 22회 OOMKilled
#   victorialogs ~128MiB (limit 128Mi) · 2시간에 16회 OOMKilled
# 같은 매니페스트가 Mac에서는 각각 steady ~145Mi / peak 59Mi로 돈다.
# ⚠️ GOMEMLIMIT은 **힙 소프트 리밋**이라 이 비-힙 증가를 막지 못한다 — 핀이 따로 필요하다.
# ⚠️ 핀 값 6은 limit을 검증한 기준선(Mac 코어 수)이다. 올리려면 limit + docs/memory-ledger.md
#    행을 함께 재산정할 것.
# (@test 이름은 영어 — 디렉토리 단위 실행 시 한글이 인코딩 깨짐. 중간 단언은 [ ]/단순 명령만.)

setup() { D="$(cd "$BATS_TEST_DIRNAME" && pwd)"; }

@test "vector pins its tokio worker count to the core budget its memory limit was sized against" {
  # ⚠️ env(VECTOR_THREADS)가 아니라 CLI 플래그여야 한다 — 이름이 틀리면 즉시 기동 실패로 드러난다.
  #    env 오타는 조용히 무시되어 "핀했다고 믿는" 상태를 만든다.
  t="$(yq '.spec.template.spec.containers[] | select(.name == "vector") | .args | to_entries | .[] | select(.value == "--threads") | .key + 1' "$D/vector.yaml")"
  [ -n "$t" ]
  v="$(yq ".spec.template.spec.containers[] | select(.name == \"vector\") | .args[$t]" "$D/vector.yaml")"
  printf '%s' "$v" | grep -qxF -- '6'
  # limit이 함께 바뀌지 않았는지 — 핀과 limit은 같은 기준선에서 나온 짝이다.
  l="$(yq '.spec.template.spec.containers[] | select(.name == "vector") | .resources.limits.memory' "$D/vector.yaml")"
  printf '%s' "$l" | grep -qxF -- '320Mi'
}

@test "victorialogs pins GOMAXPROCS (GOMEMLIMIT is a heap-only soft limit and cannot cover it)" {
  p="$(yq '.spec.template.spec.containers[] | select(.name == "victorialogs") | .env[] | select(.name == "GOMAXPROCS") | .value' "$D/victorialogs.yaml")"
  printf '%s' "$p" | grep -qxF -- '6'
  # GOMEMLIMIT은 남아 있어야 한다(힙 쪽 방어) — 핀이 그것을 대체하지 않는다.
  m="$(yq '.spec.template.spec.containers[] | select(.name == "victorialogs") | .env[] | select(.name == "GOMEMLIMIT") | .value' "$D/victorialogs.yaml")"
  printf '%s' "$m" | grep -qxF -- '115MiB'
  l="$(yq '.spec.template.spec.containers[] | select(.name == "victorialogs") | .resources.limits.memory' "$D/victorialogs.yaml")"
  printf '%s' "$l" | grep -qxF -- '128Mi'
}

@test "both pins agree on the same core budget (a split baseline is a silent regression)" {
  vt="$(yq '.spec.template.spec.containers[] | select(.name == "vector") | .args | to_entries | .[] | select(.value == "--threads") | .key + 1' "$D/vector.yaml")"
  a="$(yq ".spec.template.spec.containers[] | select(.name == \"vector\") | .args[$vt]" "$D/vector.yaml")"
  b="$(yq '.spec.template.spec.containers[] | select(.name == "victorialogs") | .env[] | select(.name == "GOMAXPROCS") | .value' "$D/victorialogs.yaml")"
  [ -n "$a" ]
  printf '%s' "$b" | grep -qxF -- "$a"
}
