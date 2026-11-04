# T24 봇 브리핑 관측 원본(인증서·복원 검증)

- 단계: P4 후속
- 상태: 완료 (2026-11-04. 브리핑 인증서 칸은 cert-manager 지표, 복원 검증 칸은 `database/pg` annotation의 실제 값을 보여 준다(BRIEF-01 두 칸 live). 봇 읽기 권한은 그대로)
- 명세: [../spec.md](../spec.md)
- Blocked by: T20
- 선행 결정: 할 일 1 (확정(사용자 2026-11-03): 인증서 칸은 cert-manager 지표를 VictoriaMetrics로 수집하고 봇은 Grafana로 읽음, 만료 경보 함께. 복원 검증 칸은 `restore-check`가 `database/pg` Cluster annotation에 결과를 남기고 봇은 이미 읽는 Cluster에서 읽음. 봇 읽기 권한은 그대로)
- 연결 AC: AC-B7 (BRIEF-01 관측 칸)
- 수행: 에이전트 + 사람

## 목표

T20 일일 브리핑의 인증서 칸과 복원 검증 칸은 봇 권한으로 읽을 원본이 없어 늘 "미확인"이다. 출처는 봇 저장소 `docs/ai-bot/VERIFICATION.md` "T20 실연동 결과"의 BRIEF-01 행과 "T20 남은 것" 5번이다. 이 동작은 V1 규칙("실제 접근 가능한 데이터만, 읽기 불가는 마지막 정상 수집 시각과 미확인", 봇 저장소 `docs/ai-bot/prompts/01-v1-build.md` 일일 브리핑)에 맞는다. 다만 두 칸이 아무 정보도 주지 못한다. 봇이 읽기 전용으로 볼 수 있는 원본을 플랫폼에 만들고 브리핑 관측 어댑터에 잇는다.

V1 판정(T21)은 막지 않는다. 미확인 표시가 V1 규칙이라서다.

## 메모

- 인증서: cert-manager는 클러스터 안 인증서만 맡는다(Barman Cloud Plugin TLS, `platform/design.md` A.4 9번). 공개 TLS는 Cloudflare edge가, 내부 UI의 `*.ts.net`은 Tailscale이 발급·갱신한다(C.2 "시스템이 자동 발급·갱신하는 자격" 행). 브리핑이 볼 인증서의 범위부터 정한다.
- 복원 검증: 자동 복원 드릴은 두지 않는다(C.3.8. 옛 자동 드릴의 거짓 PASS 때문). 분기 1회 사람이 `homelab db restore-check`를 돌린다. 지금은 그 결과(시각, 대상 백업, 통과 여부)가 어디에도 남지 않는다. 그래서 원본부터 만들어야 한다.
- 봇 읽기 계정(C.8 "읽기 전용 접근")은 Secret·ConfigMap·pod 로그·exec를 읽지 못한다. 이 범위를 넓히지 않는 방식을 먼저 찾는다. 예: 봇이 이미 읽는 CNPG 객체의 표시, 관측 지표의 만료 시각.

## 할 일

1. 두 칸의 원본과 읽는 경로를 정한다(사용자 결정). 후보마다 함정을 비교한다. 인증서는 cert-manager `Certificate` 상태 읽기 권한 추가와 관측 지표 조회를 비교한다. 복원 검증은 `restore-check`가 결과를 남길 자리와, 그 자리가 Argo CD 동기화와 부딪히지 않는지 본다.
   - 결과(2026-11-03, 사용자 결정): 조사 두 갈래(읽기 전용 Codex 작업자)의 비교로 골랐다. 인증서: (a) cert-manager 지표 → VictoriaMetrics → 봇은 Grafana Viewer로 집계 질의, 같은 지표로 vmalert 만료 경보(7일 warning, 1일 critical, Ready 아님). (b) `Certificate` 직접 읽기(`homelab-readonly`에 권한 추가)는 경보가 없어 고르지 않았다. 대상은 `cnpg-system`의 Barman 인증서 2개(만료 2027-01-21, 갱신 01-06)다. 복원 검증: (a) `database/pg` annotation `homelab.ukyi.app/restore-check-last`·`-pass`(한 줄 JSON, 스키마 v1), Argo CD는 두 키만 비교·동기화에서 뺀다. (b) 결과 전용 ConfigMap은 봇에 권한을 더해야 하고 CI `readonly-rbac` 정책 예외가 필요해 고르지 않았다. 지표(보존 30일)·`Backup` 객체(14일)는 분기 주기보다 짧다. 함께 찾은 결함: `restore-check`가 Database CR 0개에도 통과하고 결과를 남기지 않는다. 할 일 2에서 고친다. 실제로 쓴 base backup ID 고정은 범위 밖이다(기록은 복구 목표 시각과 serverName).
