# C06 작업자 v2 배포

- 단계: 2 배포와 표면
- 상태: 대기 (선행: C02, C03, C25)
- 명세: 봇 저장소 `docs/ai-bot/COLLEAGUE_SPEC.md` §4.2(계약 배포 순서), §4.10 "변경 질문 줄이기"(작업자 변경 작성 v2), §5 AC-4 (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/COLLEAGUE_SPEC.md)
- Blocked by: C02, C03, C25
- 연결 AC: AC-4(운영)
- 수행: 에이전트 + 사람(배포 PR 승인·병합, 운영 확인 승인)
- 저장소·PR: homelab PR
- 파일 소유: 소유(연결 파일, 뒤에 C23이 키·이미지 digest를 고친다) `platform/sandbox/values.yaml`의 `worker.image`(대화·리뷰 작업자 `worker`)와 `task.image`(작업 레인 작업자 `worker-task`), 두 줄 위 주석의 "지금 값" 설명. 기록 `docs/plans/2026-10-17-homelab-rebuild/approvals.md`(추가만). `platform/sandbox/values.schema.json`의 이미지 형식(digest 고정)은 바꾸지 않는다.
- 설계 계약:
  - `platform/sandbox/values.yaml`: [design.md](../../2026-10-17-homelab-rebuild/platform/design.md) C.8 "봇을 위한 여지" 표의 "격리 작업 실행 공간" 행, C.4.4 "이미지별 단일 갱신 주체", C.4.7 "자동 병합 범위와 서버 쪽 강제 (D-07, AC-P8)"(sandbox 작업자 이미지는 사람 PR로만, 자동 병합 밖). 봇 쪽 계약은 ARCHITECTURE §14 "작업자 실행"·"이미지 빌드"·"버전 고정", §12 "T18 작업 레인 실행·정리"(작업 레인 작업자 재시작 규칙) (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/ARCHITECTURE.md). DECISIONS "T16b 결정 (사용자 2026-10-30)" D2(이미지 하나, 작업자는 사람 PR) (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/DECISIONS.md).
  - `approvals.md`: [spec.md](../../2026-10-17-homelab-rebuild/spec.md) §12(계획 문서를 고칠 때의 규칙)와 이 저장소 `AGENTS.md` "변경 규칙"(외부 변경은 승인 뒤 기록).

## 목표

sandbox의 두 작업자(대화·리뷰 `worker`, 작업 `worker-task`)가 C02·C03·C25가 들어간 봇 main 빌드로 바뀌어, v1·v2 요청을 둘 다 받고 한도 정보를 싣고, 변경 작성의 옛 지시문 판과 새 판(C25 작업자 변경 작성 v2: 확인할 것·선택지 질문·수정 차례 입력)을 둘 다 받는 작업자가 운영에 선다. C25도 같은 이미지로 함께 배포하므로 작업자 이미지 사람 PR은 이 티켓 하나다. 게시 서버는 아직 v1 대화·리뷰 요청과 옛 지시문 판만 보내므로 owner가 보는 대화·리뷰·작업·변경 동작은 그대로여야 하고, 그것을 운영에서 확인해 기록한다. 이 배포가 끝나야 C11(대화 v2 전환)·C12(리뷰 말투)를 병합할 수 있고, 새 지시문 판을 보내는 C27·C28·C29도 이 배포 뒤다.

## 할 일

