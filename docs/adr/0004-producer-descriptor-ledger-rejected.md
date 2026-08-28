# push 주기·메트릭 집합을 생산자 descriptor 원장으로 옮기지 않는다

「이 생산자는 몇 초마다 push하는가」가 3가지 파서로 9곳에서 재파생된다(TS yaml-parse · grep 정규식 · yq).
2026-08 아키텍처 리뷰가 `policy/push-producers.json` + TS·셸 두 adapter를 후보로 올렸다. 기각한다.

근거는 ADR-0001과 **동형**이다. 후보가 든 마찰("크론 표기가 바뀌면 4곳이 조용히 빈 문자열을 낸다")이
실측으로 거짓이다 — 파생 8곳 전부가 직후 `fault`로 fail-closed다(`gha:63` · `adguard:41` ·
`jobfailed:116,122` · `bulkssd:85` · `drift:68`). 누락을 잡는 기전이 이미 있으므로 남는 비용은 중복 편집뿐이다.

덧붙여 실제 공유면은 cron→초 하나뿐이다. `metrics`·`heartbeat`·`delivery`의 소비자는
`tools/check-alert-rules.ts` 단 하나라 파일화는 수렴이 아니라 직렬화다. 확장자 사각지대(`.service`·`.timer`)도
원장이 아니라 전-파일 스캔이 닫으며, `tests/gates/test_unit-failure-notify.bats:50`이
"스코프 확대는 처방이 아니다"를 이미 확정했다. 셸 쪽 공유 자리도 이미 존재한다
(`tests/gates/lib/vmalert-e2e.sh`의 `vme_to_s`·`vme_fault`, 5개 하네스 공유).

각 하네스가 크론 수용을 좁히는 것(`bulkssd:83-86`이 `"M H * * *"`만 받는 것)은 CONTEXT.md 「판정 어휘」가
지킨 하네스-로컬 정책이다.

재개 조건: cron→초 파생이 아니라 **`metrics`/`heartbeat`에 두 번째 소비자가 생길 때**.
그 전까지 아키텍처 리뷰는 이 후보를 재제안하지 않는다.
