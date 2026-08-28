# prescription-reach — 게이트 결정 원장

### design r1 (codex)

- F1 accept — The proposed witness never checks the derived Terraform state key (high)
- F2 accept — The canonical versions syntax does not actually equal Bash `source` semantics (medium)
- F3 accept — The permanent ABS guard omits the acknowledged empty-domain failure mode (medium)

**F3 처방 선택 기록**: 권고는 두 갈래였다 — ⓐ 카디널리티를 검증하는 헬퍼, ⓑ 가드/회계 모델을 확장해
재귀·루프 구동 스캔에 기계 판독 가능한 floor와 양성 증인을 요구. **ⓑ를 택했다.** ⓐ는 이 패스의 적대
검증이 deletion test로 죽인 `tests/lib/absent.sh`를 되살리는 방향이라 두 판정이 충돌하고, ⓑ는 프리미티브
없이 같은 구멍을 닫으면서 형태 판정이라 「열거 붕괴」 축도 피한다. 결정 자체는 accept이고, 갈래 선택은
설계(§02)에 근거와 함께 기록했다.

반영 위치: F1 → `design.md` §13 · F2 → §04 · F3 → §02.

### design r2 (codex)

발견 0건 · `verdict: approve`. r1에서 Accept한 세 건이 전부 resolved로 재검증됐고, 수정이 새 critical·high
회귀를 만들지 않았으며 증인을 약화·생략·삭제하지 않았다는 것이 함께 확인됐다. 게이트 통과.
