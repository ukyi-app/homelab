# T02 새 작업 사본 준비

- 단계: P0 정리·준비
- 상태: 준비됨 (로컬 단계 1~7과 push 단계 8~11. push는 사람 승인 뒤)
- 명세: [../spec.md](../spec.md)
- Blocked by: 없음
- 선행 결정: D-03 (확정: 히스토리 유지, `legacy` 태그 + 교체 커밋), D-23 (확정 2026-10-17: public 유지, 계획 문서 공개 수용)
- 연결 AC: AC-X1, AC-X2
- 수행: 에이전트 (로컬 git) + 사람 (브랜치 push 승인)

## 목표

새 홈랩 작업을 git으로 관리해 계획과 새 문서가 유실되지 않게 한다. 지금 이 폴더의 모든 문서는 이 디스크에만 있다. 옛 클러스터가 살아 있는 동안 main은 건드리지 않는다.

**push하면 계획 문서가 공개된다.** `homelab`은 public이고, 사용자가 이 공개를 받아들였다(D-23). 공개된 내용은 되돌릴 수 없으므로 push 직전에 시크릿·운영 민감 정보가 없는지 다시 본다. Secret scanning push protection이 켜져 있어 시크릿 모양의 문자열이 있으면 push가 막힌다.

## 할 일

옛 파일을 작업 트리에 풀지 않는 순서다. checkout을 쓰지 않으므로 옛 `AGENTS.md`, `CLAUDE.md`, `.claude/settings.json`(옛 PreToolUse 훅)이 `/home/ukyi/homelab`에 풀리지 않는다.

1. 백업: `cp -a /home/ukyi/homelab/docs/plans <NUC 안 백업 경로>`. 백업 경로는 `/home/ukyi/homelab` 밖에 둔다. git 작업 중 실수로 덮어써도 되살리기 위해서다.
2. 작업 사본을 만든다.
   - `git -C /home/ukyi/homelab init -b rebuild`
   - `git -C /home/ukyi/homelab remote add origin https://github.com/ukyi-app/homelab.git`
   - `git -C /home/ukyi/homelab fetch --no-tags origin main`
3. 옛 main을 확인한다. `test "$(git -C /home/ukyi/homelab rev-parse origin/main)" = 2d2054aa294b3862de1b1af6eada88fb15e656e6`. 다르면 멈추고 사람에게 알린다.
4. `rebuild`를 옛 main에 붙인다. `git -C /home/ukyi/homelab update-ref refs/heads/rebuild origin/main`. 인덱스가 비어 있어 옛 파일 929개가 삭제로 잡힌다.
5. 삭제 커밋: `git -C /home/ukyi/homelab commit -m "chore: remove legacy tree (kept at tag legacy)"`. 옛 저장소의 문서(README, AGENTS, docs/ 등)도 새 트리에 남기지 않고 `legacy` 태그로 참조한다.
6. 문서 커밋: `git -C /home/ukyi/homelab add -- docs/plans` 뒤 `git -C /home/ukyi/homelab commit -m "docs: add homelab rebuild plan"`. 옛 프롬프트 원본(`docs/cicd-simplification-prompt.md`, `docs/ai-bot-prompts/`, `docs/archive/`)은 2026-10-17에 지웠고 맥 `~/Documents` 사본만 남았다.
7. 아래 "검증"을 `rebuild` 기준으로 확인한다. 여기까지가 로컬 단계다. T04는 이 단계가 끝나면 시작할 수 있다(spec §8.2).

로컬 단계 뒤에 생기는 `docs/plans` 변경(T01 실행 기록, T04의 design.md 등)은 각 담당이 `rebuild`에 따로 커밋한다. 쓰는 중인 미추적 파일은 push 대상이 아니다.

