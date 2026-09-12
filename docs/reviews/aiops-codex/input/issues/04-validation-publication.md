# 04 — 독립 검증과 fork Draft PR·Telegram 게시

Status: needs-info
Blocked by: Q13, 01, 03
Design: [검증](../design.md#7-codex-실행과-검증), [게시](../design.md#8-githubtelegram-게시)

## 결과

같은 검증 산출물로 전용 fork의 Draft PR과 Telegram 요약을 만든다. PR 응답 유실이나
Telegram 전송 실패가 모델 재실행·중복 PR로 이어지지 않는다. 패치가 없으면 진단을 보고한다.

## 구현 범위

1. 고정된 검사 코드·의존성의 `checkCodeRoot`와 검사할 후보 tree의 `candidateRoot`를 별도
   입력으로 받는 어댑터를 구현한다. 변경 종류에 맞는 기존 gate가 실제 후보를 읽도록 연결하며
   미지원·미실행·SKIP·실패를 통과로 바꾸지 않는다. 검사 대상과 코드의 hash를 결과에 기록한다.
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

`guard.sh`의 ROOT 재계산과 `run-bats.sh`의 자체 checkout 이동을 그대로 둔 채 cwd/환경변수만
바꾸지 않는다. 진입점·helper·파서·정책·도구 버전은 고정 기준에서 읽고, 원장/매니페스트 등
검사 데이터와 파일 열거는 신규·삭제까지 반영한 후보 manifest에서 읽는다. 원장은 고정
`ledger-to-json.ts`와 그 helper·`policy/ledger.rego`로 후보 `docs/memory-ledger.md`를 검사한다.
chart/tooling/정적 검사도 코드·입력·의존성 경로를 명시하며 지원 안 된 분리는 미검증으로 보고한다.
후보 tree 밖으로 나가는 symlink는 거부한다. 검사 입력은 읽기 전용이며 쓰기는 별도 임시 공간이다.

후보 테스트·스크립트·정책은 별도 자격 없는 임시 사본에서 실행하고 고정 검사와 별도 결과로
남긴다. 후보 helper/정책/CI를 고정 검사의 신뢰 코드로 올리지 않는다. 후보의 정책 변경도 초안을
허용하되 기존 정책과의 충돌·검사 실패를 숨기거나 후보 CI의 통과로 대체하지 않는다.

고정 검사와 후보 검사는 합계 5분·2 GiB·출력 8 MiB의 동일 단계 예산을 공유한다. 게시 시도는
합계 1분·256 MiB·출력 1 MiB다. 모든 하위 프로세스에 01번 외부 감독·종료 확인 계약을 적용한다.
기존 bats의 `BATS_TEST_TIMEOUT`은 사용하지 않는다. 검증 timeout/출력 초과/OOM은 실패·미검증
항목을 남기고, 게시 timeout은 외부 반영 여부 대조로 넘긴다. 한도를 맞추려고 검사를 생략하지 않는다.

## 완료 증거

로컬 API 대역으로 create 응답 유실 뒤 기존 PR 발견, 미확인 결과 보류, Telegram 실패 후
재전송만 수행, 낡은 SHA 게시 거부, 원본 증거 유출 거부, 패치 없는 진단을 검사한다.
고정 검사 코드와 후보 CI의 초록 결과를 혼동하지 않는 사례를 포함한다. 실제 fork 권한/CI와
송신은 자격 구성이 준비된 05번에서 검증하며 로컬 모의 성공을 실제 게시 성공으로 기록하지 않는다.

기준 tree는 정상인 채 후보 원장만 예산을 초과한 대조군이 실패해야 한다. 같은 후보가
`scripts/lib/guard.sh`, 원장 파서/helper 또는 `policy/ledger.rego`까지 약화해도 고정 검사는
위반을 검출해야 한다. 신규 파일·삭제 파일도 후보 manifest 기준으로 검사하고 두 입력 hash와
검사 경로가 실제 후보를 가리키는지 확인한다. 정상 후보 통과를 함께 확인해 무조건 실패와 구별한다.
무한 대기/출력 폭주 후보 테스트와 TERM 무시 자식을 주입해 제한 후 실패 기록·전체 자식 종료·
lease 해제·다음 사건 처리를 검증한다. 검증 중 후보 입력 변조는 hash 확인에서 거부한다.

## Comments

- 2026-09-12: Q7·Q11 및 ADR-0008·ADR-0009의 초안/운영 적용 구분을 따른다.
