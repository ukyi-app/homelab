# T23 플랫폼 후속(T13에서 넘김)

- 단계: P2 후속
- 상태: 진행 중 (2026-10-29 착수. 할 일 1 스위치(#987)와 공유 차트 태그 완료. 할 일 2·3 U40 VM 실측 통과(2026-10-29, #988·#989·#990, 기록 PR). 할 일 4 규칙 수정(#986), 남은 것: 다음 NUC 재부팅 때 `ALERTS`에 `AdGuardTailnetQueriesMissing`이 없는지와 libvirt iptables 체인이 사라졌는지 확인)
- 명세: [../spec.md](../spec.md)
- Blocked by: T13
- 선행 결정: D-12 (확정(사용자 2026-10-18, T05): 빈 NUC 검증은 VM, 설계 E8 VM 격리 조건 여섯, VM 호스트는 tailnet 밖)
- 연결 AC: AC-P5, AC-P6, AC-P10
- 수행: 에이전트 + 사람

## 목표

T13이 끝내지 않고 넘긴 플랫폼 후속을 처리한다(T13 할 일 3, 사용자 결정 2026-10-29). U40 2회차(할 일 1~3)와 시나리오 17의 재부팅 오경보(할 일 4) 둘이다. T13 결과표 [../platform/verification.md](../platform/verification.md) "한계와 후속"의 13 U40 줄과 17 `AdGuardTailnetQueriesMissing` 줄이 출처다.

## 할 일

1. U40 시험에 필요한 전역 스위치를 만든다. 지금 root에는 없다([../../../runbooks-public/restore.md](../../../runbooks-public/restore.md) 3절 U40 문단). `platform/root/values.yaml`의 `components.externalSecrets.enabled`는 ESO operator와 Store Application만 끄고, ExternalSecret은 앱·데이터 공유 차트(`platform/charts/app`, `platform/charts/app-data`)와 플랫폼 구성 요소(Kustomize 포함) 여러 곳에 따로 있다. 그 값을 끄면 빈 클러스터에는 ESO CRD도 없어 남은 ExternalSecret을 적용하지 못한다.
   - 설계 C.6.4 "클러스터 유실 + Infisical 장애" 행과 부록 1 U40 행대로, 복구 PR의 root 값 하나가 ClusterSecretStore와 모든 ExternalSecret을 렌더하지 않게 값을 전달한다. 설계 행은 이 값을 `externalSecrets.enabled`로 적는다. 실제 키 이름과 전달 경로는 구현 때 정하고 설계 행을 같은 변경에서 맞춘다.
   - 기본값은 지금 렌더와 같아야 한다. 운영 렌더가 바뀌지 않는 것을 ci 렌더 비교로 보인다.
   - 공유 차트를 바꾸면 차트 버전과 git 태그를 올린다(설계 C.4.5). 태그 생성은 사람 승인 뒤다.
   - VM 격리 조건(T13 할 일 2, 설계 E8)대로 이 값은 VM의 복구 PR(`values-vm`)에서만 끈다. 운영 values는 바꾸지 않는다.
   - 결과(2026-10-29): 스위치는 `cluster.restore.externalSecrets: false`(복구 PR이 `values-<클러스터>.yaml`에만, 없으면 켜짐)다. 끄면 Store 3개와 ExternalSecret 11개(클러스터마다), 공유 차트의 ExternalSecret 전부가 렌더되지 않고 `external-secrets-stores`·`edge-probe` Application이 빠진다. ESO operator는 남는다. cloudflared는 로컬 Helm 차트로, 관측 ExternalSecret 셋은 같은 Application의 Helm source로 옮겼다. 공유 차트 `app` 1.2.0·`app-data` 1.1.0. 기본값 렌더는 바뀌지 않는다(root 아래 410개 바이트 동일, ci 단계 `external secrets switch`가 지킨다). 스위치를 끄지 않은 PR은 옛 chartVersion 앱도 통과하고, 끈 클러스터에서만 원인을 말하며 실패한다. 로컬 codex 리뷰 2라운드(1라운드 P2 둘 수정, 2라운드 지적 없음).
2. U40(설계 부록 1)을 VM에서 실제로 해 본다. T13 시나리오 13과 같은 VM 격리 조건 여섯으로 하되, VM이 Infisical에 닿지 못하게 막고 빈 클러스터를 복구한다.
   - 확인할 가정(설계 부록 1 U40 행): 할 일 1의 스위치를 끄면 root wave가 손으로 만든 Secret만으로 끝까지 진행하고, 값을 되돌렸을 때 ESO가 같은 이름의 기존 Secret을 넘겨받는다.
   - 넘겨받지 않거나 root가 진행하지 않으면 설계 부록 1 U40 행의 대안(되돌리는 PR 직전 손 Secret 삭제, 필요한 Application만 손으로 sync)을 `restore.md`에 절차로 둔다. 설계 C.6.4 행과 맞춘다.
   - 손으로 만드는 Secret의 값은 저장소 밖 암호화 내보내기에서 온다. 화면·파일·인자에 남기지 않는다.
   - 결과(2026-10-29): 판정 `실제 검증 완료`(가정 둘 다 통과, 대안을 쓰지 않았다). VM 클러스터 CoreDNS로 `infisical.com`을 NXDOMAIN으로 막고(설계 E8 VM 격리 조건 그대로, 운영 무변경), 복구·끔 PR #988(`42c8b6e`) 뒤 손 Secret 10개(Owner 9, `argocd-secret` Merge 1, 키 17)를 root apply 전에 넣었다. root는 retry 없이 끝났고 Application 17개 Synced/Healthy, 손 sync 0회, DB 복구(`system_identifier` 같음, 새 base backup)도 됐다. 차단을 풀고 켜는 PR #989(`6a946cd`) 뒤 ESO가 10개를 모두 넘겨받았다(UID 그대로, 해시 = 내보내기 기대값, canary 바뀜, 파드 재시작 0). 정리 PR #990(`99cec1a`). 한계: 앱 0개라 공유 차트·ApplicationSet 생성 Application 경로는 라이브로 보지 않았다(사용자 결정 2026-10-29). 시험 healthchecks 체크·Telegram 봇은 만들지 않고 가짜 값을 썼다(사용자 결정 2026-10-29, 알림은 판정 밖). VM과 외부 시험 자원은 2026-10-29~30에 모두 정리했다(approvals).
3. 결과를 T13 결과표의 13 U40 줄, 설계 부록 1 U40 행, `restore.md` 3절 U40 문단에 기록한다.
   - 결과(2026-10-29 기록 PR): 결과표 "한계와 후속" 13(결과·한계·발견·후속 네 줄), 설계 부록 1 U40 행과 C.6.4 "클러스터 유실 + Infisical 장애" 행(`[제안]` → 실제 검증 완료, 손 Secret을 지우지 않음), `restore.md` 3.1 소절(실행한 블록: 지도, 내보내기, 손 Secret, 스냅숏, 기대 해시, 넘겨받기 판정, VM 시험의 차단·확인 파드·해제), `recovery-assets.md` 내보내기 형식, `.tool-versions` age 1.3.2, `vm.md` 6절(정리 순서, AppArmor 잔여), `bootstrap.md` 2.2 vm 2단계(선택 사전 로그인), 승인 기록.
4. `AdGuardTailnetQueriesMissing`(`platform/observability/stack/vmalert/rules/adguard.yaml`)의 재부팅 오경보를 없앤다(T13 시나리오 17, 2026-10-29). 재부팅으로 svclb 파드가 새 IP를 받아도 파드 객체가 그대로면 `kube_pod_start_time`이 옛 값이라, 새 IP 출처 질의가 질의 로그 파일에 쓰일 때까지(이번에 약 2분) 울린다.
   - 기준 시각을 파드 시작 대신 svclb 컨테이너 시작 시각(예: `kube_pod_container_state_started`)으로 바꾸거나 짧은 `for`를 둔다. `for`는 실제 이탈 감지도 그만큼 늦춘다.
   - 규칙 시험(`platform/observability/stack/vmalert/tests/adguard.test.yaml`)에 "같은 파드, 새 IP" 경우를 더하고, 기존 이탈 경우가 계속 울리는지 본다.
   - 결과(2026-10-29): 기준 시각 후보에 svclb 컨테이너 시작 시각(`kube_pod_container_state_started`)을 더했다. 파드 시작 시각은 컨테이너 지표가 없을 때의 기준으로 남겼고 `for`는 두지 않았다. 규칙 시험 "같은 파드, 새 IP"는 바꾸기 전 규칙에서 5분 시점 오경보로 실패하고 바꾼 뒤 통과하며, 같은 시험의 이탈(15분)은 여전히 울린다. 운영 지표로 다시 평가: S17 오경보 시각(2026-10-28 22:16:30Z~22:18:00Z)에 옛 식은 741992초로 발화, 새 식은 빈 결과. 남은 것: 다음 NUC 재부팅 때 `ALERTS`로 확인.
   - 같은 재부팅 뒤 U40 VM 정리의 남은 것도 본다: 2026-10-29 정리 때 `vm.md` 6.3에 libvirt iptables 체인만 남았다(재부팅하면 사라짐, T13과 같음). 재부팅 뒤 6.3 블록을 다시 돌려 "남은 것 0"을 본다(통과하면 블록이 VM 상태 폴더도 지운다).

## 필요한 자격

할 일 4는 자격이 필요 없다. 할 일 1~3은 T13 시나리오 13과 같다. T13이 끝나며 VM 자원과 시험 자격을 지웠으므로(T13 결과 절 "정리", 2026-10-28) 다시 만든다(사람).

- `eso-homelab-dev` Universal Auth client secret(VM 전용, 시험 뒤 폐기).
- VM 전용 R2 버킷과 그 버킷 전용 토큰, VM operator OAuth client, 시험 터널 토큰, 시험 healthchecks 체크, 시험 Telegram 봇 토큰(모두 `homelab-dev`). 2026-10-29에는 체크와 봇을 만들지 않고 가짜 값을 넣었다(알림은 U40 판정 밖, 사용자 결정).
- 복구 자산의 R2 읽기 전용 토큰(운영 백업 버킷만, 시험 동안만 VM에 손으로).
- VM 호스트 준비는 T13과 같다(`docs/runbooks-public/vm.md`, 운영 NUC inotify 사전 확인 포함).

## 완료 조건

- 할 일 1의 스위치가 기본값에서 운영 렌더를 바꾸지 않고, 끄면 Store와 모든 ExternalSecret이 렌더되지 않는다(ci 렌더 비교).
- U40이 `실제 검증 완료`이거나, 사용자가 승인한 한계로 기록돼 있다.
- 가정이 틀렸으면 `restore.md`의 클러스터 유실 + Infisical 장애 절차가 실제로 한 순서와 같다.
- svclb 파드가 같은 객체로 새 IP를 받아도 `AdGuardTailnetQueriesMissing`이 울리지 않고, tailnet 이탈 경우는 여전히 울린다(규칙 시험).

## 검증

VM에서 Infisical 접근을 막은 상태로 시나리오 13의 확인(설계 G 13행, T13 할 일 2)을 다시 한다. 결과는 T13 결과표에 PR로 남긴다(명세 AC-X1). 공개하면 안 되는 증거는 저장소 밖에 두고 위치만 적는다.

할 일 4는 `ci`의 vmalert 규칙 시험으로 보고, 다음 NUC 재부팅 때 그 경보가 나지 않았는지 지표(`ALERTS`)로 본다.

## 되돌리는 방법

T13 "되돌리는 방법"의 VM 항목과 같다: VM을 폐기하고, VM 전용 R2 버킷과 tailnet의 `vm-*` 기기를 지우고, `eso-homelab-dev` client secret을 폐기한다. 할 일 2는 여기에 더해 VM operator OAuth client를 Revoke하고(콘솔에 삭제가 없다), 시험 터널과 `homelab-dev` 외부 자격 키를 지우고, **암호화 내보내기 파일과 그 암호문구를 지운다**(순서는 `docs/runbooks-public/vm.md` 6절 머리). 2026-10-29~30에 모두 했다(approvals).

할 일 4는 규칙을 바꾼 PR을 되돌린다.
