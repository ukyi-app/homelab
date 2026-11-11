# C43 작업자 배포: 두 자격과 계정 묶음

- 단계: 8 한도 뒤 API 크레딧
- 상태: 대기 (선행: C39, C40, C41, C42)
- 명세: 봇 `docs/ai-bot/COLLEAGUE_SPEC.md`의 C38이 더한 절·AC(구/신 판 호환과 되돌리기)
- Blocked by: C39, C40, C41, C42
- 연결 AC: C38이 정한 번호(조사 AC-A11의 배포 쪽)
- 수행: 에이전트 + 사람(sandbox 배포 PR 검토·병합, 새 키 준비)
- 저장소·PR: homelab PR 하나(`platform/sandbox`, 사람 PR D2)
- 파일 소유: homelab `platform/sandbox/values.yaml`(두 digest와 "지금 값"·되돌리기 주석), ExternalSecret 템플릿·schema(계정 묶음 매핑), `tools/ci/` fixture, `docs/runbooks-public/`의 복구·교체 절
- 설계 계약: 조사 4.5, 4.6 ③, 6.2. 앞선 같은 종류 PR: homelab #1258, #1272.

## 목표

두 작업자가 옛 요청과 새 요청을 함께 받는 이미지로 뜨고, 계정 묶음을 읽을 수 있다. 기능은 꺼져 있다.

## 할 일

1. 선행 확인: C39~C41이 든 봇 main 빌드가 게시 서버에 먼저 배포돼 있다(받기부터). 새 원격 키가 필요하면 PR 병합 전에 사람이 준비한다(값은 저장소에 없음).
2. 두 digest를 그 빌드로 바꾸고 서명 확인 결과로 주석을 고친다.
3. ExternalSecret에 계정 묶음 매핑을 더한다. `CLAUDE_AUTH_METHOD`는 옛 판의 수동 기본값으로 남는다.
4. 되돌리기 순서 주석: 자동 사용 끄기와 구독 고정 → 새 판 요청·저장 결과 비우기 → 작업자 → 게시 서버.
5. PR 설명에 병합 전 사람 순서, 병합 뒤 볼 것(두 파드 Ready, 기동 로그, 구독 대화 1회), 되돌리는 법을 적는다.

## 완료 조건

- [ ] 병합 뒤 두 작업자가 새 이미지로 Ready이고 지금 구독 경로가 그대로 돈다(운영 읽기).
- [ ] `bun run ci` 통과, 공개 저장소 규칙 위반 없음.

## 검증

- 경계: S4(차트 렌더·schema), 운영 읽기. 명령: homelab `pre-commit run --files`, `bun run ci`.
- 잡는 실패: 매핑 누락, digest 불일치. 못 잡는 범위: 자동 사용 실동작(C45).

## 결과

(구현 뒤 채운다)
