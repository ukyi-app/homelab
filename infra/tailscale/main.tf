# tailnet에는 이미 정책이 있다. 빈 state에서 Create하면 provider가 ts-default ETag를 보내 기존 정책에 412로 실패한다
# (v0.29.2 resource_acl.go). 먼저 import해 state로 가져오면 첫 plan이 "1 import, 1 change"로 바뀔 내용을 diff로 보여 준다.
# overwrite_existing_content로 덮는 방법은 diff 없이 덮어써 쓰지 않는다.
import {
  to = tailscale_acl.homelab
  id = "acl"
}

resource "tailscale_acl" "homelab" {
  acl = file("${path.module}/policy.hujson")
}
