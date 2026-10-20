terraform {
  required_version = "= 1.16.6"

  required_providers {
    github = {
      source = "integrations/github"
      # 정확 핀. 6.13.0의 legacy 클라이언트는 갱신 apply가 한 번 실패하면 그 ruleset의 드리프트가 영구히 안 보인다
      # (#3519, 수정 #3637 미출시). tools/tf-github.sh가 apply 실패 뒤 state rm + import로 다시 편입한다(설계 C.3.9).
      # #3637이 든 릴리스가 나오면 올리고 그 우회를 지운다. .terraform.lock.hcl 변경은 사람이 확인한다.
      version = "= 6.13.0"
    }
  }
}
