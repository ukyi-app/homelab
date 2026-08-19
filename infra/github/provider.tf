provider "github" {
  owner = var.github_owner
  token = var.github_token
}

# branch protection·ruleset·secrets가 `github_repository` **리소스**를 참조하면, CI의 읽기 전용
# plan에 그 리소스가 의존성으로 딸려 들어온다. 그런데 GitHub은 repo의 merge 설정 필드
# (allow_squash_merge 등)를 **Administration:write 토큰에게만** 돌려주고, provider는 부재를
# `false`로 읽어 **영구 허위 드리프트**를 만든다(2026-08-19 실측: 읽기 전용 PAT로 그 필드가 전부 null).
# data source로 바꾸면 같은 node_id를 얻으면서 **변경 제안을 만들지 않는다**(data는 diff를 내지 않는다).
data "github_repository" "homelab" {
  name = var.repo_name
}
