# 0009 — AIOps의 운영 수정 초안은 전용 fork에서 Draft PR로 제출한다

- 상태: 수용(accepted, 설계 결정) — 2026-09-12 사용자 인터뷰 Q11
- 구현: 설계 중
- 관련: ADR-0008, `.github/workflows/ci.yaml`, `.github/workflows/iac.yaml`

## 맥락

AIOps는 진단에 필요한 모든 파일의 수정 초안을 만들 수 있다(ADR-0008).
여기에는 워크플로와 IaC도 포함된다. 현재 same-repo PR은 Draft여도 CI를 실행하고,
IaC plan은 PR 코드를 checkout한 뒤 운영 자격을 사용한다. 따라서 Draft 상태만으로는
초안 코드의 실행을 운영 자격과 분리할 수 없다.

## 결정

수정 초안은 **AIOps 전용 fork의 브랜치에서 homelab으로 Draft PR**을 제출한다.
same-repo 브랜치의 CI 승인 경계를 전면 개편하는 대안 대신 GitHub의 공개 fork PR 경계를
사용한다. 공개 fork의 PR에는 upstream 시크릿이 전달되지 않고 `GITHUB_TOKEN`은 읽기 전용으로
제한된다. [GitHub 공식 문서](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows)

PR 제출은 운영 적용 승인이 아니다. 자동 머지는 활성화하지 않는다.
새 fork와 게시 자격의 실제 구성은 후속 구현에서 검증한다.

## 대안과 결과

- **전용 fork**: 모든 파일의 수정 제안을 유지하면서 upstream 시크릿과 초안 실행을 분리한다.
  최초 fork·게시 자격 설정이 추가된다. fork도 공개이므로 원본 장애 증거나 민감값을 게시하지 않는다.
- **same-repo + CI 승인 경계 개편**: 별도 fork는 필요 없으나 기존 운영 시크릿 공급과 승인된
  revision의 실행 경계를 다시 설계해야 한다. PR 자신이 바꿀 수 있는 workflow 조건만으로는 부족하다.

현재 IaC workflow는 fork에서 시크릿이 없어 plan을 생략하는 경로와 회계 제외를 이미 갖고 있다.
실제 fork PR의 `gate` 실행, 최초 기여자 승인 정책, 시크릿 미제공은 배선 단계의 수용 검사다.
CI 자체를 바꾼 초안의 초록 결과는 변경된 CI를 통과했다는 뜻이므로 그 변경도 검토해야 한다.
