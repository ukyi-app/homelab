# T09 시크릿 체계

- 단계: P2 플랫폼 구축 (재분해 T05 2026-10-18)
- 상태: 진행 중 (2026-10-19 착수. 끝난 것: Infisical 가입·프로젝트 5개·identity 4개(사람 포함), U05(배포 키 OIDC 확정), ESO v2.13.0과 ClusterSecretStore 2개(PR #757), 부트스트랩 Secret과 읽기 경계(`homelab`만 200), 시나리오 6(PR #759·#760)·7(PR #761·#762·#764. 시험용 client secret 장애 주입, 운영 자격 로그인 200으로 복구, 자동 재동기화)의 E3 동등 절차, e3-probe 정리(PR #765)와 Infisical 시험 키 삭제, Argo CD `owner` 비밀번호(PR #766·#767, 로그인 200), 회전 런북 초안·`bootstrap.md` 2.2 선행 조건. 남은 것: Grafana·AdGuard 관리자 자격, 새 Telegram 봇, Terraform 자격 3종(`homelab-admin`), 복구 자산 목록과 두 곳 보관)
- 명세: [../spec.md](../spec.md)
- 설계: [../platform/design.md](../platform/design.md) E.1 E3과 "E3의 동등 절차", E.2 E3 행, C.4.8, C.6, B.8 "E3 시크릿", F D-04·D-10·D-20
- Blocked by: T07
- 선행 결정: D-04 (확정(사용자 2026-10-18): Infisical Cloud Free, identity 4/5), D-07 (확정(사용자 2026-10-18, T05): 배포 PR 자동 병합. 그래서 병합 키 원본 프로젝트 `homelab-ci-merge`와 Secret Sync가 유지됨), D-10 (확정(사용자 2026-10-18, T05): homelab 알림용 Telegram 새 봇을 이 티켓에서 만듦. 옛 봇 토큰은 재발급하지 않음), D-20 (확정(사용자 2026-10-18, T05): 모든 값을 새로 발급), D-23 (확정: public 유지, 운영 민감 문서는 저장소 밖), Kubernetes 시크릿 전달 계층 (확정(사용자 2026-10-18, T05): ESO v2.13.x)
- 연결 AC: AC-P10
- 수행: 에이전트 + 사람 (Infisical 가입(2FA), identity와 client secret 발급, 새 외부 토큰 발급, Telegram 새 봇, 복구 자산 보관, 장애 주입 승인)

## 목표

시크릿 원본을 Infisical 한곳에 두고, 클러스터에는 ESO로 자동 전달한다.

## 선행 조건

- T07이 끝났다. 이 티켓은 T07이 만든 Argo CD·root·`argocd-cm`(ExternalSecret health 덮어쓰기 자리)과 다시 켠 Actions(OIDC 시험 워크플로)를 쓴다.
- D-04, D-20이 확정됐다.

## 첫 작업: 배포 키 OIDC 확인 (U05)

다른 작업보다 먼저 한다. 이 결과가 T10의 키 전달 방식을 정한다(설계 C.4.8).

- Infisical OIDC Auth를 Free에서 쓸 수 있는지 본다.
- 배포 identity `gha-homelab-deploy`를 claim으로 묶을 수 있는지 본다. `sub` 문자열 대신 개별 claim으로 묶는다: `repository_owner = ukyi-app`, `ref = refs/heads/main`, `event_name = push`, `job_workflow_ref = ukyi-app/homelab/.github/workflows/app-build.yaml@refs/tags/app-build-v*`. glob이 안 되면 태그를 만들 때마다 이 claim 값을 사람이 바꾼다(설계 C.4.8).
- 시험 워크플로는 시크릿 없는 시험 키로 하고 끝나면 지운다.
- 안 되면 배포 키도 앱별 Secret Sync(앱 저장소 public, 앱 9개까지)로 전환하고 기록한다(설계 F D-04). `app-build`의 test·push job에서 OIDC 토큰이 발급되지 않는지는 시나리오 15에서 다시 본다.

## 범위

- Infisical 프로젝트 5개와 identity 4개(D-04, 설계 C.6.3). Free 요금제다.
  - 프로젝트는 읽는 주체가 다른 키마다 나눈다. Free에는 경로 RBAC가 없어 프로젝트만 경계가 되기 때문이다: `homelab`(`prod`, 운영 값), `homelab-dev`(`dev`, 로컬 개발·VM 검증 값), 사람 전용 `homelab-admin`(`prod`, Terraform 자격, machine identity 없음), 배포 키 `homelab-ci-deploy`(`prod`), 병합 키 `homelab-ci-merge`(`prod`, machine identity 없음).
  - identity는 5개 한도 중 4개를 쓴다: 사람, `eso-homelab`(운영 ESO, `homelab`만 읽기), `eso-homelab-dev`(VM 시험 ESO, `homelab-dev`만 읽기. client secret은 T13이 VM을 준비할 때 발급), `gha-homelab-deploy`(배포 App 키, OIDC, `homelab-ci-deploy`만 읽기). `gha-homelab-merge`는 만들지 않는다.
  - 병합 App 키의 원본 자리는 프로젝트 `homelab-ci-merge`다. GitHub environment `automerge`로 가는 Secret Sync와 그 App Connection(fine-grained PAT)은 environment를 만드는 T10에서 설정한다. D-07(확정)이 자동 병합을 골라 병합 키와 sync는 유지된다.
  - 더 필요하면 Pro(identity당 월 $20 연간, $23 월간)로 바꾼다. 옛 비상안(VM identity를 시험 때만 만듦)은 영구 여유를 만들지 못해 쓰지 않는다.
- `platform/external-secrets`: ESO v2.13.x(설계 기준 v2.13.0, chart 2.13.0)와 ClusterSecretStore 2개(`infisical-platform`, `infisical-apps`). Infisical 연결은 Universal Auth다. 규칙은 `external-secrets.io/v1`만, 키는 `data[]`로 하나씩 명시, `deletionPolicy: Retain`, `creationPolicy: Owner`, `find`·`recursive` 금지다(설계 C.6.1). ESO는 2~3주마다 새 minor가 나와 D-18의 갱신 대상이다.
- ESO 부트스트랩 Secret `external-secrets/infisical-universal-auth`. 평상시 사람이 클러스터 밖에서 넣는 유일한 자격이다(설계 C.6.4). ESO용 Universal Auth client secret은 사용 횟수 무제한으로 둔다. 1로 두면 두 번째 동기화부터 실패한다(추측, 설계 B.8 "E3 시크릿").
- ESO 최초 접속 자격증명의 별도 암호화 보관.
- 플랫폼 시크릿 등록: `homelab`에 새 Telegram 봇 토큰, Grafana·AdGuard·Argo CD 관리자 자격. Terraform 자격은 `homelab-admin`에만 둔다.
- 복구 자산 목록과 복구 순서 (Infisical 장애, 계정 잠김, 클러스터 유실). 저장소가 public이므로(D-23) 목록은 저장소 밖 비공개 위치에 두고, 저장소 문서에는 위치와 항목 이름만 둔다. 복구 자산은 NUC 밖 두 곳에 저장한다(설계 C.6.4).
- 외부 토큰 새로 발급과 등록(D-20): Cloudflare Terraform용 토큰, R2 state 버킷 키, Tailscale Terraform용 OAuth(ACL과 DNS 쓰기, 기기 읽기). 셋 다 `homelab-admin`에 등록한다. 옛 자격 폐기는 T06의 자격 폐기 표가 맡는다. D-20 확정으로 T06이 `보류(…, T09)`로 미리 정한 줄은 없다. 실행 중 그런 줄이 생기면 이 티켓이 새 자격을 등록한 뒤 옛 자격을 폐기해 닫는다. 새 구조에 대응 자격이 없는 것은 새로 발급하지 않는다: cert-manager DNS-01용 Cloudflare 토큰(D-08), GHCR pull PAT(D-29).
- homelab 알림용 Telegram 봇을 새로 만든다(BotFather, D-10). 새 봇은 대화를 먼저 시작할 수 없어 사람이 새 봇에게 먼저 메시지를 보낸다. 토큰은 `homelab`에 등록한다. 옛 봇의 토큰은 재발급하지 않는다. 재발급은 옛 토큰을 끊는다고 봐야 하고(추측), 그 토큰을 쓰는 저장소 밖 `mac-uptime-guard`의 알림이 T22까지 아무 표시 없이 멈추기 때문이다. 옛 봇과 토큰은 T22가 `mac-uptime-guard`를 처리할 때까지 그대로 둔다. **2026-10-19 실제:** 사용자가 `mac-uptime-guard`를 쓰지 않아 옛 봇 토큰은 T06에서 폐기하기로 했다(approvals). 새 봇 생성은 그대로 이 티켓이 한다.
- 옛 SOPS age 개인 키: NUC에 `~/.config/sops/age/keys.txt`가 있다. 옛 SOPS 파일의 recipient와 맞으면 옛 공개 저장소 히스토리의 SOPS 파일을 풀 수 있다(일치 여부 미확인). 새 구조에서 쓰지 않으므로 복구 자산에 넣지 않는다. T06이 자격 폐기 완료를 확인한 뒤 지운다(D-20). 키 값은 다루지 않는다. **2026-10-19 실제:** T06이 cluster 키를 `age-keygen -y`로 대조한 뒤 지웠다(approvals).
- 같은 앱 안의 시크릿 범위 분리. 같은 봇 안에서도 게시 서버와 작업자의 시크릿 범위를 나눌 수 있는 구조를 이 티켓이 준비한다(명세 §4.2). 작업자 쪽은 T08b 격리 작업 공간이 받는 모델 자격 범위다(작업자 전용 ClusterSecretStore `infisical-sandbox`도 T08b). 봇 시크릿(Discord 토큰, 봇 GitHub App 키, 모델 자격) 등록 자체는 T16b~T19에서 한다(명세 §11 Infisical 행).
- 회전 절차 초안(`docs/runbooks-public/rotate.md`)에 병합 App 키 회전 순서를 넣는다: (T10 뒤) `homelab github verify` exit 0 확인 → 새 키 발급 → Infisical 값 교체 → environment secret `updated_at`이 교체 시각 이후인지 확인 → 옛 키 삭제. App 키는 만료가 없고 25개까지 동시에 유효해 `deploy-merge` 성공만으로는 새 키 반영을 증명하지 못한다. sync 실패 알림은 프로젝트 Admin 메일로 온다.

## 시나리오 6·7의 E3 동등 절차

경보(T08b), 배포 PR 흐름(T10), `homelab status`(T12)는 이 티켓 뒤에 생긴다. 그래서 이 티켓은 시나리오 6·7을 그 산출물 없이 시험 ns에서 같은 확인으로 통과시킨다. 세부는 설계 E3 표 아래 "E3의 동등 절차"다.

- **대상:** root 아래에 PR로 더한 시험 Application `e3-probe`(프로젝트 `platform`, ns `app-e3-probe`. `infisical-apps` store의 conditions가 `app-*`라서다). 원본은 `platform/e3-probe/`에 손으로 쓴 Deployment 1개(digest로 고정한 공개 이미지, readiness, 키마다 `valueFrom.secretKeyRef`, `envFrom` 없음)와 ExternalSecret 1개(키마다 `data[]`)다. 값은 사람이 Infisical `homelab`/`prod`의 `/apps/e3-probe/`에 만든 시험 키 하나다. `argocd-cm`에 ExternalSecret health 덮어쓰기(설계 C.3.3)가 있어야 한다.
- **시나리오 6(E3 범위):** Infisical에 없는 키를 ExternalSecret `data[]`와 Deployment env에 더하는 손 PR 병합 → `kubectl -n app-e3-probe get externalsecret e3-probe -o jsonpath='{.status.conditions[0].reason}'` → `SecretSyncedError`, 대상 Secret의 `sha256sum`이 전후 같음, 새 파드 `CreateContainerConfigError`와 옛 파드 Ready, `kubectl -n argocd get application e3-probe -o jsonpath='{.status.health.status}'` → `Degraded`(지금 spec으로 동기화한 이력 없음). revert PR → Healthy.
- **시험용 client secret 장애 주입:** 운영 ESO client secret(복구 자산의 값)은 폐기하지 않는다. 폐기하면 저장소 밖 복구 자산이 폐기된 값으로 남는다. 대신 `eso-homelab`에 시험용 두 번째 Universal Auth client secret을 발급한다. 부트스트랩 Secret `external-secrets/infisical-universal-auth`의 `clientSecret`만 그 값으로 바꾸고(값은 출력하지 않는다) ClusterSecretStore Ready를 확인한 뒤, Infisical에서 두 번째 secret을 폐기해(승인 기록) 장애를 낸다. 복구는 부트스트랩 Secret을 원래 secret으로 되돌리는 것이고, 두 번째 secret은 폐기된 채 남긴다. T08b·T10·T13도 이 방법을 쓴다.
- **시나리오 7(E3 범위):** 위 장애 주입(승인 기록) → ExternalSecret 즉시 갱신 annotation으로 실패를 바로 일으킴 → `kubectl get clustersecretstore` Ready=False, 기존 Secret 그대로 → `kubectl -n app-e3-probe delete pod -l app=e3-probe` 뒤 기존 Secret으로 Ready → Deployment 이미지 digest만 바꾸는 손 PR 병합 → 새 파드 Ready, Application Healthy(health 덮어쓰기, U07) → 새 키를 요구하는 손 PR → Degraded, 원인은 ExternalSecret conditions에 보임 → 부트스트랩 Secret을 원래 client secret으로 되돌림 → Ready 복귀와 자동 재동기화.
- **넘기는 확인:** ExternalSecretNotReady 경보와 Telegram 수신은 T08b, 이미지만 바꾸는 배포 PR의 자동 병합은 T10, `homelab status`가 빠진 키와 다음 명령을 보여 주는지는 T13(시나리오 6·7 전체를 `homelab-smoke`로)이 본다.
- **정리:** 끝에 시험 Application·`platform/e3-probe/`를 지우는 PR을 병합하고 Infisical 시험 키를 지운다.

## 필요한 자격

이 티켓이 쓰는 자격과 준비하는 곳:

- Infisical 계정: 이 티켓에서 사람이 가입한다(2FA). 요금제 선택, identity 생성, Universal Auth client secret 발급도 이 티켓이다.
- Cloudflare·R2·Tailscale 콘솔 로그인: 새 Terraform 자격을 발급한다. 기존 계정이다.
- Telegram 계정: BotFather로 새 봇을 만든다. 기존 계정이다.
- GitHub owner 계정: OIDC 시험 워크플로, `e3-probe` 손 PR 병합. Actions는 T07이 다시 켰다.
- 클러스터 관리자 kubeconfig: ESO 부트스트랩 Secret, 장애 주입. T07이 만든다.
- 복구 자산 보관 위치 두 곳(예: 비밀번호 관리자와 오프라인 암호화 사본). 저장소 밖, NUC 밖이다.

이 티켓이 뒤 티켓에 준비하는 자격(설계 E.2 "완료 기준이 쓰는 것" 표):

- T08a: Cloudflare Terraform 토큰, Tailscale Terraform OAuth, R2 state 키(`homelab-admin`). AdGuard 관리자 자격(`homelab`). 터널 토큰·operator OAuth를 ESO로 받는 경로.
- T08b: 새 Telegram 봇 토큰, Grafana 관리자 자격(`homelab`). Telegram 토큰·healthchecks URL을 ESO로 받는 경로.
- T10: Infisical 프로젝트와 배포 OIDC identity `gha-homelab-deploy`, R2 state 자격(`homelab-admin`), 병합 키 원본 자리 `homelab-ci-merge`.
- T11: 플랫폼 시크릿 전달.
- Argo CD 관리자 자격(`homelab`): 이 티켓이 받는다(사용자 결정 2026-10-19, T07). `argocd-secret`에 `accounts.owner.password`(bcrypt)와 `accounts.owner.passwordMtime`을 합치는 ExternalSecret(`creationPolicy: Merge`)을 둔다. T07은 `admin`을 끄고 `owner`만 두므로 그 전까지 Argo CD는 `kubectl`·`argocd --core`로만 다룬다. `platform/argocd` kustomization에서 `argocd-secret`을 patch하지 않는다(T07 주석).
- T13: `eso-homelab-dev` identity와 `homelab-dev` 프로젝트. client secret 발급과 키 채우기는 T13이 VM을 준비할 때 한다.

## 제약

- 에이전트는 시크릿 값을 출력하거나 조회하지 않는다. 확인은 응답 코드와 이름으로만 한다(설계 B.8 "E3 시크릿").
- 클러스터에는 Cloudflare 토큰을 두지 않는다(터널 토큰만). Terraform 자격은 `homelab-admin`에만 둬 ESO identity도 읽지 못한다.
- 옛 저장소 교훈(설계 E3 "옛 저장소에서 가져올 것")과 설계 B.8 "E3 시크릿" 함정은 해당 설정 옆 주석으로 옮긴다.

## 완료 조건

- ClusterSecretStore 2개(`infisical-platform`, `infisical-apps`)가 Ready다. 시험 ns의 ExternalSecret이 동기화된다.
- identity가 4개(사람, `eso-homelab`, `eso-homelab-dev`, `gha-homelab-deploy`)다. `homelab-ci-merge`에 machine identity가 없다.
- `eso-homelab`이 `homelab` 밖의 프로젝트(`homelab-admin`, `homelab-dev`, `homelab-ci-*`)를 읽지 못한다.
- 배포 키 OIDC 방식이 확정됐다. 안 되면 배포 키도 앱별 Secret Sync로 전환하고 기록했다(설계 F D-04).
- 위 동등 절차로 시나리오 6·7의 E3 범위를 통과한다: `SecretSyncedError`, Secret 불변, `CreateContainerConfigError`, 기존 Secret 유지, ExternalSecret health 덮어쓰기. 경보·Telegram 수신(T08b), 배포 PR 자동 병합 흐름(T10), `homelab status` 표시(T13)는 이 티켓의 완료 조건에서 뺀다. 어느 항목도 T08b·T10·T12의 산출물을 쓰지 않는다.
- 복구 자산의 운영 ESO 자격으로 Infisical 로그인이 성공한다(장애 주입 전과 뒤).
- 복구 자산 목록이 있다. 저장소가 public이면 목록은 저장소 밖에 있고, 저장소 문서에는 위치와 항목 이름만 있다.
- T06 자격 폐기 표에 `보류(…, T09)` 줄이 있으면 모두 `삭제됨` 또는 `유지(이유)`로 바뀌었다. 실행은 [approvals.md](../approvals.md)에 있다. 다음 두 줄은 이 닫기에서 뺀다: 옛 healthchecks ping URL 줄 `보류(D-10, T08b)`은 T08b가 닫고, 옛 Telegram 봇 토큰 줄 `보류(D-10, T22)`는 T22가 `mac-uptime-guard`를 처리한 뒤 닫는다. D-10 대안(옛 봇 토큰 재발급)은 고르지 않았으므로 이 티켓이 옛 Telegram 줄을 닫는 분기는 없다.
- `e3-probe` 정리 PR이 병합됐고 Infisical 시험 키가 지워졌다.

## 검증

- `kubectl get clustersecretstore -o wide`.
- 필수 키를 일부러 빼고 배포해 실패 메시지를 확인한다: 없는 키를 가리키는 시험 ExternalSecret → `kubectl get externalsecret -o jsonpath='{.status.conditions}'`에 `SecretSyncedError`, 대상 Secret 없음. 이어서 위 시나리오 6 동등 절차.
- ESO의 Infisical 접근을 끊고 기존 Secret과 서비스가 유지되는지 확인한다: 시험용 client secret 장애 주입 → 기존 시험 Secret 유지, Ready=False(경보는 T08b에서 본다) → 부트스트랩 Secret을 원래 client secret으로 되돌려 복구. 이어서 위 시나리오 7 동등 절차.
- 복구 자산의 운영 ESO client ID·secret으로 Infisical Universal Auth 로그인 → 성공. 토큰은 출력하지 않고 응답 코드만 본다. 장애 주입 전과 뒤에 한 번씩 한다.
- `eso-homelab`의 Universal Auth로 로그인한 토큰으로 `homelab-admin`·`homelab-dev`·`homelab-ci-*` 값 조회 → 모두 거부. 값은 출력하지 않고 응답 코드만 본다.
- 첫 작업(U05)의 결과가 작업 기록에 있다.

## 되돌리는 방법

- ESO Application을 revert PR로 제거한다(시험 ns만 영향).
- 부트스트랩 Secret을 지우고 identity를 비활성화한다.
- Infisical 프로젝트와 값은 남긴다.
- 되돌리기 실행도 [approvals.md](../approvals.md)에 기록한다.
