#!/usr/bin/env bats
# fixture-memory-ratios.ts — 발화 e2e 픽스처의 메모리 비율 오라클.
# 이 코드는 vmalert-memory-nearlimit-firing-e2e.sh의 preflight가 "픽스처가 두 판정을 실제로 가른다"를
# 단언하는 근거다. 셸 heredoc의 인라인 python이던 동안 typecheck도 단위 테스트도 이것을 보지 못했다
# (PR #564 리뷰 F3). 오라클이 조용히 틀리면 비싼 replay 증거가 거짓 green이 된다 — 그래서 실패 경로마다
# 증인을 세운다.
# ⚠️ 중간 단언은 `[ ]`만 — bash 3.2에서 `[[ ]]` 실패가 침묵 통과한다. @test 이름은 영어(CJK 함정).

# ⚠️ **피연산자 실재 증인 + 거부 문구 양성 대조.** 이 파일의 검증 레인은 `[ "$status" -eq 1 ]`로
#    판정하는데, 도구가 없을 때 bun의 rc도 정확히 1이라 두 채널이 겹친다. 실측(2026-09-02,
#    `tools/fixture-memory-ratios.ts`를 지운 격리 트리): 10건 중 3건(#4 · #8 · #10)이 그대로 `ok`였다 —
#    그 셋은 `FAIL:` 문구를 물지 않았던 자리다.
setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  T="$ROOT/tools/fixture-memory-ratios.ts"
  [ -f "$T" ]
  F="$BATS_TEST_TMPDIR/fixture.jsonl"
}

# limit 128Mi 기준. usage/inactive/active/shmem을 받아 cache·working_set은 커널 항등식으로 채운다 —
# 픽스처 생성기(vmalert-memory-nearlimit-gen.py)와 같은 규율이라 여기서 모순 형상이 나오지 않는다.
_fixture() { # $1=container $2=usage $3=inactive $4=active $5=shmem [$6=limit]
  local c="$1" us="$2" ina="$3" act="$4" shm="$5" lim="${6:-134217728}"
  local cache=$(( ina + act + shm )) ws=$(( us - ina ))
  {
    printf '{"metric":{"__name__":"container_memory_usage_bytes","container":"%s"},"values":[%d]}\n' "$c" "$us"
    printf '{"metric":{"__name__":"container_memory_cache","container":"%s"},"values":[%d]}\n' "$c" "$cache"
    printf '{"metric":{"__name__":"container_memory_working_set_bytes","container":"%s"},"values":[%d]}\n' "$c" "$ws"
    printf '{"metric":{"__name__":"container_memory_total_inactive_file_bytes","container":"%s"},"values":[%d]}\n' "$c" "$ina"
    printf '{"metric":{"__name__":"container_memory_total_active_file_bytes","container":"%s"},"values":[%d]}\n' "$c" "$act"
    printf '{"metric":{"__name__":"kube_pod_container_resource_limits","container":"%s"},"values":[%d]}\n' "$c" "$lim"
  } > "$F"
}

@test "it reports the three ratios for a well-formed fixture" {
  # glances 라이브 실측 형상(2026-08-31 cgroup raw): usage 132878336 · inactive 14307328 · active 28622848 · shmem 0
  _fixture cachebound 132878336 14307328 28622848 0
  run bun "$T" --fixture "$F" --container cachebound
  [ "$status" -eq 0 ]
  # working_set 0.8834 · usage−cache 0.6702 · usage−inactive−active 0.6702 (shmem 0이라 뒤 둘이 같다)
  [ "$output" = "0.883423 0.670166 0.670166" ]
}

@test "shmem splits the two unreclaimable axes apart (the F1 regression anchor)" {
  # anon 20Mi인데 shmem 100Mi — cgroup v2의 file이 shmem을 포함하므로 usage−cache는 그 몫을 잃는다.
  _fixture shmembound $((123*1048576)) $((2*1048576)) $((1*1048576)) $((100*1048576))
  run bun "$T" --fixture "$F" --container shmembound
  [ "$status" -eq 0 ]
  # usage−cache = 15.6%(shmem 소실) vs usage−inactive−active = 93.75%(shmem 보존)
  [ "$output" = "0.945313 0.156250 0.937500" ]
}

@test "a missing metric fails closed and names what is absent" {
  _fixture cachebound 132878336 14307328 28622848 0
  grep -v container_memory_total_active_file_bytes "$F" > "$F.cut"
  mv "$F.cut" "$F"
  run bun "$T" --fixture "$F" --container cachebound
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'container_memory_total_active_file_bytes'
}

@test "an unknown container is a missing-metric failure, not an empty success" {
  _fixture cachebound 132878336 14307328 28622848 0
  run bun "$T" --fixture "$F" --container nosuchcontainer
  [ "$status" -eq 1 ]
  printf '%s' "$output" | grep -qF -- '메트릭 누락'
  # rc 0에 빈 출력이면 호출자가 빈 문자열을 비율로 읽는다 — 그것이 fail-open의 입구다.
  [ -n "$output" ]
}

@test "a working_set that breaks the kernel identity is rejected" {
  _fixture cachebound 132878336 14307328 28622848 0
  # working_set만 손으로 어긋나게 — usage − inactive_file 과 다른 값
  sed 's/"container_memory_working_set_bytes","container":"cachebound"},"values":\[[0-9]*\]/"container_memory_working_set_bytes","container":"cachebound"},"values":[99999999]/' "$F" > "$F.m"
  mv "$F.m" "$F"
  run bun "$T" --fixture "$F" --container cachebound
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'working_set'
}

@test "a cache smaller than its own LRU halves is rejected" {
  # cache < inactive+active — cgroup v2에서 성립할 수 없다(file = inactive + active + shmem).
  _fixture cachebound 132878336 14307328 28622848 0
  sed 's/"container_memory_cache","container":"cachebound"},"values":\[[0-9]*\]/"container_memory_cache","container":"cachebound"},"values":[1024]/' "$F" > "$F.m"
  mv "$F.m" "$F"
  run bun "$T" --fixture "$F" --container cachebound
  [ "$status" -eq 1 ]
  echo "$output" | grep -q '항등식'
}

@test "a zero limit is rejected before any division" {
  _fixture cachebound 132878336 14307328 28622848 0 0
  run bun "$T" --fixture "$F" --container cachebound
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'limit'
}

@test "usage flow control: working_set above usage is impossible" {
  # usage보다 큰 working_set — inactive_file이 음수여야 성립하므로 물리적으로 불가능하다.
  _fixture cachebound 1048576 0 0 0
  sed 's/"container_memory_working_set_bytes","container":"cachebound"},"values":\[[0-9]*\]/"container_memory_working_set_bytes","container":"cachebound"},"values":[99999999]/' "$F" > "$F.m"
  mv "$F.m" "$F"
  run bun "$T" --fixture "$F" --container cachebound
  [ "$status" -eq 1 ]
  printf '%s' "$output" | grep -qF -- '> usage('
}

@test "a flag error exits 2, distinct from a validation failure" {
  _fixture cachebound 132878336 14307328 28622848 0
  run bun "$T" --fixture "$F"
  [ "$status" -eq 2 ]
  run bun "$T" --fixture "$F" --container cachebound --bogus x
  [ "$status" -eq 2 ]
}

@test "an unreadable fixture fails closed" {
  run bun "$T" --fixture "$BATS_TEST_TMPDIR/nope.jsonl" --container cachebound
  [ "$status" -eq 1 ]
  printf '%s' "$output" | grep -qF -- '픽스처를 읽을 수 없다'
}
