# 04 — 독립 검증과 fork Draft PR·Telegram 게시

Status: needs-info
Blocked by: Q13, 01, 03
Design: [검증](../design.md#7-codex-실행과-검증), [게시](../design.md#8-githubtelegram-게시)

## 결과

같은 검증 산출물로 전용 fork의 Draft PR과 Telegram 요약을 만든다. PR 응답 유실이나
Telegram 전송 실패가 모델 재실행·중복 PR로 이어지지 않는다. 패치가 없으면 진단을 보고한다.

## 구현 범위

1. 후보가 수정할 수 없는 신뢰된 기준 revision의 검사 진입점을 사용한다. 변경 종류에 맞는
   기존 gate를 운영 자격 없는 환경에서 실행하고 미실행·SKIP·실패를 구분한다.
2. 진단의 근거 참조, base SHA, patch와 결과 manifest hash, 비민감 공개 내용을 확인한다.
   secret 필요·지원 밖 변경을 보류하고 정책/ADR/CI 변경의 효과를 리뷰에 명시한다.
   전체 파일 초안 권한을 임의 path allowlist로 축소하지 않는다.
3. 별도 게시 사본에서 검증된 patch를 적용한다. repo ID·base main·fork·branch prefix를
   신뢰된 설정으로 고정하며 후보 `.git`·hooks나 모델이 지정한 게시 URL을 실행에 쓰지 않는다.
4. fork Contents/Workflows write와 upstream PR write를 분리한다. 권장 자격은 별도
   GitHub App 두 개다. Draft PR 생성만 수행하며 auto-merge·ready 전환·운영 dispatch는 제외한다.
5. 사건 마커·branch로 기존 PR을 대조한 뒤 게시 상태를 기록한다. 결과가 불명하면 확인
   대기로 남긴다. Telegram은 독립 재전송하며 로그·내부 런북 대신 원인 후보·다음 행동·PR 링크를 보낸다.

fork 자체 Actions는 비활성화하고 NUC를 GitHub Actions runner로 등록하지 않는다.
구독 인증·운영 kubeconfig·SOPS 키·GitHub writer·Telegram 토큰의 역할 간 접근을 검증한다.

## 완료 증거

로컬 API 대역으로 create 응답 유실 뒤 기존 PR 발견, 미확인 결과 보류, Telegram 실패 후
재전송만 수행, 낡은 SHA 게시 거부, 원본 증거 유출 거부, 패치 없는 진단을 검사한다.
고정 검사 코드와 후보 CI의 초록 결과를 혼동하지 않는 사례를 포함한다. 실제 fork 권한/CI와
송신은 자격 구성이 준비된 05번에서 검증하며 로컬 모의 성공을 실제 게시 성공으로 기록하지 않는다.

## Comments

- 2026-09-12: Q7·Q11 및 ADR-0008·ADR-0009의 초안/운영 적용 구분을 따른다.
