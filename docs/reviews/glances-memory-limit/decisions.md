# 리뷰 결정 원장 — glances-memory-limit

### release r1 (codex)

- F1 accept — Subtracting total cache hides unreclaimable tmpfs/shared memory
- F2 accept — The regression gate permits the supposedly unchanged threshold and duration to drift
- F3 defer — The load-bearing gate oracle bypasses the repository's typed-code boundary; 형제 발화 e2e 하네스 4개(adguard 1곳·gha-liveness 1곳·jobfailed 2곳)와 `*-gen.py` 4개가 모두 같은 패턴이라 이 하나만 TS로 옮기면 계열 일관성과 `tests/gates/lib/vmalert-e2e.sh`(`vme_*`) 재사용이 끊긴다. 하네스 계열 전체의 언어 이관은 이 버그픽스의 단일 행동 범위를 넘는 별도 작업으로 둔다.

#### 판정 근거(라이브 검증)

**F1 — 확증.** `database/pg-1`의 postgres가 `memory.stat:file 120.19Mi` 중 **shmem 38.00Mi**를 보유하고,
호스트는 swap이 0이라 그 38Mi는 회수 불가다. 그런데 r1 시점 expr(`usage − cache`)은 이를 통째로 빼서
limit 대비 3.9%로 보고했다(실제 회수 불가 7.6%). 리뷰어가 든 "shared memory로 94%를 쓰는 컨테이너가
0%에 가깝게 평가된다"는 시나리오가 이 레포에서 실재한다.
처방: 분자를 `usage − total_inactive_file − total_active_file`로 교체한다. cAdvisor가
`container_memory_total_{active,inactive}_file_bytes`를 실제로 노출하며(라이브 확인), 그 값은 cgroup
`memory.stat`과 일치한다. 이 분자는 파일 LRU에 있는 회수 가능분만 빼므로 shmem이 남는다 —
라이브 대조: glances 67.0%(변화 없음·침묵 유지) / postgres 3.9% → **7.6%**(shmem 회복).

**F2 — 부분 확증(임계 상향은 반증).** 리뷰어는 "임계를 0.95로 바꿔도 통과한다"고 했으나,
뮤테이션 실측 결과 하네스가 잡는다: `CONTRACT VIOLATION (preflight): 캐시-바운드 픽스처의 working_set
비율(0.883423) ≤ 임계(0.95) — 결함 expr조차 발화하지 않는 형상이라 L1/L3가 vacuous하다`.
preflight의 `CB_WS > T` 단언이 그 경로를 이미 fail-closed로 막는다.
다만 나머지 지적은 유효하다 — ⓐ 임계 **하향**(0.70)은 네 단언을 모두 통과해 안 잡히고, ⓑ `for:` 연장도
안 잡히며, ⓒ `diagnosis.md`가 "anon이 limit의 90%인 픽스처"라 적은 L2가 실제로는 95.3125%다.
처방: `T == 0.85`·`FOR == 10m`을 명시 대조하고(파생은 추출 실패 검출용으로 유지), 문서 수치를 정정한다.
값을 고정하면 룰이 바뀔 때 하네스가 조용히 낡는 대신 시끄럽게 실패한다 — 의도적 변경이면 하네스도
함께 갱신하라는 신호다.

### release r2 (codex)

findings 0건 · `verdict: approve`. r1의 F1·F2 처방을 재검증했고 새로 깨진 것도 없다.
게이트는 이 승인으로 통과한다(waiver 불요).
