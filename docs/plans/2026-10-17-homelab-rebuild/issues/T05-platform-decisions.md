# T05 플랫폼 결정 확정·구축 티켓 재분해

- 단계: P1 플랫폼 설계 (결정 게이트)
- 상태: 대기
- 명세: [../spec.md](../spec.md) §5.3
- Blocked by: T04
- 연결 AC: AC-P3, AC-X1
- 수행: 사람 (결정) + 에이전트 (문서·티켓 갱신)

## 목표

구축에 들어가기 전에 플랫폼 결정을 모두 확정하고, 구축 티켓을 설계에 맞춘다.

## 할 일

1. 설계 문서 F와 D-05~D-07, D-09~D-12, D-18, D-20, D-21, D-22, D-25(병합 방식), D-26(Codex Connector), D-27(로컬 자료 입력)을 결정한다. 이 목록은 AC-P3과 같다(명세 §7). 명세 §5.2·§5.3의 추천을 참고한다.
   - 이미 확정된 것: D-04(Infisical Cloud Free, identity 4/5)와 D-08(내부 UI `*.ts.net`, Tailscale DNS (b′))은 확정(사용자 2026-10-18)이다. 같은 날 새 결정 D-28(GitHub 보호 설정 Terraform)·D-29(저장소 공개 정책)와 D-13의 일부(봇 저장소 가시성, 옛 aiops 처리)도 확정(사용자 2026-10-18)이다(명세 §5.1).
   - D-07을 정할 때 D-04 의존을 함께 본다: 자동 병합을 하지 않기로 하면 병합 App 키와 Secret Sync가 사라지고 identity는 그대로 4/5다.
2. 결정을 설계 문서와 명세 §5에 기록한다 (누가, 언제). 같은 변경에서 그 결정 ID로 자리를 둔 문서 위치를 채운다. 명세 §12대로 `bot/` 전체와 플랫폼 프롬프트에서 D-ID를 검색해 자리를 채운다. D-25를 정하면 D-03 문구도 맞춰 고친다.
3. 설계 문서 E를 기준으로 T06~T13의 범위·순서·의존성을 갱신한다. 필요하면 쪼개거나 합친다.
4. 명세 §4.4의 배정에 맞춰, 아래 자리마다 만들 구축 티켓을 정한다. 지금 잠정 배정은 Argo CD 읽기 전용 계정 T07, 공개 webhook 수신 경로·Alertmanager 외부 수신자·Kubernetes·관측 읽기 전용 계정·격리 작업 공간 T08, 리뷰 전용 App 구조 T10이다.
   - AC-P12 다섯 자리: 공개 webhook 수신 경로, 읽기 전용 접근(관측·Argo CD·Kubernetes), Alertmanager 경보 외부 수신자, 격리 작업 공간, 리뷰 전용 App.
   - AC-P11 두 자리: 비AI 알림, 외부 생존 감시.
   - AC-P8: 병합 조건 공개와 봇 변경 PR의 자동 병합 차단.
