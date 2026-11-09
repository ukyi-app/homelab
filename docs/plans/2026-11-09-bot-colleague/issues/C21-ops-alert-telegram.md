# C21 운영 알림 (지표 + vmalert → Telegram)

- 단계: 5 멈춤과 계정
- 상태: 대기 (선행: C19)
- 명세: 봇 저장소 `docs/ai-bot/COLLEAGUE_SPEC.md` §4.7 "운영 알림", §5 AC-18 (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/COLLEAGUE_SPEC.md)
- Blocked by: C19
- 연결 AC: AC-18
- 수행: 에이전트 + 사람(운영 발화 시험 승인과 Telegram 도착 확인)
- 저장소·PR: 둘(봇 PR → 봇 이미지 배포 → homelab PR)
- 파일 소유:
  - 봇 `src/ops-metrics.ts`: 멈춤 지표 줄. 소유(연결 표에 없음). C22가 계정 이름·방식 값을 채울 때 같은 줄을 쓴다(연결 표에 없는 공유, README 5절에 반영).
  - 봇 `src/main.ts`: 지표 조립에 멈춤 기록 읽기를 넘기는 배선이 필요하면 그 자리만. 연결 표에 없는 공유 파일이다(C19·C20과 겹친다. README 5절에 반영).
  - 봇 시험: `test/ops-metrics.test.ts`.
  - homelab `platform/observability/stack/vmalert/rules/bot.yaml`: 모델 멈춤 경보 규칙. 소유.
  - homelab `platform/observability/stack/vmalert/tests/bot.test.yaml`: 그 규칙의 발화·미발화·해소 시험. 소유.
  - homelab `tools/ci/alerting.ts`: route 시험 표(`ROUTES`)에 이 경보의 라벨 경우를 더해야 할 때만. 소유(다른 티켓이 고치지 않음).
  - homelab `platform/observability/stack/alertmanager/alertmanager.yml`: 바꾸지 않는 것이 목표다. 기존 warning 경로(봇 route `continue` + Telegram 형제 route, 4시간 반복, 해소 전송)를 그대로 쓴다.
