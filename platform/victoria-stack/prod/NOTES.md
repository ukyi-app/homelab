# victoria-stack 운영 노트

## metrics-server는 계속 비활성 (k3s `--disable=metrics-server`)
의도적으로 metrics-server를 돌리지 않는다(약 40–60 MiB 절약, §14). 결과:
- `kubectl top nodes` / `kubectl top pods`는 동작하지 않는다 — 버그가 아니라 의도된 동작.
- **대체재:** Grafana 대시보드 `Homelab — Node & Pod Memory (uid: homelab-resources)`가
  `kubectl top`의 정식 대체재다. "Pod memory vs limit" 테이블이 §10 메모리 원장의
  라이브 뷰다.
- metrics-server 재활성화는 HPA를 도입할 때에만(범위 밖, §14); 그 경우
  `infra/k3s-bootstrap`에서 `--disable=metrics-server` 제거도 필요하다.

## 내부 전용 자세
Grafana, vmsingle, VictoriaLogs, vmalert, Alertmanager는 공개 HTTPRoute도, cloudflared
라우트도 없다. 오직 Tailscale로 노출된 단일 `homelab` Gateway의 `web-internal-tls`
listener(M3, :8443)를 거쳐 `*.home.ukyi.app`으로만 접근 가능하다. 기본 자세 =
internal-by-default (§6).

## dead-man's-switch 부트스트랩 의존성
오프 노드 감지기는 healthchecks.io에 있다(외부 계정, Task 5.16 / Makefile
bootstrap 단계 참조). 노드가 죽으면 relay의 ping이 멈추고 healthchecks.io가 페이징한다.
모니터링 대상 노드에 자체 호스팅할 수 없는 유일한 관측 신호다 (R8).