2. 플랫폼 변경(지표 수집·경보, CLI 결과 기록, Argo CD 비교 제외)을 PR로 한다.
   - 결과(2026-11-03): homelab #1035 `40f1798`. vmsingle 수집 job `cert-manager`(cert-manager 컨트롤러 지표), vmalert `certificates` 그룹 경보 3개(만료 7일 미만 warning, 1일 미만 critical, Ready 아님)와 `TargetMissing`에 cert-manager 추가. `restore-check`는 시험을 시작한 `pg`의 uid에 결과를 묶어 `restore-check-last`·`-pass`에 남긴다(그사이 `pg`가 다른 객체로 바뀌면 멈추고 `--abort`로만 버림). Database CR 0개는 실패로 바꿨다. Argo CD `cnpg-cluster`는 두 키를 비교·동기화에서 뺀다(`ignoreDifferences` + `RespectIgnoreDifferences`). Codex P2 1건(다시 만든 `pg`에 결과가 붙음)은 같은 PR에서 고쳤다. 적용 뒤 수집 `up`=1, 인증서 2개 Ready, 경보 없음.
3. 봇 브리핑 관측 어댑터에 두 원본을 더한다(봇 저장소 PR). 읽기 실패와 오래된 값은 지금처럼 미확인과 마지막 정상 수집 시각으로 둔다.
   - 결과(2026-11-03): 봇 #32 `12a09c3`. 인증서는 Grafana로 집계 질의 4개(개수, 가장 이른 만료 `min(… > 0)`, Ready 개수, 신선도)를 읽는다. 복원 검증은 백업 원본이 이미 받는 Cluster 응답의 annotation을 읽는다. 봇 RBAC·NetworkPolicy·자격은 바꾸지 않았다.
4. BRIEF-01의 두 칸을 실연동으로 확인하고 봇 `VERIFICATION.md`에 적는다.
   - 결과(2026-11-04): owner가 11-03 23:32 `homelab db restore-check --apply`로 통과 기록을 남겼다(23:35 끝, 임시 객체 0, Argo CD `cnpg-cluster` Synced 유지). 11-04 08:50 브리핑은 회차 1건이 전송됐고 봇 Grafana 질의 4개가 성공했다. 채널 문구(owner 맥의 Codex가 읽기만 해서 옮김): 인증서 칸 "정상 · 2개 모두 Ready · 가장 이른 만료 2027-01-21(78일) · 관측 11-04 08:50", 백업 줄의 복원 검증 "복원 검증 통과 11-03 23:34 · CLI 기록 기준, 백업 성공과 별개". 봇 `VERIFICATION.md` "T24 실연동 결과".

## 완료 조건

- 브리핑의 인증서·복원 검증 칸이 실제 원본 값을 보여 준다. 읽기 실패 때는 미확인이다.
- 봇 읽기 계정이 Secret·ConfigMap을 읽지 않는 범위 그대로다. 넓혔다면 그 이유와 사용자 승인이 [../approvals.md](../approvals.md)에 있다.
- 봇 `VERIFICATION.md` BRIEF-01의 두 칸 기록이 바뀌었다.

## 검증

`04` §4 BRIEF-01(관측 칸).
