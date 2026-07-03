# 0004 — 골든패스 확장 대신 베스포크 컴포넌트 유지 (rule-of-two)

- 상태: 수용(accepted)
- 관련: `AGENTS.md`(멀티레포 앱 플로우), `platform/files/`, `infra/cloudflare/dns.tf`,
  `docs/bespoke-component-checklist.md`, `docs/decisions/0001-secret-management-hybrid.md`

## 맥락
공유 Helm 차트(`platform/charts/app`)는 web/worker/site 3 kind의 골든패스를 제공한다. files
파일 스토어는 이 표면 밖의 5축을 요구한다: ① stateful PVC(bulk-ssd), ② 복수 리스너(internal
8080 + public 8081), ③ HTTP method 매치, ④ 시크릿 파일 마운트(keys.json), ⑤ 평문 env. files를
골든패스에 흡수하려면 닫힌 차트 스키마(`values.schema.json`)를 5축 확장해야 하는데, 현재 이
수요의 소비자는 files 단 하나(n=1)다.

## 결정
**골든패스를 확장하지 않는다.** files는 `platform/files/` 베스포크 컴포넌트로 유지한다. 대신
베스포크의 실비용 2가지(릴리스마다 수동 이미지 bump, 컴포넌트 규약 재발견)를 구조로 제거한다:
bump-poll 베스포크 핀 레인 + 본 ADR + `docs/bespoke-component-checklist.md`.

## 근거 (rule-of-two)
- **소비자 n=1엔 추상화하지 않는다.** 닫힌 스키마를 5축 확장하면 web/worker/site 3 kind 전부의
  표면·검증·문서 비용이 늘고, 회귀 위험(SSA atomic list 영구 OutOfSync·스키마 밖 필드 거부)이
  golden-path 앱 전체로 번진다. 베스포크는 그 위험을 files 디렉토리에 격리한다.
- **노출 레지스트리 이원화가 이미 이 경계를 코드로 표현한다.** 앱 host는 `apps.json`(데이터 합류
  — create-app이 등록, teardown이 무인 자동 회수)로, 플랫폼 공개 host(argocd-webhook·files)는
  코드 고정 레지스트리(`reserved-hosts.json`→dns.tf `platform_hosts`)로 관리한다. 후자는 destroy
  가드 allowlist(`^cloudflare_dns_record\.app\[`) 비대상이라 apex/www처럼 무인 삭제로부터 보호된다.
  앱은 자동 수명주기, 플랫폼 컴포넌트는 owner 고정 — 두 부류를 한 레지스트리에 섞으면 files가
  teardown 자동 회수에 휩쓸릴 수 있다.
- **appset 경계도 같은 결론.** files를 `apps/`로 편입하면 appset destination.namespace=prod
  하드코딩과 충돌하고 차트 백도어를 재개방해야 한다(역행).

## 기각된 대안
- **공유차트 5축 확장**: n=1 수요에 닫힌 스키마 표면 확대 — 비용 > 이득.
- **files의 apps/ 편입**: appset·차트 계약 역행(위 근거).

## 재평가 트리거
**두 번째 stateful 컴포넌트 수요가 생기면(n=2) 이 결정을 재검토한다.** 그때의 흡수 우선순위(비용
낮은 축부터): ⑤평문 env > ④시크릿 파일 마운트 > ③method 매치. ①stateful PVC·②복수 리스너는
그때도 별도 차트/베스포크로 유지한다(상태·리스너 토폴로지는 앱마다 달라 공유 스키마화 이득이 작다).

## 결과
- 새 베스포크 컴포넌트는 `docs/bespoke-component-checklist.md`를 따른다(files가 4번째 손복제:
  adguard→homepage→cache→files. 5번째부터는 체크리스트 기반).
- files는 bump-poll 베스포크 핀 레인(`platform/files/prod/source-repo` + `.image-pin.json`)으로
  자동 이미지 bump에 합류한다(apps/ 레인과 동일 fail-closed autoDeploy 게이트).
