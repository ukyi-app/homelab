# T23 플랫폼 후속(T13에서 넘김)

- 단계: P2 후속
- 상태: 대기
- 명세: [../spec.md](../spec.md)
- Blocked by: T13
- 선행 결정: D-12 (확정(사용자 2026-10-18, T05): 빈 NUC 검증은 VM, 설계 E8 VM 격리 조건 여섯, VM 호스트는 tailnet 밖)
- 연결 AC: AC-P5, AC-P10
- 수행: 에이전트 + 사람

## 목표

T13이 끝내지 않고 넘긴 플랫폼 후속을 처리한다(T13 할 일 3, 사용자 결정 2026-10-29). 지금은 U40 2회차 하나다. T13 결과표 [../platform/verification.md](../platform/verification.md) "한계와 후속"의 13 U40 줄이 출처다.

## 할 일

1. U40(설계 부록 1): 클러스터 유실과 Infisical 장애가 겹친 복구를 VM에서 실제로 해 본다. T13 시나리오 13과 같은 VM 격리 조건 여섯(T13 할 일 2, 설계 E8)으로 하되, VM이 Infisical에 닿지 못하게 막고 빈 클러스터를 복구한다.
   - 확인할 가정(설계 부록 1 U40 행): root 값으로 ClusterSecretStore와 ExternalSecret을 렌더하지 않으면(지금 값 경로는 `platform/root/values.yaml`의 `components.externalSecrets.enabled`. 설계 행에는 `externalSecrets.enabled`로 적혀 있다) root wave가 손으로 만든 Secret만으로 끝까지 진행하고, 값을 되돌렸을 때 ESO가 같은 이름의 기존 Secret을 넘겨받는다.
   - 넘겨받지 않거나 root가 진행하지 않으면 설계 부록 1 U40 행의 대안(되돌리는 PR 직전 손 Secret 삭제, 필요한 Application만 손으로 sync)을 `docs/runbooks-public/restore.md`에 절차로 둔다. 설계 C.6.4 "클러스터 유실 + Infisical 장애" 행과 맞춘다.
   - 손으로 만드는 Secret의 값은 저장소 밖 암호화 내보내기에서 온다. 화면·파일·인자에 남기지 않는다.
2. 결과를 T13 결과표의 13 U40 줄과 설계 부록 1 U40 행에 기록한다.

## 필요한 자격

T13 시나리오 13과 같다. T13이 끝나며 VM 자원과 시험 자격을 지웠으므로(T13 결과 절 "정리", 2026-10-28) 다시 만든다(사람).

- `eso-homelab-dev` Universal Auth client secret(VM 전용, 시험 뒤 폐기).
- VM 전용 R2 버킷과 그 버킷 전용 토큰, VM operator OAuth client, 시험 터널 토큰, 시험 healthchecks 체크, 시험 Telegram 봇 토큰(모두 `homelab-dev`).
- 복구 자산의 R2 읽기 전용 토큰(운영 백업 버킷만, 시험 동안만 VM에 손으로).
- VM 호스트 준비는 T13과 같다(`docs/runbooks-public/vm.md`, 운영 NUC inotify 사전 확인 포함).

## 완료 조건

- U40이 `실제 검증 완료`이거나, 사용자가 승인한 한계로 기록돼 있다.
- 가정이 틀렸으면 `restore.md`의 클러스터 유실 + Infisical 장애 절차가 실제로 한 순서와 같다.

## 검증

VM에서 Infisical 접근을 막은 상태로 시나리오 13의 확인(설계 G 13행, T13 할 일 2)을 다시 한다. 결과는 T13 결과표에 PR로 남긴다(명세 AC-X1). 공개하면 안 되는 증거는 저장소 밖에 두고 위치만 적는다.

## 되돌리는 방법

T13 "되돌리는 방법"의 VM 항목과 같다: VM을 폐기하고, VM 전용 R2 버킷과 tailnet의 `vm-*` 기기를 지우고, `eso-homelab-dev` client secret을 폐기한다.
