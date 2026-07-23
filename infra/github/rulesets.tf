# F-0 — bump-poll/** ref 네임스페이스를 writer App(ukyi-homelab-writer) 전용으로 예약한다.
#
# 왜: tools/ensure-bump-pr.ts의 force-push 소유권 검증은 **안전 인터록이지 인증이 아니다** — 워크플로의
#   git commit은 서명되지 않으므로 author/committer/메시지는 자유 텍스트이고, 적대적 contents:write 행위자는
#   신원을 위조할 수 있다. 강제 가능한 유일한 서버측 불변식이 이 ruleset이다.
# 닫는 것: 비-writer의 bump-poll/* 브랜치 생성(creation)과 기존 브랜치로의 push(update)를 차단(R-19 서버 강제 +
#   rogue ref 심기 차단). 유일한 합법 writer는 writer App뿐 — bump-poll.yaml이 이 토큰으로 push하고
#   pr-sweeper.yaml은 bump-poll/를 명시적으로 제외한다(R-25). 그래서 bypass actor 하나로 100% 커버된다.
# 못 닫는 것: R-46(이미 존재하는 writer-생성 head에 다른 base PR을 여는 동시-PR 생성)은 이 ruleset으로도 못 막는
#   **수용된 잔여**다 — git ref lease는 동시 PR 생성을 원리적으로 막을 수 없다. 도구의 ③-b2 재조회가 창을 좁힐 뿐.
# deletion: 이번 increment에서 제외 — 삭제 제약은 delete_branch_on_merge를 깨 고아 브랜치를 남길 수 있어
#   (GitHub 문서 명시) 멱등 writer-App 정리 경로 설계 후 후속 increment로 연기한다.
# apply: 이 루트는 신뢰 앵커 — owner-local apply 전용(CI 무인 apply 금지). 라이브 강제는 실측으로만 확증된다.
# github_branch_protection.main(repo.tf)과 공존한다 — 서로 다른 ref(main vs bump-poll/**), 무간섭.

# writer App ID(4043080 = ukyi-homelab-writer)를 **직접 핀**한다(slug data source 대신 리터럴).
# 왜(2026-07-23 라이브 실측): GitHub fine-grained PAT는 `GET /apps/{slug}`(공개 엔드포인트인데도)를 404로
#   막아 `data.github_app.writer`가 죽는다 → apply가 classic 토큰을 강제하고, 만약 tf-reconcile의
#   TF_GITHUB_TOKEN이 fine-grained면 github plan이 매 주기 깨진다. App ID는 slug보다 안정적이다 —
#   리네임에도 불변(삭제·재생성 시에만 변하고 그건 전면 재설정 상황). slug(ukyi-homelab-writer)는 실행기
#   신원 3곳과 같은 App이다(run-bump-plan.ts WRITER_NAME · ensure-bump-pr DEFAULT_WRITER). 이 리터럴
#   변경은 canonical-freeze 게이트(test_bump_poll_ruleset.bats)가 잡는다.

resource "github_repository_ruleset" "bump_poll_writer_only" {
  name        = "bump-poll-writer-only"
  repository  = github_repository.homelab.name
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["refs/heads/bump-poll/**"]
      exclude = []
    }
  }

  rules {
    creation = true # bypass 외에는 bump-poll/* ref 생성 불가 (rogue ref/PR 차단)
    update   = true # bypass 외에는 push 불가 (R-19 서버 강제 — 남의 커밋 덮어쓰기 차단)
    # deletion은 이번 increment에서 설정하지 않는다(연기 — 위 헤더 주석 참고).
  }

  # bypass = writer App 하나(ukyi-homelab-writer, App ID 4043080 — 위 주석: slug 해석 대신 ID 직접 핀).
  bypass_actors {
    actor_id    = 4043080
    actor_type  = "Integration"
    bypass_mode = "always"
  }
}
