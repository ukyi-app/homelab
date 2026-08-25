# ts-scan-kernel — 게이트 트리아지 결정 원장

### design r1 (codex)

- F1 Accept (부분) — The migration gate can silently lose kernel consumers; 권고 3개 중 **negative gate만**
  채택한다. AST 기반 발견은 검출 메커니즘을 바꿀 뿐 구멍(우회한 가드가 정적·런타임 집합에서 동시에
  사라진다)을 막지 못하고 범위를 넓힌다. 여유 없는 정확한 커버리지 기대값은 이 레포가 명시적으로
  기각한 패턴이다(커널 주석의 실측 — 주석 "11종/27종" vs 실제 13종/31종).
- F2 Accept — Malformed floor values remain fail-open; 실측 재현 완료
  (`DISK_CAP_MIN_FLAGS=abc` → SCAN 방출 + rc=0). 유효성 판정을 커널 계약에 넣고, 바이트 동일하게
  복제된 `positiveInt` 2벌을 흡수해 미적용 2곳을 덮는다. 거부 종료코드는 2(바닥값 실패의 1과 구별).

### design r2 (codex)

- G1 Accept — Kernel-side validation cannot reject an empty floor after coercion; 실측 재현 완료
  (`--min-refs ""` → 지금은 거부 / `--min-scan ""` → 지금도 통과). `Number("")===0`이라 숫자 계약만으로는
  의도적 0과 빈 입력을 구별할 수 없고, 0은 정당한 바닥값이라 금지로 피할 수도 없다. r1 F2의 처방을
  그대로 두면 **현재 정확한 두 곳(`check-image-ownership`·`check-workflow-readiness`)에 회귀가 난다.**
  → 커널 표면에 `parseFloor(raw, source)`를 세 번째 함수로 추가해 coercion 앞에서 판정하고, 주입 지점
  넷을 모두 그 경로로 모은다. 명시적 `"0"`은 통과. `scanFloor` 안의 숫자 검증은 상수 주입 경로를 덮는
  안전망으로 남긴다. 기존 `positiveInt` 제거는 빈 문자열 exit 2 테스트가 green이 된 뒤로 순서를 건다.

WAIVED by user: G1의 처방이 리뷰어 권고의 자구 채택(coercion 앞 검증 · 네 주입 지점 수렴 · 명시적 0 유지 ·
기존 파서 제거 전 증명)이라 설계 재량이 없어, 라운드 상한(2) 도달 상태에서 재리뷰 없이 종결한다.
r1의 F1·F2는 r2가 해소를 확인했다(r2가 그 둘을 다시 열지 않았다).

### 티켓 01 코드리뷰 (2축 — Standards · Spec)

설계 게이트가 아니라 구현 리뷰다. `/code-review`가 두 축을 병렬 서브에이전트로 돌렸다.

- **H1 Accept (설계 뒤집음)** — `tools/lib/` 커널 규율 위반: `process.exit`는 콜사이트 소유.
  grilling Q3이 "커널이 exit을 소유한다"로 정했고 게이트 r1·r2가 통과시켰으나, 이 레포가 네 곳
  (`tools/README.md` · `image-pin.ts` · `repo-walk.ts` · `sealed-contract.ts`)에 정반대를 명시한다.
  셸 동형을 논거로 삼았지만 셸 커널은 `scripts/lib/`이고 TS `tools/lib/`는 다른 규율이다.
  → `ScanError` throw + 콜사이트 종료로 전환. `ScanOpts.exitCode`가 소멸하고(Speculative Generality
  동시 해소) 테스트가 프로세스 기동 없이 예외를 직접 본다. 회귀 증인은 "커널이 종료하지 않는다"를
  정적으로 단언하는 테스트다(뮤테이션: 종료를 도로 가져가면 4건 red).
- **H2 Accept** — 새 인식 단언 2개가 vacuous. `SCAN_NEW_RE`를 매치 0으로 변조해도 27건 전부 green
  (실측 재현). 검증이 기준을 대상과 **같은 깨진 패턴**에서 뽑아 0회 반복했다. 14번 테스트를 13번으로
  통합하면서 `[ -n "$new_files" ]` 바닥값을 함께 지운 것이 원인이다 — 그 단언이 이 구멍을 막고 있었다.
  → 신형 열거에 바닥값 복원. 같은 변조가 이제 red다.
- **판정① Accept(부분)** — 셸·TS 이중 구현 면제는 성립하나, 근거로 적은 "셸 가드는 TS 커널을 부를 수
  없다"가 **거짓**이었다(`repo-walk.ts`의 `import.meta.main` CLI를 셸 가드 셋이 실제로 부른다).
  → 진짜 근거로 교체: 불가능이 아니라 **종료 제어가 프로세스 경계를 못 건넌다**는 것.
- **Spec (a)1 Accept** — 티켓이 "가장 위험한 가정"으로 지목한 바닥값 분리 경로에 회귀 증인이 없었다.
  → 바닥값과 위반이 둘 다 참인 경로 테스트 추가(뮤테이션으로 3건 red 확인).
- **Spec (a)2 Accept** — 카운트 레시피가 `scripts/lib/scan-floor.sh`에도 있는데 안 고쳤다(실측 5 vs 6).
  "아무도 대조하지 않는 손 관리 수치는 반드시 드리프트한다"고 경고하는 그 문단이 드리프트했다.
- **냄새 Refused Bequest Accept** — `scanSignal`이 `ScanOpts` 전체를 받아 `exitCode`를 조용히 무시했다.
  → `SignalOpts`(`quiet`만)로 좁힘.
- **Spec (b) 판정: 범위 초과 아님** — `ScanOpts.hint`는 커널이 종료를 소유하면 콜사이트가 진단을 보탤
  수 없어 도메인 힌트가 소실되는 것을 막는다(throw 전환 후에도 유효 — 예외 메시지에 실린다).
  `CONTRIBUTING.md` 변경은 이 커널이 만든 문서 부정합(레시피 undercount·이중 구현 조항)의 해소다.
  티켓 02~06 침범 없음, `positiveInt` 2벌 그대로 → r2 순서 제약 준수.
