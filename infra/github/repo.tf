resource "github_repository" "homelab" {
  name                   = var.repo_name
  visibility             = "private"
  has_issues             = true
  allow_merge_commit     = false
  allow_squash_merge     = true
  allow_rebase_merge     = false
  delete_branch_on_merge = true
  # Repo already exists — import it once: see runbook 02.
}

resource "github_branch_protection" "main" {
  repository_id = github_repository.homelab.node_id
  pattern       = "main"

  required_status_checks {
    strict   = true
    contexts = ["gate"] # ONLY `gate` runs on pull_request (ci.yaml); `build` runs on push-to-main (post-merge), so it must NOT be a required PR check or every PR hangs permanently pending
  }
  required_pull_request_reviews {
    required_approving_review_count = 0
    require_last_push_approval      = false
  }
  enforce_admins      = false
  allows_force_pushes = false
  allows_deletions    = false
}
