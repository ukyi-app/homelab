# T22 기존 앱 저장소 재연결·옛 저장소 정리

- 단계: P5 후속 (P4와 병행)
- 상태: 대기
- 명세: [../spec.md](../spec.md)
- Blocked by: T13, T16 (봇 첫 배포 증거)
- 선행 결정: D-13 (옛 aiops 저장소·App 처리), D-18 (의존성 업데이트 방식), D-21 (`homelab-app-template` 재사용)
- 연결 AC: AC-P14
- 수행: 에이전트 + 사람 (대상 선택, 병합, 저장소 보관·App 정리)

## 목표

사용자가 고른 기존 앱을 새 CI/CD 흐름으로 다시 배포한다. 옛 AIOps 저장소와 App, 고르지 않은 저장소를 정리한다.

## 배경

- `files`, `page`, `trip-mate-api`, `aiops-autodeploy-canary`는 `ukyi-app/homelab/.github/workflows/reusable-app-build.yaml@main`을 호출한다.
- `homelab-app-template`은 두 경로로 의존한다. 자기 CI(`template-ci.yaml`)가 매주 homelab main의 `tools/app-config-schema.json`을 받아 오고, scaffold가 새 앱 저장소에 reusable@main 호출을 심는다.
- `aiops`에는 의존이 없다.
- main을 교체하면(T07) reusable 호출과 스키마 가져오기가 모두 깨진다. `homelab-app-template`은 T10(D-21), `aiops-autodeploy-canary`는 D-13에서 다룬다.
- `page`와 `trip-mate-api`는 옛 클러스터에서 이미 철거돼 있다. 그래서 재연결은 사실상 첫 배포다.
- 옛 homelab Actions가 꺼진 뒤(C-06) 다른 저장소의 Renovate도 멈췄다. 다른 저장소에 열린 renovate PR은 25개다 (D-18).

## 순서

봇이 새 플랫폼의 첫 실제 앱이므로(D-01, 확정) 실제 배포는 봇의 첫 배포 뒤, 곧 T16의 배포 증거가 나온 뒤에 한다. 대상 선택과 워크플로 수정 준비는 T13 뒤 바로 해도 된다.

## 할 일

1. 재연결할 앱을 사용자가 고른다. files 데이터는 폐기됐다 (C-03).
2. 고른 앱마다 옛 워크플로 호출을 새 공통 워크플로로 바꾼다.
3. 고르지 않은 앱은 옛 호출을 지우거나 저장소를 보관(archive) 처리할지 정한다.
4. D-13 결정에 따라 옛 `ukyi-app/aiops`, `aiops-autodeploy-canary` 저장소 보관과 `ukyi-homelab-aiops` App 정리를 실행한다. T06에서 넘겨받은 일이다.
5. `mac-uptime-guard`(private, 옛 맥 미니용)를 유지할지 보관할지 정한다.

## 제약

- 한 앱에 옛 이미지 갱신 자동화(옛 공통 워크플로 호출)와 새 공통 워크플로를 동시에 두지 않는다. 근거는 [플랫폼 프롬프트](../platform/design-prompt.md) §5의 "앱별 이미지 변경의 단일 갱신 주체"다.
- 저장소 보관과 App 정리는 고르지 않은 앱 저장소를 포함해 매번 사람 승인으로 하고, [../approvals.md](../approvals.md)에 기록한다 (명세 §11).

## 완료 조건

- 고른 앱마다 시나리오 1(첫 배포)을 통과한다.
- 할 일 3~5의 저장소와 App마다 처리(보관, 삭제, 유지와 이유)가 실행됐고, approvals.md에 승인 기록이 있다.

## 검증

- 앱별 배포 결과와 실행 확인 기록.
- 대상 저장소의 `archived` 상태와 org App 설치 목록을 다시 조회해 approvals.md와 대조한다.
