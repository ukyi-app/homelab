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
