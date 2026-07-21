# Triage 결정 — bump-poll-ruleset (F-0)

### plan r1

R-1 accept — R-46 is neither blocked nor neutralized; spec의 "중화(neutralize)" 표현 제거, "F-0은 비-writer의 ref 생성/push/삭제만 닫고 R-46은 좁혀졌으나 원천 차단 안 된 명시적 수용 잔여"로 정정; 실행기 재조회 보존; `tools/ensure-bump-pr.ts` R-46 주석은 Stage 4에서 완화; 랜딩된 `docs/bugfixes/bump-poll-duplicate-pr.md`(역사 기록)는 미수정.
R-2 accept — rollout has no safe deletion fallback; 해소 경로 (b): 이번 increment는 creation+update만 배포, deletion=true는 멱등 writer-App 정리 경로 설계·검증 후 후속 increment로 연기.
