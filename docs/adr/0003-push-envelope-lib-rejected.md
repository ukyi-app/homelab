# push 봉투를 공용 lib으로 접지 않는다

방출 자리 8곳(curl push 6 + textfile collector 2)이 페이로드 조립·하트비트 위치·타임아웃·실패 거동을
각자 결정하고, 그 결과 URL 표기 4종·타임아웃 정책 4종(2곳은 타임아웃 부재)·실패 거동 4종이 공존한다.
2026-08 아키텍처 리뷰가 `scripts/lib/push-metrics.sh`로 봉투를 접는 deepening을 후보로 올렸다. 기각한다.

첫째, **완전성 가드가 생산자 파일별 정적 판정이다.** `tools/check-alert-rules.ts:441-459`·`:740-763`이
각 생산자 파일에서 쓰기 엔드포인트·VM 호스트+동사·exposition 페이로드 모양을 직접 찾는다. 조립을
lib으로 옮기면 6개 생산자가 `producerSignal` 0이 되어 "레지스트리 생산자인데 스캔에서 안 잡혔다"로
전건 red다. `pm_gauge <리터럴> <값>` 형태는 `EXPO_INLINE`(이름 앞이 `\n`·`${VAR}`·따옴표)에 매치하지 않는다.

둘째, **adapter 2종이라는 전제를 코드가 부정한다.** `scripts/notify-unit-failure.sh:11-16`이
"push 생산자 레지스트리·exposition 페이로드 계약이 전부 무관"이라고 스스로 적는다. textfile 2곳은
HELP/TYPE를 내고(push 6곳은 안 낸다) 하트비트-마지막 대신 원자적 rename 계약을 지며, 라벨 정책도
의도적으로 다르다(거부 vs 이스케이프).

셋째, **실패 거동이 도메인 소유다.** restore-drill의 `|| fail`은 KubeJobFailed가 `pg-restore-drill.*`를
제외해 in-band 무음이라서고, pvc-du의 `||` 부재는 잡 실패로 페이징하려는 선택이다.
`PM_ON_FAIL=warn|fatal`이 담지 못한다 — CONTEXT.md 「정책 원장」(대조 의미론은 콜사이트 소유)과 같은 계열이다.

넷째, 동반 변경 실측이 0건이다(주장된 22건은 이미지 핀 범프·대량 커토버였다).

**살릴 것 하나**: 「하트비트는 마지막 줄」 계약 위반 2곳(`platform/adguard/prod/rewrite-reconciler.yaml:196` ·
`scripts/backup-files-data.sh:231`)은 실재 결함이다. 방출 코드를 옮기지 말고 **이미 있는 생산자
레지스트리에 정적 가드로 얹어** 닫는다 — per-file 판정 모델이 온전하다.

재개 조건: push 생산자가 아니라 **완전성 가드가 파일별 정적 판정을 그만둘 때**.
그 전까지 아키텍처 리뷰는 이 후보를 재제안하지 않는다.
