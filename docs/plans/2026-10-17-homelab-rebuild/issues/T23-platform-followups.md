# T23 플랫폼 후속(T13에서 넘김)

- 단계: P2 후속
- 상태: 진행 중 (2026-10-29 착수. 할 일 4 규칙 수정, 다음 재부팅 때 `ALERTS` 확인 남음. 할 일 1 작업 중. 할 일 2·3은 VM 자격 재발급(사람) 뒤)
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
2. U40(설계 부록 1)을 VM에서 실제로 해 본다. T13 시나리오 13과 같은 VM 격리 조건 여섯으로 하되, VM이 Infisical에 닿지 못하게 막고 빈 클러스터를 복구한다.
   - 확인할 가정(설계 부록 1 U40 행): 할 일 1의 스위치를 끄면 root wave가 손으로 만든 Secret만으로 끝까지 진행하고, 값을 되돌렸을 때 ESO가 같은 이름의 기존 Secret을 넘겨받는다.
   - 넘겨받지 않거나 root가 진행하지 않으면 설계 부록 1 U40 행의 대안(되돌리는 PR 직전 손 Secret 삭제, 필요한 Application만 손으로 sync)을 `restore.md`에 절차로 둔다. 설계 C.6.4 행과 맞춘다.
   - 손으로 만드는 Secret의 값은 저장소 밖 암호화 내보내기에서 온다. 화면·파일·인자에 남기지 않는다.
3. 결과를 T13 결과표의 13 U40 줄, 설계 부록 1 U40 행, `restore.md` 3절 U40 문단에 기록한다.
4. `AdGuardTailnetQueriesMissing`(`platform/observability/stack/vmalert/rules/adguard.yaml`)의 재부팅 오경보를 없앤다(T13 시나리오 17, 2026-10-29). 재부팅으로 svclb 파드가 새 IP를 받아도 파드 객체가 그대로면 `kube_pod_start_time`이 옛 값이라, 새 IP 출처 질의가 질의 로그 파일에 쓰일 때까지(이번에 약 2분) 울린다.
   - 기준 시각을 파드 시작 대신 svclb 컨테이너 시작 시각(예: `kube_pod_container_state_started`)으로 바꾸거나 짧은 `for`를 둔다. `for`는 실제 이탈 감지도 그만큼 늦춘다.
   - 규칙 시험(`platform/observability/stack/vmalert/tests/adguard.test.yaml`)에 "같은 파드, 새 IP" 경우를 더하고, 기존 이탈 경우가 계속 울리는지 본다.
   - 결과(2026-10-29): 기준 시각 후보에 svclb 컨테이너 시작 시각(`kube_pod_container_state_started`)을 더했다. 파드 시작 시각은 컨테이너 지표가 없을 때의 기준으로 남겼고 `for`는 두지 않았다. 규칙 시험 "같은 파드, 새 IP"는 바꾸기 전 규칙에서 5분 시점 오경보로 실패하고 바꾼 뒤 통과하며, 같은 시험의 이탈(15분)은 여전히 울린다. 운영 지표로 다시 평가: S17 오경보 시각(2026-10-28 22:16:30Z~22:18:00Z)에 옛 식은 741992초로 발화, 새 식은 빈 결과. 남은 것: 다음 NUC 재부팅 때 `ALERTS`로 확인.

## 필요한 자격

할 일 4는 자격이 필요 없다. 할 일 1~3은 T13 시나리오 13과 같다. T13이 끝나며 VM 자원과 시험 자격을 지웠으므로(T13 결과 절 "정리", 2026-10-28) 다시 만든다(사람).

- `eso-homelab-dev` Universal Auth client secret(VM 전용, 시험 뒤 폐기).
- VM 전용 R2 버킷과 그 버킷 전용 토큰, VM operator OAuth client, 시험 터널 토큰, 시험 healthchecks 체크, 시험 Telegram 봇 토큰(모두 `homelab-dev`).
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

T13 "되돌리는 방법"의 VM 항목과 같다: VM을 폐기하고, VM 전용 R2 버킷과 tailnet의 `vm-*` 기기를 지우고, `eso-homelab-dev` client secret을 폐기한다.

할 일 4는 규칙을 바꾼 PR을 되돌린다.