- 설계 계약:
  - `src/ops-metrics.ts`: 봇 ARCHITECTURE "13. 개선안 v2 적용"의 "지표 (`/metrics`, DB gauge)"(라벨은 코드 고정 목록, ID·본문 없음, 경보는 `max()`)와 "8. 봇 중단 경보 연결" (c) (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/ARCHITECTURE.md).
  - vmalert 규칙·시험: homelab [설계 C.3.7 관측·알림·외부 생존 감시](../../2026-10-17-homelab-rebuild/platform/design.md)(룰은 Git, 단위 시험 CI, 평가 30초)와 [설계 C.8 봇을 위한 여지](../../2026-10-17-homelab-rebuild/platform/design.md)의 "경보 외부 수신자" 행(봇 route `continue: true`, 비AI 경로 Telegram). 규칙 파일 머리 주석의 `service` 라벨 금지 규칙.
  - route 시험: homelab `tools/ci/alerting.ts`의 라벨별 receiver 시험 주석(설계 C.8, D-10).
  - 결정: 봇 DECISIONS "동료 봇 전환 (사용자 2026-11-09)" 7, "D-14 봇 모델 계정과 인증"의 "변경(사용자 2026-11-09…)" (https://github.com/ukyi-app/homelab-bot/blob/main/docs/ai-bot/DECISIONS.md).

## 목표

모델이 멈추면 2분 안에 owner의 Telegram에 원인 종류(한도·인증 만료·결제), 풀리는 시각(KST), 할 일(기다리기 / API 크레딧 계정으로 바꾸기 / 다른 구독 계정으로 바꾸기와 그 CLI 명령), 지금 계정이 온다. Discord에는 이 경보가 가지 않는다. 멈춘 동안 4시간마다 다시 오고, 풀리면 해소가 온다.

봇 PR은 지표만 더하므로 병합하면 바로 지표가 나간다(경보는 homelab PR 뒤). homelab PR은 병합하면 Argo CD가 vmalert 규칙을 바로 적용한다.

## 할 일

1. 봇 지표를 더한다(`src/ops-metrics.ts`): 멈춤 여부와 종류(고정 목록 라벨: 한도·인증 만료·결제), 풀리는 시각(Unix 초, 모르면 0 또는 시계열 없음 중 하나로 정해 적는다), 지금 계정 이름과 방식(C22 전에는 비어 있음. 계정 이름은 owner가 CLI로 정한 짧은 이름이라 라벨 값으로 둘지, 값 비노출 규칙과 카디널리티를 보고 정한다), 미룬 리뷰 수(C19). 값은 C19의 멈춤 기록에서 읽는다. 라벨에 ID·본문을 넣지 않는다.
2. 봇 PR을 병합하고 이미지 digest PR이 자동 병합돼 운영에 나간 뒤, vmsingle에서 새 시계열이 보이는지 확인한다(멈춤이 없으면 0 값).
3. homelab 규칙을 더한다(`rules/bot.yaml`의 bot 그룹): severity warning, `service` 라벨 없음(Telegram 형제 route만 받고 봇 수신기는 버린다). 두 파드가 같은 DB 값을 내므로 `max()`로 묶는다. 도착 예산 2분(수집 30초 + 평가 30초 + `group_wait` 30초)을 지키도록 `for`는 0이나 아주 짧게 둔다. 근거를 규칙 옆 주석에 적는다.
4. 경보 문구(annotations): 원인 종류, 풀리는 시각 KST, 할 일 세 가지와 해당 CLI 명령(`homelab bot account use <이름>`, `--by api`, C22·C23이 만든 이름 그대로), 지금 계정. KST 변환을 vmalert 템플릿 함수로 할 수 있는지는 미확인이다. 안 되면 봇이 내는 지표를 바꾸지 말고 UTC와 "KST = UTC+9"를 함께 적는 등 대안을 정해 주석에 남긴다. 원인 값은 Discord에 가지 않는다.
5. 규칙 단위 시험(`tests/bot.test.yaml`): 종류별 발화, 멈춤 없음 미발화, 해소, 문구의 KST 시각. route 시험(`tools/ci/alerting.ts`)은 지금 표의 warning 경우가 이 경보를 덮는지 보고, 경보 이름을 넣은 경우가 따로 필요하면 한 줄 더한다.
6. 로컬 검사 뒤 homelab PR을 연다. owner 검토 뒤 병합한다.
7. 운영 발화 시험(사람 승인 뒤 1회): 실제 지표로 규칙이 발화하고 Telegram에 2분 안에 도착하며 Discord에는 가지 않는지 본다. 실제 한도를 기다리지 않는 주입 방법(예: 시험용 멈춤 기록)을 정해 승인받는다. 끝나면 해소가 오는지 본다. 결과를 homelab [approvals.md](../../2026-10-17-homelab-rebuild/approvals.md)와 봇 `VERIFICATION.md`에 적는다.
8. 기록: 봇 `docs/ai-bot/VERIFICATION.md`에 "C21 운영 알림" 절, `docs/ai-bot/ARCHITECTURE.md` "지표" 절에 새 지표 줄, `docs/ai-bot/DECISIONS.md`에 라벨·KST 표기 선택 문단을 더한다. 이 계획 폴더 `README.md`의 C21 상태 줄을 갱신한다.

## 완료 조건

- [ ] 봇 `/metrics`에 멈춤 종류·풀리는 시각·지금 계정·미룬 리뷰 수 지표가 있고, 라벨에 ID·본문이 없다.
- [ ] 모델 멈춤이 되면 2분 안에 Telegram에 원인 종류, 풀리는 시각(KST), 할 일, 지금 계정이 온다. Discord에는 이 경보가 가지 않는다.
- [ ] 멈춘 동안 4시간마다 다시 오고, 풀리면 해소가 온다.
- [ ] 운영 발화 시험 1회 결과가 [approvals.md](../../2026-10-17-homelab-rebuild/approvals.md)와 봇 `VERIFICATION.md`에 있다.

## 검증

- 경계: S1(봇 지표 출력)과 S4(vmalert 규칙 단위 시험, Alertmanager route 시험). 운영에서 S5 발화 시험 1회. 앞선 예: 봇 `ops-metrics` 시험, homelab `vmalert/tests/bot.test.yaml`, `tools/ci/alerting.ts`.
- 명령: 봇 `npm run check`, `npm test`(바뀐 파일 관련 시험만). homelab `pre-commit run --all-files`, `bun run ci`.
- 잡는 실패: 지표 이름·라벨 불일치, 봇 수신기로 가는 route, KST 표기 오류, 두 파드 중복 집계. 못 잡는 범위: 실제 Telegram 전송(S5 발화 시험이 본다).

## 결과

(구현 뒤 채운다)
