# guard-dominance — actor 가드가 실제로 지배하는지 (설계 패스 결과)

`guard-witness` 캠페인이 자기 설계 패스로 분리한 축(티켓 10)의 설계 패스 기록이다.
**결론: 처방은 착지했고 정적 분류 가드는 기각했다.** 이 문서는 그 경로를 남긴다.

## 이 경계가 담는 것

앱 레포는 homelab 쓰기 자격이 0이지만 dispatch App(`actions:write`)을 갖는다
(`reusable-app-build.yaml:159-167` — `repositories: homelab` · `permission-actions: write`).
그 토큰이 homelab의 변이까지 트리거하지 못하게 막는 것이 owner 가드다.

## 설계가 다섯 번 무너졌다

| 라운드 | 규칙 | 무너진 지점 |
|---|---|---|
| 원안 | 술어를 실행한다 | 그 술어가 **도는지**를 안 본다 |
| r1 | 가드가 앞이거나 하위 잡이 `needs`로 의존한다 | 이 레포는 `needs`를 **순서 전용**으로 쓴다(`bump-poll.yaml:109-110`) |
| r2 | 능력 4항목에 걸리면 특권이다 | 목록에 없으면 안전 — `build.yaml`·`tf-reconcile.yaml`이 0건 매치 |
| r3 | `workflow_dispatch` 보유를 보호 대상으로 잡는다 | **트리거 열거**다. 재실행이 트리거를 우회하고 `iac.yaml`·`bump.yaml`이 우주 밖에 남는다 |
| r4 | 능력 폐포 공집합이면 비특권으로 **파생**한다 | 열거 공집합을 통과 판정으로 승격 — `reusable-app-build.yaml#build`가 라이브 반례 |

다섯 번 다 **무언가를 열거하고 열거 밖을 안전으로 읽었다.** 기각 기록은
`docs/adr/0002-dominance-classifier-rejected.md`(재개 조건 포함).

## 살아남은 것 — 재실행 축

`github.run_attempt`은 재실행이 **보존할 수 없는 유일한** 컨텍스트 값이고, attempt≥2의 개시자는
언제나 `actions: write`를 든 주체다(GitHub 스케줄러도 push도 재실행을 하지 않는다).
⇒ **이 축에는 열거할 트리거가 없다.** 열거 밖이라는 개념이 성립하지 않는 유일한 자리다.

## 착지한 처방

1. **신원** (`1450596`) — 가드 15사본이 `github.actor` 하나만 비교했다. actor는 재실행에서
   **최초 트리거 신원으로 보존**되므로 owner의 과거 디스패치 재실행이 통과했다(실측: 15/15).
   `github.triggering_actor`를 병기해 **둘 다** 요구한다.
2. **재실행 축** (`ee4d62e`) — 가드 10개가 `if: github.event_name == 'workflow_dispatch'`로
   한정돼 있어 push·schedule run의 재실행에서 **스텝 자체가 skip**됐다(1번이 닿지 못했다).
   `if:`를 없애고 트리거 판정을 본문으로 옮긴 뒤 재실행 절을 그 앞에 둔다. 이벤트 구동 특권
   잡 둘(`iac.yaml#apply` · `bump.yaml#writeback`)에는 재실행 전용 가드를 첫 스텝으로 넣는다.

라이브로 노출돼 있던 특권 잡(실측): `build.yaml#build`(push — 가변 canonical 태그 재조준 →
`bump.yaml:109`의 라이브 digest 해소로 전 소비처 재핀) · `pr-sweeper.yaml#sweep`(schedule —
무장된 auto-merge 봇 PR `update-branch`) · `tf-reconcile.yaml#reconcile`(schedule — `terraform apply`) ·
`iac.yaml#apply`(push 재생 — 옛 머지 SHA로 라이브 Cloudflare 수렴) · `bump.yaml#writeback`.

## 증인

`tools/tests/test_mutation-dispatch.bats` — 열거를 `ATTEMPT` 기준으로 **17사본**으로 넓혔다.
재실행 축 3케이스는 17건 공통, dispatch 축 3케이스는 `ACTOR`를 담은 15건에만 적용한다.
계수 증인이 `replay == pred + evt` · `empty == replay` · 바인딩 등식 · **`if:` 잔존 0**을 진다.
뮤테이션 7종 전건 red(신원 3 + 재실행 4).

## 프로토타입이 남긴 것 (분류 가드를 되살릴 때의 출발점)

기각했지만 측정은 유효하다. dispatch 우주 기준 GUARDED 15 · DOMINATED 7 · NONPRIVILEGED 7 ·
ALLOW 4 · **미분류 0**이었고, 뮤테이션 6종이 전건 red였다. 재개 조건(ADR-0002)이 충족되면
이 수치가 비회귀 기준선이다.

## 잔여 위험 — 명시한다

- **`run_attempt` 증가는 이 레포에서 실측된 적이 없다.** 문서화된 거동이고 처방은 그 확인과
  무관하게 옳지만(둘 다 요구하는 것이 더 약해질 수 없다), 확인 전까지는 문서 신뢰다.
- **`bump-poll.yaml`은 여전히 앱 레포 dispatch의 정당한 대상이다.** 안전이 폴링 로직의
  fail-closed 검증(main reachable · descendant · digest 핀 · autoDeploy 누락=거부)에 걸려 있고,
  그 검증 자체의 증인은 이 패스 밖이다.
- **능력이 러너 파일시스템에 남는 문제는 닫았다**(`persist-credentials: false`, 실측 1곳 → 잔존 0).
  다만 이것은 **가드가 아니라 처방**이다 — 새 write 스코프 잡이 같은 형태로 들어와도 잡아 줄
  기전이 없다(그 기전이 곧 기각한 분류 가드다).
- **크로스레포 `workflow_call` 호출자는 보이지 않는다.** 정적 분석의 원리적 경계다.
