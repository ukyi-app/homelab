# 0001 — 시크릿 관리 하이브리드(SOPS + SealedSecrets) 유지

- 상태: 수용(accepted)
- 관련: `AGENTS.md`(시크릿 공급 규약), `scripts/sealing-key-dr-gate.sh`, `docs/traps.md`

## 맥락
플랫폼 시크릿은 SOPS + age(`*.enc.yaml`, recipient 2개: cluster + recovery)로,
앱 시크릿은 SealedSecrets(컨트롤러 공개키로 봉인)로 관리한다. "한 도구로 통일하자"는
제안이 반복해서 나왔다(인지부하 감소).

## 결정
하이브리드를 유지한다. 전면 통일하지 않는다.

## 근거
- **controller-독립 복호가 DR 앵커다.** SOPS+age는 age 개인키만 있으면 컨트롤러·클러스터
  없이도 복호된다. SealedSecrets는 라이브 컨트롤러의 sealing key에 종속된다 — 컨트롤러가
  죽으면 봉인 시크릿은 복구 키 없이는 못 푼다. 플랫폼 부트스트랩 시크릿을 SealedSecrets로
  옮기면 "클러스터를 세우려면 클러스터가 필요한" 순환이 생긴다.
- 판정단 검토 8/10이 하이브리드 우세로 판정(통일의 단순함 < controller-독립 DR 자산).

## 기각된 대안
- **전면 SealedSecrets 통일**: controller-독립 SOPS DR 자산을 잃는다. 부트스트랩 순환.
- **전면 SOPS 통일**: 앱 레포가 age 개인키(또는 KSOPS 권한)를 알아야 해 신뢰 경계가 넓어진다.
  SealedSecrets는 공개키만으로 앱 레포에서 봉인 가능(write-only 경계).

## 결과
- sealing key 백업 체인을 DR fail-closed 게이트로 강제한다(`tests/test_sealed-secrets-restore.bats`).
- "어느 도구로 뭘 봉인하나"의 인지부하는 `make secret-edit`/`secret:seal` 진입점으로 완화한다.

## 개정 2026-07 — 채널 선택 기준(de-facto)의 성문화

원 결정("하이브리드 유지")은 *유지 근거*만 담았고 "새 시크릿을 어느 채널에 둘지"의 판단 기준은
암묵이었다. 실태를 조사해 de-facto 기준을 명문화한다.

**기준 = 부트스트랩 임계성 / DR 복구 독립성.**
- **SOPS(`*.enc.yaml`, 9개)** — 클러스터를 *세우는 데* 필요하거나, 컨트롤러 없이 age 개인키만으로
  복호돼야 하는 시크릿. `scripts/seed-secrets.sh`가 terraform output·`.env.secrets`에서 시드한다:
  tunnel·operator-oauth·r2-creds(pg/cache)·pg-app-credentials·alerting·restore-drill-alerting·
  cloudflare-api-token(cert-manager). 이들이 SealedSecret이면 "클러스터를 세우려면 클러스터가
  필요한" 순환(원 결정 근거)에 빠진다.
- **SealedSecrets(`*.sealed.yaml`, 20개)** — 클러스터가 이미 선 뒤 자동화가 산출하거나(provision-db/
  cache·create-app·앱 레포 `secret:seal`) owner가 라이브 컨트롤러 공개키로 봉인하는 앱·부가 시크릿:
  앱 `*-secrets`·data-conn·adguard-auth·argocd-notifications·files-keys·ghcr-pull(prod·files)·ghcr-read.
  라이브 컨트롤러 sealing key에 종속돼도 무방한(DR은 sealing key 백업 체인이 커버) 등급.

**판정 규칙(신규 시크릿):** "부트스트랩/DR bring-up 경로가 이 값을 컨트롤러 없이 요구하는가?"
→ 예: SOPS(seed-secrets 배선). 아니오(앱·부가·자동화 산출): SealedSecrets(`make seal-*` 또는
`secret:seal`). 회색지대는 SOPS로(DR 안전측).

### 부록 — 크리덴셜 → 소비자 평면 매트릭스(토폴로지, 값 아님)

토큰 1개가 여러 봉인/시드 평면에 흩어져 회전 시 일부 평면이 stale로 남는 클래스(GHCR·telegram
실증). 아래는 값이 아니라 *어느 파일이 같은 크리덴셜을 소비하는가*의 지도다(출처: `seed-secrets.sh`
heredoc·sealed 산출물 경로 — 비-secret). 실제 회전 절차·revoke 확인은 owner-local 런북(비커밋).

| 크리덴셜 | SOPS(`*.enc.yaml`) | SealedSecret(`*.sealed.yaml`) | Actions secret / 기타 |
|---|---|---|---|
| telegram 봇 토큰 | `victoria-stack/prod/alerting.enc.yaml`, `cnpg/prod/restore-drill-alerting.enc.yaml` (2) | `argocd/extras/argocd-notifications-secret.sealed.yaml` (1) | `TELEGRAM_BOT_TOKEN`(github tf) (1) |
| R2 pg/cache 키 | `cnpg/prod/r2-creds.enc.yaml`, `cache/prod/cache-r2-creds.enc.yaml` (2) | — | `R2_*`(github tf)·`infra/*/backend.hcl` state 버킷 재사용 |
| GHCR_PULL_TOKEN | — | `ghcr-pull/prod/ghcr-pull.sealed.yaml`, `files/prod/ghcr-pull.sealed.yaml`, `victoria-stack/prod/ghcr-read.sealed.yaml` (3) | — (owner-local `.env.secrets`) |
| cert-manager CF | `traefik/prod/cloudflare-api-token.enc.yaml` (1) | — | (broad `TF_VAR_cloudflare_api_token`은 별개 토큰 — tf provider 전용) |

**회전 원칙:** 크리덴셜 회전 = 그 행의 *모든* 평면 재생성. 클러스터 평면(SOPS+Sealed)은 `make
seed-secrets`(SOPS) + `make seal-*`(Sealed)로, Actions/backend 평면은 owner-local(tf apply·backend.hcl)로.
CI측 telegram은 실패 시에만 발화하므로 Actions 평면 stale이 조용히 알림 공백을 만든다(회전 PR
체크리스트가 owner-local 평면 확인을 강제 — 아래 런북).
