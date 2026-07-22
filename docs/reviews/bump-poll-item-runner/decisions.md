# Triage 결정 — bump-poll-item-runner (F-1)

### design r1

DG-1 accept (high) — 설계가 enforced call-site 게이트 `tests/gates/test_bump-poll-callsite.bats`(22 witness·84KB) migration을 누락. 워크플로 한 줄 호출은 그 게이트를 필연 실패시킴. → design change surface에 이 게이트 이관 추가: 22 witness(순서·레인 verbatim/승인게이트·원격 변이 소유·real-git 격리·staged-잔여·effective-ownership)를 (a) thin 워크플로→러너 경계와 (b) 러너 실행 테스트로 분할, 계약·변이 witness 무약화·무삭제.
DG-2 accept (medium) — 러너 테스트 매트릭스가 H-2의 실제 상태(git add 후 staged 잔여)를 안 만듦(bump-tag 실패는 add 전, ensure-bump-pr stub 실패는 commit 후 clean index). → post-stage/post-write 실패 시나리오 추가(staging 후 commit 실패·write 후 bump-tag 실패): 다음 항목 commit이 자기 경로만·전 worktree remove·run 계속·끝 비-0 + cleanup/격리 teeth witness. (기존 게이트 @test 16 witness를 러너 레벨로 이관+강화와 동일.)