5. 확정 안 된 간선 T09 → T10을 D-04(확정(사용자 2026-10-18))가 정한 App 키 전달 방식(배포 키는 Infisical OIDC, 병합 키는 Secret Sync → environment `automerge`)에 맞춰 정한다. 착수와 완료를 나눌지도 함께 정한다.
6. 구축 티켓마다 필요한 외부 자격증명과 그것을 준비하는 티켓을 대조한다. 지금은 T08이 T09의 토큰 등록을 선행으로 둔다.
7. 명세 §8 그래프를 갱신하고 순환이 없는지 확인한다.
8. 설계 문서 E의 단계별 "되돌리는 방법"을 각 구축 티켓에 옮긴다.
9. T06 선행 확인의 NUC 로컬 보존 범위를 D-12와 함께 정한다. 대상은 명세 §4.5의 "NUC 로컬 전용 자료"다.
10. 옛 `ukyi-app/aiops` 저장소와 `ukyi-homelab-aiops` App은 제거(삭제), `aiops-autodeploy-canary`와 `mac-uptime-guard`는 공개하지 않고 private 보관으로 확정(사용자 2026-10-18)이다(D-13 일부, D-29). 실행은 T22에서 한다. T06과 T22에 이 내용이 반영돼 있다.
11. T04 검토 과정과 2026-10-18 결정에서 설계에는 들어갔지만 티켓에는 아직 없는 항목을, 3번 재분해 때 해당 티켓에 옮긴다. 설계 문서 E와 C가 기준이다. 결정에서 바로 나온 범위·완료 조건(D-04, D-08, D-28, D-29, `page`·`trip-mate-api` 삭제)은 2026-10-18에 T06~T10, T13, T14, T22에 먼저 넣었고, 재분해 때 아래 목록과 대조한다.
    - T06: 임시 ruleset `main-interim`과 `allow_auto_merge=false`를 옛 보호 해제와 같은 단계에서 적용한다. 순서는 `main-interim` 생성 → active 확인 → 옛 브랜치 보호 전체 DELETE → 404 확인 → `allow_auto_merge=false`다(설계 E1). 이 단계의 GitHub 변경은 `gh api`로 하고 T10에서 import한다(D-28). 옛 aiops App이 homelab에 설치돼 있으면 homelab 설치만 해제한다. 자격 폐기 표에 삭제하는 앱의 자격(`trip-mate-api`의 Google OAuth client·OXR app id·`BETTER_AUTH_SECRET`, `page` admin token)이 있다. `page`·`trip-mate-api` 저장소와 GHCR 패키지는 삭제했다(D-29, 2026-10-18 실행).
    - T07: main 교체 뒤 최소 `ci`를 필수 검사로 더한다. 이 `ci` ruleset은 `gh api`로 만들고, T10이 import하면서 제자리에서 `main-checks`로 이름을 바꾼다(D-28). `platform/root`(Helm 차트)에 `root-prod.yaml`, `root-vm.yaml`, 클러스터 값 파일을 둔다. `host/clusters/{prod,vm}.env`를 둔다. MagicDNS 이름은 env에 두지 않는다. OS를 다시 설치했으면 옛 NUC 기기를 지우고 다시 등록한다. rebuild → main 병합 전에 자기 저장소 참조 revision을 손으로 확인한다.
    - T08: 봇 자리 Application `platform/bot-slot`(wave 1, retry 무제한·`refresh: true`, 시험 ns `bot-slot-probe`)을 둔다. 작업자 egress에서 DNS를 뺀다. 차트 egress에서 tailnet 대역을 뺀다. 옛 healthchecks 줄 `보류(D-10, T08)`을 닫는다. Tailscale DNS를 Terraform `tailscale_dns_configuration`으로 관리한다(D-08: `data.tailscale_devices` precondition, 첫 apply 전 콘솔 값 이전과 plan 무변경 확인, DNS 별도 root `infra/tailscale-dns`, `prevent_destroy`, count 없음). AdGuard servicelb의 ratelimit 버킷 공유를 확인한다. "tailnet 출처 질의 1시간 0건" 경보를 둔다. 시나리오 14에 D-08 추가 확인을 넣는다. R2 state 잠금 동시 실행 시험을 한 번 한다(U02, D-28).
    - T09: Infisical 프로젝트를 키마다 나눈다(배포 `homelab-ci-deploy`, 병합 `homelab-ci-merge`, 사람 전용 `homelab-admin`, VM용 `homelab-dev`). identity는 4개(사람, `eso-homelab`, `eso-homelab-vm`, `gha-homelab-deploy`)이고 `gha-homelab-merge`는 만들지 않는다(D-04). `rotate.md`에 병합 키 회전 순서를 넣는다. 장애 주입은 시험용 두 번째 client secret으로 한다.
    - T10: Terraform github root `infra/github`, 래퍼 `tools/tf-github.sh`, guard(`github_rest_api` postcondition), CI의 `terraform test`, `main-interim`·`ci` ruleset import(D-28). 병합 키 Secret Sync(fine-grained PAT App Connection)와 environment `automerge`, `deploy-merge`의 `secrets.HOMELAB_MERGE_KEY`, ci의 workflow-guard(D-04). 앱 저장소와 `homelab-app-template`의 `app-main` ruleset과 CODEOWNERS를 대조한다(결정 5로 먼저 건 것은 import). attestation 출처 확인을 넣는다. attestation은 항상 만든다(private 앱 경로 없음, D-29). GHCR 패키지 Public 시험, public 앱 저장소 기본 설정, push job 캐시 없음, 템플릿 CI 금지 패턴 검사(D-29). 앱 저장소 읽기에는 `GITHUB_TOKEN`을 쓴다. 공유 차트에 `serviceAccountName`을 추가한다. ci가 platform 로컬 Helm 차트(`root`, `bot-slot`)도 렌더해 검사한다.
    - T12: `homelab github plan·apply·verify`가 T10의 래퍼를 감싼다(D-28). `homelab app new --private`은 두지 않고, `homelab app add`는 private 저장소와 익명 GHCR pull이 안 되는 패키지를 거부한다(D-29).
    - T13: VM 준비 자산을 마련한다(`eso-homelab-vm` 자격, `homelab-dev` 키 채우기, 전용 R2 버킷·serverName, `vm-` 이름). VM 호스트는 tailnet에 넣지 않는다(`TAILNET_JOIN=false`). VM은 운영 공개 URL과 운영 Tailscale 기기를 건드리지 않는다. 시나리오 14에 D-08 추가 확인(셀룰러 Tailscale 기기, 사용자 규칙 적용률)을 넣는다.
    - T14: D-13의 확정 부분(public 봇 저장소, 운영 산출물은 저장소 밖이나 private 위치, 옛 aiops 제거)과 D-29의 봇 조건(모델 호출 전 `author_association` 확인)을 봇 문서 자리에 채운다.
    - T16: 봇 자리 `target`을 봇 ns로 바꾸는 PR을 봇 등록 PR보다 먼저 병합해, 콜드스타트 순서를 재현하고 확인한다.
    - T22: 대상은 `files`(재연결), `homelab-app-template`(새 구조 확인), 옛 aiops 저장소·App 삭제, `aiops-autodeploy-canary`·`mac-uptime-guard` private 보관이다. `page`·`trip-mate-api` 재연결과 private 앱 완료 기준은 넣지 않는다(D-29).
12. 결정과 갱신한 문서를 `rebuild`에 커밋한다. push는 사람 승인 뒤에 한다(명세 §12).

## 완료 조건

- 할 일 1의 결정이 전부 결정됐거나, 이유와 재결정 시점을 단 보류 상태다. 보류한 결정에 의존하는 티켓에는 대기 표시가 있다.
- T06~T13이 설계 문서 E와 일치하고, 할 일 4의 자리마다 담당 티켓이 있다.
- 각 구축 티켓에 되돌리는 방법이 있다.
- 결정과 갱신한 문서가 `rebuild`에 커밋돼 있다.

## 검증

- 결정표에 빈 칸이 없다.
- §8.2 그래프의 모든 선행 ID가 존재하고 순환이 없다.
- 결정한 D-ID마다 `bot/`과 `platform/`을 검색해 "미정" 자리가 남지 않았다.
