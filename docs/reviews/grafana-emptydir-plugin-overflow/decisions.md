# 트리아지 결정 — grafana-emptydir-plugin-overflow

### release r1

아티팩트: `docs/reviews/grafana-emptydir-plugin-overflow/release-r1.json`
(`ok: true` · `verdict: needs-attention` · `codexStatus: 0` · `triageMode: human` · findings 2)

- **R-1 defer — The regression guard cannot detect recurrence of the diagnosed root cause**;
  사실관계는 맞고 이미 공개된 한계다(테스트 헤더의 `⚠️ 한계` 주석, 진단서 `## Seam` 절). 리뷰어 권고
  (a)"불변 페이로드(플러그인을 구운 핀 이미지 + preinstall 비활성)"는 Stage 1 게이트에서 선택지로 명시
  제시했고 사용자가 512Mi 범위를 골라 **명시적으로 미룬 범위**다. 지금 수용하면 `/bugfix`의 단일 동작
  플립을 깨고 리뷰되지 않은 `/deepen` 작업이 섞여 들어간다. 후속 과제로 이월:
  ① 페이로드 불변화(핀 이미지) ② emptyDir 사용률 관측(현재 `kubelet_volume_stats_*`는 PVC 전용이라
  emptyDir 지표가 없음 — `pvc-du-exporter` 확장 후보). 이월 사실은 `docs/traps-detail.md`의
  "emptyDir sizeLimit vs 런타임 다운로드 페이로드" 항목 마지막 불릿에도 기록했다.
- **R-2 accept — The new live-verified trap is omitted from the mandatory SSOT and enforcement ledger**;
  레포 규약이 명시적이고(`docs/traps.md`의 "새 가드 테스트를 추가하면 이 표에도 한 줄 추가한다") 직접
  검증했다 — 등록 전 `make verify-traps`는 exit 0으로 **통과**했는데, 이는 어디에도 언급되지 않은 신규
  가드가 자명하게 통과하기 때문이다(원장 헤더가 경고하는 "거짓 안심" 갭 그 자체). 적용:
  `docs/traps-detail.md` 섹션 추가(+ `> 가드:` 주석) · `docs/traps.md` 원장 행 추가 ·
  `AGENTS.md` 한줄 인덱스 추가. 검증: 카운트 52/52 정합 · `make verify-traps` OK ·
  `tests/gates/test_traps-sync.bats` 3/3 · `tests/gates/test_verify-traps.bats` 2/2 · `make verify` exit 0.

사용자 결정: `as proposed` (제안된 결정 열 그대로 — 추가로 제시했던 R-1b(라이브 posture 가드)는 미채택).

### release r2

아티팩트: `docs/reviews/grafana-emptydir-plugin-overflow/release-r2.json`
(`ok: true` · **`verdict: approve`** · `codexStatus: 0` · `triageMode: human` · findings 0)

R-2 수정 재검증 라운드. finding 0건으로 통과 — 트리아지할 행이 없다. 리뷰어 요약:
"R-2 is resolved: the trap is documented with its guard at docs/traps-detail.md:344-363, registered in
docs/traps.md:48, and indexed in AGENTS.md:108. Static verification confirmed 52/52 index parity,
bidirectional guard-ledger linkage, and CI collection of the new Bats test. No new critical or high
issue was introduced by this fix."

게이트 통과 조건 충족(`verdict: approve`) — waiver 없음.