8. push 전 확인: 사람이 push를 승인했고, `git grep -nIE '(ghp_|github_pat_|xox[bp]-|AKIA|-----BEGIN)' rebuild -- docs/plans` 같은 검색에 시크릿 모양의 문자열이 없다. 승인이 없으면 여기서 멈춘다.
9. 명시적 refspec으로 push한다. `git -C /home/ukyi/homelab push -u origin refs/heads/rebuild:refs/heads/rebuild`. push protection이 막으면 우회하지 않고 사람에게 알린다.
10. 아래 "검증"을 `origin/rebuild` 기준으로 다시 확인한다.
11. [../approvals.md](../approvals.md)에 push 줄을 더해 커밋한다 (AC-X2). 이 커밋은 다음 승인된 push(예: T01 실행 기록)와 함께 올라간다.

## 제약

- main에는 push하지 않는다. 관리자는 브랜치 보호를 우회할 수 있으므로(`enforce_admins=false`) 인자 없는 `git push`를 쓰지 않고 명시적 refspec만 쓴다. main 교체는 T07에서 PR로 한다.
- `git checkout`, `git switch`, `git reset --hard`, `git clean`은 쓰지 않는다. 옛 파일을 작업 트리에 풀거나 추적되지 않은 파일을 지울 수 있다. `docs/plans/`는 처음에 추적되지 않은 상태다.
- 옛 사본 `~/workspace/homelab`은 그대로 둔다. fetch, prune, 브랜치 변경도 하지 않는다. 이유는 셋이다.
  - 워크트리 10개가 연결돼 있다(메인 포함). 그중 3개는 `/tmp` 경로가 사라져 prunable이다.
  - 커밋 안 된 변경이 있다.
  - 옛 호스트 유닛이 그 경로의 스크립트를 실행한다(spec §4.5).
- 문서 내용은 수정하지 않는다. git 설정과 커밋만 한다. 예외는 [../approvals.md](../approvals.md)의 승인 줄이다.

## 되돌리기

- push 전: 1의 백업 사본으로 `docs/plans/`를 되살린다.
- push 뒤: `git -C /home/ukyi/homelab push origin --delete rebuild`. 브랜치는 지워지지만 공개된 내용은 되돌릴 수 없다. 되돌린 것도 [../approvals.md](../approvals.md)에 기록한다.

## 완료 조건

`/home/ukyi/homelab`이 git 저장소이고, 원격 `rebuild` 브랜치에 [../approvals.md](../approvals.md)를 포함한 `docs/plans/` 전체가 들어 있으며 옛 파일은 없다. `rebuild` push가 approvals.md에 기록돼 커밋돼 있다.

## 검증

명령은 `git -C /home/ukyi/homelab`으로 실행한다. push 전(할 일 7)에는 아래의 `origin/rebuild`를 `rebuild`로 바꿔 읽고, `refs/heads/rebuild`의 `git ls-remote`는 건너뛴다.

- `git status --porcelain --untracked-files=no`가 비어 있다. 추적 중인 파일에 커밋 안 된 변경이 없다는 뜻이다. T04가 쓰는 중인 미추적 파일은 검사 대상이 아니다.
- `git ls-remote origin refs/heads/rebuild`가 커밋을 돌려준다.
- `git ls-remote origin refs/heads/main`이 작업 전과 같다(`2d2054aa294b3862de1b1af6eada88fb15e656e6`).
- `git ls-tree -r --name-only origin/rebuild`에 `docs/plans/` 아래 파일만 있다.
- `git merge-base --is-ancestor 2d2054aa294b3862de1b1af6eada88fb15e656e6 origin/rebuild`가 성공한다. `rebuild`가 옛 main에서 이어졌다는 확인이다. 히스토리가 무관하면 T07에서 main으로 PR을 만들 수 없다.
- `c=$(git rev-list --reverse --ancestry-path 2d2054aa294b3862de1b1af6eada88fb15e656e6..origin/rebuild | head -n 1); test -n "$c" && test -z "$(git ls-tree "$c")"`가 성공한다. 옛 main 바로 위 커밋(삭제 커밋)이 빈 트리라는 확인이다. 그 위에 커밋이 더 쌓여도 그대로 쓸 수 있다.
