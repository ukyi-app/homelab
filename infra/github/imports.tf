# E1·E2와 결정 5 하드닝이 gh api로 만든 ruleset을 편입한다(설계 C.3.9 도입 순서). 첫 apply가 끝나면 이 파일을 지운다.
# ruleset ci는 제자리에서 main-checks로 이름이 바뀐다(name은 ForceNew가 아니라 보호 공백이 없다).
import {
  to = github_repository_ruleset.main_interim
  id = "homelab:25372131"
}

import {
  to = github_repository_ruleset.main_checks
  id = "homelab:25397171"
}

import {
  for_each = {
    "files"                = 25327498
    "homelab-app-template" = 25327516
    "homelab-bot"          = 25332733
  }
  to = github_repository_ruleset.app_main[each.key]
  id = "${each.key}:${each.value}"
}