1. C02·C03·C25가 모두 들어간 봇 main 커밋의 `app-build` digest를 고른다. 로컬 빌드 digest는 쓰지 않는다. 빌드 증명을 `gh attestation verify`로 대조한다(지금 주석의 방식과 같게).
2. `platform/sandbox/values.yaml`의 `worker.image`와 `task.image`를 그 digest로 바꾸고, 각 줄 위 "지금 값" 주석을 새 커밋·들어간 계약(v1·v2 요청 수용, 한도 정보, 변경 작성 옛 판·새 판 수용)으로 고친다. 다른 값은 바꾸지 않는다.
3. 병합 시점: 작업 레인에 진행 중 작업이 없을 때 병합한다(작업자 파드가 다시 뜬다). 진행 중이면 기존 재시작 규칙(봇 ARCHITECTURE §12 "T18 작업 레인 실행·정리")대로 되는지 PR 본문에 적는다.
4. 사람 PR: PR 본문(`/pr` 양식)에 digest, 원본 커밋, 증명 대조 결과, 롤백 방법(이전 두 digest로 되돌림)과 C03 롤백 주의(게시 서버만 C03 이전으로 되돌리면 새 작업자의 한도 칸 응답이 거부된다)와 C25 롤백 안내(게시 서버가 옛 판만 보내는 동안 새 작업자는 옛 응답만 내므로 게시 서버만 되돌려도 깨지지 않는다. C27·C28·C29 병합 뒤 작업자를 C25 이전으로 되돌리면 새 판 요청이 거부되므로 그 셋도 함께 되돌린다)를 적는다. owner 검토 뒤 병합한다.
5. 운영 확인(owner 승인 뒤): 지금 게시 서버(v1)로 대화 한 번(멘션 또는 `/chat`), PR 리뷰 한 번(`homelab-smoke`), 작업 레인 한 번(`homelab-smoke` 프로젝트)이 성공하는지 본다. 작업자 기동 로그에 버전 확인 실패·거부가 없는지 본다. C25 몫으로, 작업 작업자의 intake(`/v1/task/intake`)가 받는 변경 작성 지시문 판 목록(옛 판·새 판)을 알리는지 보고, 운영에서 변경 PR 경로가 켜져 있으면 옛 판 변경 작성이 지금처럼 되는지도 본다(새 판 실행은 C27·C28·C29 병합 뒤라 여기서 보지 않는다).
6. 기록: [approvals.md](../../2026-10-17-homelab-rebuild/approvals.md)에 승인·병합 PR·운영 확인 결과, 봇 `VERIFICATION.md`에 "C06 작업자 v2 배포" 절. 이 계획 폴더 `README.md`의 C06 상태 줄 갱신과 C11·C12가 병합 가능해졌다는 표시, C27·C28·C29가 새 지시문 판을 보낼 수 있게 됐다는 표시.

- 롤백 주의(C25에서 넘어옴, 2026-11-10): C27~C29가 새 판 `change-v2`를 보내기 시작한 뒤 작업자만 되돌리면 저장된 새 판 결과를 읽지 못한다. 진행 중 CHANGE 턴을 끝내거나 drain한 뒤 되돌린다.
- 롤백 순서(C03에서 넘어옴, 2026-11-10): 게시 서버만 C03(봇 #116) 이전으로 되돌리면 새 작업자의 리뷰·작업 응답이 strict 스키마에 거부된다. 되돌릴 때는 작업자 이미지를 먼저 되돌리고, 이 순서를 PR 본문과 절차에 적는다.

## 완료 조건

- [ ] `worker`·`worker-task` 이미지가 C02·C03·C25가 든 main 빌드 digest이고, 증명 대조 결과가 PR에 있다. C25 작업자 변경 작성 v2도 같은 이미지로 배포됐다.
- [ ] 배포 뒤 v1 게시 서버 + v2 작업자 조합에서 대화·리뷰·작업이 성공한다(AC-4 운영).
- [ ] 작업 작업자 intake가 변경 작성 옛 판·새 판을 알리고, 옛 판 요청의 동작은 그대로다.
- [ ] 승인과 확인 결과가 `approvals.md`와 봇 `VERIFICATION.md`에 있다.

## 검증

- 경계: S5(운영). 계약 자체는 C02의 S2 시험이 이미 잡는다.
- 명령: homelab `pre-commit run --all-files`, `bun run ci`(sandbox values schema의 digest 형식, gitleaks).
- 잡는 실패 / 못 잡는 범위: 잡는 것은 v2 작업자가 v1 요청을 거부하는 운영 회귀, 잘못된 digest·빌드 증명 불일치다. 못 잡는 범위: v2 요청의 운영 동작(C11·C12 병합 뒤), 변경 작성 새 판의 운영 동작(C27·C28·C29 병합 뒤, C24), 2.1.308 `rate_limit_event` 실측(C24).

## 결과

(구현 뒤 채운다)
