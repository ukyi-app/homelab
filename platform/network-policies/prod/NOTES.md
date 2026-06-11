# NetworkPolicy — east-west 격리 (Pass-5 Open Item #3)

k3s는 번들된 **kube-router** 컨트롤러로 NetworkPolicy를 강제한다(설치 시
`--disable-network-policy`를 절대 넘기지 않음). "내부 전용"은 이전에는 "공개 HTTPRoute 없음"으로만
강제되었다; 이 policy들은 실제 east-west 격리를 추가해, 침해된 공개 `api`/`ssr` pod가
database/admin 계층으로 측면 이동(lateral movement)하지 못하게 한다.

## 강제되는 내용

| Namespace | 방향 | 기본값 | 허용 |
|-----------|-----------|---------|--------|
| `prod` (apps) | Ingress | **deny** | gateway→:8080, observability→:9090, prod 내부 앱→앱 :8080, kubelet probe (pod CIDR) |
| `prod` (apps) | Egress  | **deny** | DNS (kube-system CoreDNS), database:5432, prod 내부 앱→앱 :8080 |
| `database` (CNPG) | Ingress | **deny** | prod→:5432, cnpg-system (operator), observability→:9187, ns 내부, kubelet probe |
| `database` (CNPG) | Egress | *open* (아래 참조) | — |

"침해된 앱이 데이터베이스에 닿으면 안 된다" 경계는 양쪽에서 **심층적으로** 강제된다:
prod는 `database:5432`로만 egress 가능하고, `database`는 prod로부터 5432 ingress만 받는다
(operator/metrics/ns 내부 제외). 앱은 기본적으로 **일반 인터넷 egress가 없다** — 필요한 앱은
자체 추가 `NetworkPolicy`를 함께 배포한다.

배치: `prod` policy는 이 컴포넌트에 있다(`platform-components` ApplicationSet이
`platform/*/prod`에서 자동 발견); `database` policy는 자기 계층과 함께
`platform/cnpg/prod/networkpolicy.yaml`에 있다(`cnpg-data` Application이 sync).

## 의도적 범위 한정 (향후 하드닝)

- **`database` egress는 의도적으로 열어 두었다.** CNPG 인스턴스는 Kubernetes API,
  R2 object store(barman/rclone), Telegram/healthchecks, 그리고 streaming replication을 위해
  서로에게 접근해야 한다. 그 egress 집합을 정밀하게 매핑하려면 라이브 클러스터가 필요하므로,
  잠그는 것은 후속 하드닝으로 추적한다(라이브 egress를 앞에 두고 + 연결성 테스트로 진행).
- **`prod`와 `database`만 커버한다.** 각각 공개 공격 표면과 핵심 자산이다. default-deny를
  `gateway`/`edge`/`observability` 등으로 확장하는 것은 추가적인 향후 작업이며,
  `kube-system`/`argocd`는 피해야 한다(거부 시 DNS/CD가 망가진다).
- **prod 내부 앱→앱(`:8080`)은 의도적으로 허용한다**(`allow-intra-prod-http`) — 같은 신뢰
  계층의 동거 앱들 간 서버 사이드 호출(예: SSR/web→api)이 동작하도록. 완전한 앱 간 격리는
  의도적으로 채택하지 않은 더 엄격한 자세다; 앱별 allow 쌍이 필요해지고 기본적으로 SSR→API가
  망가진다. prod→`database` 경계에는 영향이 없다.

## 라이브 검증 (보류 — `tests/posture/network-policy.bats`)

NetworkPolicy 강제는 라이브 클러스터에서만 테스트할 수 있다(namespace들은 ArgoCD가
M3/M4를 sync하기 전에는 존재하지 않는다). bring-up 시 posture 스위트를 실행해 확인할 것:

1. **probe가 default-deny에서 살아남는다.** `allow-ingress-kubelet-probes` policy는 k3s pod/
   cluster CIDR(`10.42.0.0/16`)에서 probe 포트로의 접근을 허용한다. k3s `cluster-cidr`이
   커스텀이거나 probe 소스가 그 범위 밖의 노드 기본 IP로 밝혀지면 앱/CNPG pod가
   `NotReady`가 된다 — 관측된 probe 소스로 `ipBlock`을 넓힐 것. **pod가 Ready를 유지하는지 먼저 확인.**
2. **부정 케이스:** `default`(목록에 없는 namespace)의 pod는 `pg-rw.database.svc:5432`에 닿을 수 없다.
3. **긍정 케이스:** `prod` pod는 `pg-rw.database.svc:5432`에 닿을 수 있고, `prod` pod는 임의의
   외부 `:443`을 열 수 없다(egress default-deny).
