#!/usr/bin/env bats
# D-e 동시성 핀 가드 (2026-08-14 NUC 콜드스타트 OOM 루프에서 나온 것).
#
# vector(tokio)와 VictoriaLogs(Go)는 **가용 코어 수만큼 워커/P를 띄운다**(NUC 14코어에서 vector
# 워커 15개 확인). 기준선(라이브 Mac 6코어)에 묶어 두는 **위생 조치**이고, 이 파일은 그 핀과
# 짝이 되는 limit이 함께 움직이도록 잠근다.
# ⚠️ **핀은 2026-08-14 NUC OOM 루프의 원인이 아니었다** — 핀을 넣어 워커를 15→8로 줄였는데
#    커널 OOM 기록의 anon-rss는 vector 325324 kB로 핀 전(325080·325136·325160·325056)과 동일했다.
#    실제 원인은 limit 자체였다: vlogs는 128Mi 안에 인제스션 작업집합이 안 들어갔고(캐시만 80.5MB),
#    vector는 그 vlogs가 죽어 sink 백프레셔로 미전송 배치를 쌓다 죽는 **결합 루프**였다.
#    ⇒ vlogs 128→256Mi · vector 320→512Mi로 상향(docs/memory-ledger.md 행 동반).
# ⚠️ GOMEMLIMIT은 **힙 소프트 리밋**이라 비-힙 증가를 막지 못한다 — limit과 별개로 유지한다.
# ⚠️ 핀 값 6과 limit은 같은 기준선에서 나온 짝이다. 어느 한쪽만 바꾸지 말 것.
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
  printf '%s' "$l" | grep -qxF -- '512Mi'
}

@test "victorialogs pins GOMAXPROCS (GOMEMLIMIT is a heap-only soft limit and cannot cover it)" {
  p="$(yq '.spec.template.spec.containers[] | select(.name == "victorialogs") | .env[] | select(.name == "GOMAXPROCS") | .value' "$D/victorialogs.yaml")"
  printf '%s' "$p" | grep -qxF -- '6'
  # GOMEMLIMIT은 남아 있어야 한다(힙 쪽 방어) — 핀이 그것을 대체하지 않는다.
  m="$(yq '.spec.template.spec.containers[] | select(.name == "victorialogs") | .env[] | select(.name == "GOMEMLIMIT") | .value' "$D/victorialogs.yaml")"
  printf '%s' "$m" | grep -qxF -- '230MiB'
  l="$(yq '.spec.template.spec.containers[] | select(.name == "victorialogs") | .resources.limits.memory' "$D/victorialogs.yaml")"
  printf '%s' "$l" | grep -qxF -- '256Mi'
}

@test "both pins agree on the same core budget (a split baseline is a silent regression)" {
  vt="$(yq '.spec.template.spec.containers[] | select(.name == "vector") | .args | to_entries | .[] | select(.value == "--threads") | .key + 1' "$D/vector.yaml")"
  a="$(yq ".spec.template.spec.containers[] | select(.name == \"vector\") | .args[$vt]" "$D/vector.yaml")"
  b="$(yq '.spec.template.spec.containers[] | select(.name == "victorialogs") | .env[] | select(.name == "GOMAXPROCS") | .value' "$D/victorialogs.yaml")"
  [ -n "$a" ]
  printf '%s' "$b" | grep -qxF -- "$a"
}
