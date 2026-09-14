# pr-sweeper가 전진시키는 브랜치 역시 writer만 만들고 변경할 수 있다.
# PR author 검사만으로는 writer가 만든 PR head를 다른 contents:write 주체가 덮는 공격을 못 막는다.
resource "github_repository_ruleset" "mutation_writer_only" {
  name        = "mutation-branches-writer-only"
  repository  = data.github_repository.homelab.name
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["refs/heads/bump/**", "refs/heads/create-database/**", "refs/heads/create-cache/**", "refs/heads/create-app/**", "refs/heads/update-secrets/**"]
      exclude = []
    }
  }

  rules {
    creation = true
    update   = true
  }

  bypass_actors {
    actor_id    = 4043080
    actor_type  = "Integration"
    bypass_mode = "always"
  }
}
