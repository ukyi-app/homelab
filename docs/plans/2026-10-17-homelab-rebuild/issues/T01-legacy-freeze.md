# T01 옛 저장소 동결·보존

- 단계: P0 정리·준비
- 상태: 진행 중 (Actions 비활성화 완료, 2026-10-17)
- 명세: [../spec.md](../spec.md)
- Blocked by: 없음
- 연결 AC: AC-P1, AC-X2
- 수행: 사람 (GitHub 쓰기 승인·실행). 에이전트는 명령 준비와 확인

## 목표

옛 코드를 참고용으로 남기고, 옛 자동화가 새 작업을 건드리지 못하게 한다.

## 할 일

1. [x] 저장소 Actions 비활성화 (2026-10-17). 되살리기: `enabled=true`, `allowed_actions=all`.
2. [ ] annotated `legacy` 태그를 로컬 사본 없이 `gh api`로 만든다.
   - 먼저 원격 main이 그대로인지 확인한다. `git ls-remote https://github.com/ukyi-app/homelab refs/heads/main`이 `2d2054aa294b3862de1b1af6eada88fb15e656e6`이어야 한다. 다르면 멈추고 사람에게 알린다.
   - 태그 객체를 만든다. `gh api repos/ukyi-app/homelab/git/tags -f tag=legacy -f message="<누가·언제·왜>" -f object=2d2054aa294b3862de1b1af6eada88fb15e656e6 -f type=commit`. 응답의 `sha`가 태그 객체 SHA다.
   - 그 SHA로 태그 ref를 만든다. `gh api repos/ukyi-app/homelab/git/refs -f ref=refs/tags/legacy -f sha=<태그 객체 SHA>`.
   - 옛 사본(`~/workspace/homelab`)에서는 fetch하지 않는다. 전역 git 설정이 `fetch.prune=true`, `fetch.prunetags=true`라서 fetch하면 원격에 없는 로컬 태그와 원격 추적 ref가 지워진다. 옛 사본은 그대로 둔다(T02 제약).
3. [ ] 열린 PR 10개를 닫는다. 필수다. T06 전에 끝내고, 가능하면 지금 한다.
   - 이유: renovate PR 5개(#749, #740, #739, #721, #720)는 필수 검사 `gate`가 이미 SUCCESS인 병합 가능 상태다. 지금 자동 병합이 일어나지 않는 진짜 이유는 auto-merge가 모두 꺼져 있고, 병합 자동화가 Actions 위에서 돌았기 때문이다. 누가 병합하면 main이 바뀌고 옛 Argo CD가 바로 적용한다.
   - 닫기 전에 `gh pr list -R ukyi-app/homelab --state open`의 목록이 아래 10개와 같은지 확인한다.
   - 명령: `for n in 749 740 739 737 730 729 726 725 721 720; do gh pr close $n -R ukyi-app/homelab --comment "Frozen for rebuild (tag legacy)"; done`.
   - PR을 닫아도 브랜치는 남는다.
4. [ ] 실행한 외부 변경(태그 생성, PR 닫기)을 [../approvals.md](../approvals.md)에 기록한다 (AC-X2).
5. [ ] 태그 SHA와 실행 기록을 이 티켓의 "실행 기록"에 적고 `rebuild`에 커밋한다(spec §12). `rebuild`는 T02가 만든다. push는 사람 승인 뒤에 한다.

## 제약

- 저장소는 지우지도, 이름을 바꾸지도 않는다 (C-01).
- 원격 브랜치(`aiops/*` 12개, `renovate/*` 5개, `create-app/*` 1개)는 그대로 둔다. `fix/*`는 원격에 없고 옛 사본의 로컬 전용 브랜치다. 그 보존은 T06 선행 확인에서 다룬다.
- 열린 PR에 auto-merge를 켜거나 병합하지 않는다.
- 옛 github Terraform root는 destroy하지 않는다. `homelab`과 `homelab-app-template` 저장소가 지워진다(spec §4.5).

## 되돌리기

- 태그: `gh api -X DELETE repos/ukyi-app/homelab/git/refs/tags/legacy`.
- PR 닫기: `gh pr reopen <n> -R ukyi-app/homelab`.
- 되돌린 것도 [../approvals.md](../approvals.md)에 기록한다.

## 완료 조건

- annotated `legacy` 태그가 가리키는 커밋이 태그를 만든 시점의 원격 main 커밋과 같다. 태그 객체 SHA와 그 커밋 SHA가 이 티켓에 기록돼 `rebuild`에 커밋돼 있다.
- 옛 저장소의 열린 PR이 0개다 (T06 전).
- Actions는 T07에서 main을 바꿀 때까지 `enabled:false`다.
- 태그 생성과 PR 닫기가 [../approvals.md](../approvals.md)에 있다.

## 검증

- `git ls-remote https://github.com/ukyi-app/homelab "refs/tags/legacy^{}"`의 커밋과 `git ls-remote https://github.com/ukyi-app/homelab refs/heads/main`의 커밋이 같다. annotated 태그라서 `^{}` 없이 조회하면 태그 객체 SHA가 나온다.
- `gh api repos/ukyi-app/homelab/actions/permissions`가 `enabled:false`를 돌려준다.
- `gh pr list -R ukyi-app/homelab --state open`이 비어 있다.

## 실행 기록

- `legacy` 태그 객체 SHA: 아직 없음.
- 태그가 가리키는 커밋: 아직 없음 (기대값 `2d2054aa294b3862de1b1af6eada88fb15e656e6`).
- 열린 PR 닫기: 아직 없음.
