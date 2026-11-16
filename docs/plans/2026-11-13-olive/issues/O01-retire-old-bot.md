# O01 옛 봇 끄기

- 단계: 0 끄기와 검증
- 상태: 끄기 완료(2026-11-13: 게시 서버 #1281, 작업자 둘 #1282). 남은 일: Healthchecks 확인 일시 중지(관리자)
- 명세: `spec.md` §2.2, §5.1 D-12, §13(만드는 동안 Discord 봇 없음)
- Blocked by: 없음
- 연결 AC: AC-01, AC-02
- 결정(관리자): D-12 "3번"(2026-11-13): 옛 봇을 먼저 끄고 올리브를 만든다. 끄는 방법은 "아직 봇을 사용하는건 아니라서 끄고 하는게 어때?"(2026-11-13)로 완전히 끄기를 골랐다.
- 수행: 에이전트 + 사람(배포 PR 병합)
- 저장소·PR: homelab #1281(병합됨, 게시 서버), homelab #1282(병합됨, 작업자 둘)
- 파일 소유: homelab `apps/homelab-bot/values.yaml`의 `suspended`, `platform/observability/stack/vmalert/rules/core.yaml`의 `TargetDown`, 같은 폴더 `tests/core.test.yaml`
- 설계 계약: `spec.md` §9.1(원문 7일 약속), 옛 봇 계획 `docs/plans/2026-11-09-bot-colleague/`

## 목표

옛 봇의 게시 서버가 멈춰 있고, 그 때문에 울리는 경보가 없으며, 다른 경보는 Telegram으로 계속 온다. 되돌리는 법이 값 옆 주석에 있다.

## 한 일 (homelab #1281)

1. 끄기 전 확인: 옛 봇 관리 CLI의 상태 보기로 진행 중 작업이 없음을 봤다(비상 정지 아님, 멈춤 아님, 실행 대기 없음, 작업 창구 열림).
2. 게시 서버: `apps/homelab-bot/values.yaml`에 `suspended: true`(앱 차트의 공식 멈춤 스위치: replicas 0, 마이그레이션 Job 없음).
3. 경보: 지표 Service가 남아 `up{job="bot-slot"}`이 0이라 `TargetDown`이 계속 울린다. `TargetDown`에서 그 job을 뺐고 단위 시험을 더했다. 옛 봇 경보(`bot.yaml`)는 봇 지표가 없으면 조용해서 건드리지 않았다. `TargetMissing`은 Service가 남아 울리지 않는다.
4. 데이터: 봇 DB, Secret, Service, 삭제 원장 볼륨은 그대로다.

## 멈춘 동안 달라지는 것

- Discord 수신·답이 없다(봇이 오프라인으로 보인다).
- 원문 7일 정리가 멈춘다. 정리 기능은 7일이 지난 원문만 지우므로 끄기 직전에 한꺼번에 비울 수 없었다. 최근 7일치 원문은 게시 서버(현관)가 다시 뜰 때까지 DB에 남는다. 관리자는 실제로 쓰던 봇이 아니라는 점을 들어 이대로 끄기를 골랐다.
- 홈랩 경보의 Discord 전달, GitHub webhook 수신, Healthchecks ping이 멈춘다. Telegram 경보 경로는 그대로다.

## 남은 일

1. 작업자 둘(`platform/sandbox`의 `worker`, `worker-task`)을 끈다(D-17, 관리자 "꺼" 2026-11-13). 지금은 켜진 채이고, 요청을 보낼 게시 서버가 없어 모델을 부르지 않지만 모델 자격 파일을 쥐고 있다. 차트의 고정 replicas를 값으로 바꾸는 PR로 끄고, 끄면 울리는 경보가 있는지 같은 PR에서 확인한다. 다시 켜는 것은 O13이 한다. 한 일(homelab #1282, `5f85a642`): `platform/sandbox`의 `worker.replicas`·`task.replicas`를 값으로 바꿔 0으로 뒀다(0 또는 1만). CI 정책 `tools/ci/policy.ts`가 작업 작업자에 강제하던 "replicas 1"을 "0 또는 1"로 넓히고 시험 자료 둘을 더했다. 빈 클러스터에서 `codex-home` PVC가 쓰는 파드 없이 Pending으로 남아 root를 막는 문제를 독립 리뷰가 찾아, replicas가 0일 때만 그 PVC를 Application health 합산에서 빼는 주석을 붙였다. 이 동작은 실제 빈 클러스터에서 확인하지 못했다. 다음 재구축·VM 시험 때 본다.
2. Healthchecks의 봇 확인 일시 중지(관리자).
3. `approvals.md`에 결정 줄(D-12)과 실행 줄(#1281 병합, 병합 뒤 확인)을 적는다.

## 되돌리기

`apps/homelab-bot/values.yaml`의 `suspended: true`와 `core.yaml`의 `bot-slot` 제외를 같은 PR에서 지운다. 제외를 남기면 봇 지표 수집이 끊겨도 조용하다. 멈춘 동안 온 Discord 메시지를 누락 복구가 받아 올 수 있으므로 다시 켜는 작업(O08)에서 다룬다.

## 완료 조건

- [x] 게시 서버 파드가 0개(운영 읽기, 2026-11-13).
- [x] 멈춘 뒤 8분이 지나도 `TargetDown`이 울리지 않는다(운영 읽기, 2026-11-13: 활성 경보는 Watchdog뿐, 클러스터의 룰에 `bot-slot` 제외가 실림).
- [x] 작업자 둘을 끌지 정했다(끈다, D-17).
- [x] 작업자 둘의 파드가 0개이고 그 때문에 울리는 경보가 없다(운영 읽기, 2026-11-13: homelab #1282 병합 10분 뒤 sandbox 파드 0개, 활성 경보는 Watchdog 하나, Synced·Healthy가 아닌 Application 없음).
- [x] `approvals.md`에 기록이 있다(이 계획 문서를 올린 PR에 함께 넣었다).

## 검증

- 경계: 운영 읽기. 룰 단위 시험 "TargetDown은 멈춘 게시 서버의 지표 Service(bot-slot)에는 발화하지 않는다", homelab `ci` 통과, 병합 뒤 파드·경보 읽기.
- 잡는 실패: 꺼진 봇 때문에 계속 울리는 경보, 데이터 삭제. 못 잡는 범위: 올리브 쪽(이 티켓과 무관).
