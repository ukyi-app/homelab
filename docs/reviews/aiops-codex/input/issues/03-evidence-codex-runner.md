# 03 — 선별 증거와 격리된 Codex 실행

Status: needs-info
Blocked by: Q13, 01
Design: [증거](../design.md#6-증거지식민감정보), [Codex 실행](../design.md#7-codex-실행과-검증)

## 결과

전용 실행 계정에서 `codex exec`가 선별 증거와 고정 homelab revision을 받아 구조화된
진단과 선택적 수정 초안을 만든다. Polyrelay를 설치하지 않고 실행 계약을 검증할 수 있다.

## 구현 범위

1. collector는 제한된 상태·메트릭·이벤트·선별 로그와 최신 Git 근거를 수집한다.
   생략/실패/잘림/낡은 문서/시드를 명시하고 Secret·연결 문자열·개인정보는 입력 전에 제외한다.
2. 신뢰된 coordinator가 source SHA·증거 manifest와 별도 작업 사본을 고정한다.
   homelab 전체 tracked 파일은 자료와 수정 대상으로 취급하되 repo 설정·hooks·MCP를
   실행 환경에 자동 로드하지 않는다. `.git`의 원격 자격이나 개인 홈을 상속하지 않는다.
3. 사건 실행 인터페이스를 구현한다. CLI 인자·JSONL 해석·취소·cleanup을 모듈 내부에 두고,
   첫 구현은 `codex exec` 하나로 제한한다. 시험용 fake 실행기는 내부 테스트 경계로 제공한다.
4. 구독 인증을 사용하는 엔진과 모델 도구의 읽기 권한을 분리한다. 고정 버전 permission
   profile·`never` 승인·환경/FD 정리를 적용하고 실제 인증 전 모의 자격 격리를 검증한다.
   legacy sandbox 옵션과 새 profile을 혼용하지 않는다.
5. 종료 코드·최종 JSON schema·source SHA·증거 ID·patch를 독립 확인한다. 증거 부족,
   외부 앱 원인, JSON 실패, auth/quota, timeout/OOM, 결과 불명을 구분한다. 실행 전 실패로
   확인된 일시 오류만 제한 재시도하며 인증/실행 여부가 불명하면 보류한다.

진단과 패치 생성의 Codex 단계는 합계 10분 제안이며 재시도도 01번 예산을 소비한다.
CLI/model/prompt/schema 버전과 확인된 usage를 기록하고 확인 불가 usage를 0으로 쓰지 않는다.
기존 `homelab mcp` 전체를 Codex에 연결하지 않는다.

## 완료 증거

fake 실행기로 시작 실패·유효/무효 JSON·terminal 없는 종료·부분 출력·timeout·cancel·
child cleanup을 검증한다. NUC의 실제 sandbox에서는 모의 자격의 직접 경로/symlink/proc/
환경/상속 FD/socket 접근 거부와 작업 사본 읽기·쓰기 성공을 확인한다. 이 증거 전에는
실제 구독 인증을 포함한 사건 처리를 활성화하지 않는다. 실제 모델의 진단 품질은 05번에서 평가한다.

## Comments

- 2026-09-12: 사용자 선택으로 직접 실행 파일럿 우선. Polyrelay 코드는 이 티켓에서 수정하지 않는다.
