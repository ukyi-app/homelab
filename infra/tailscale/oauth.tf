resource "tailscale_oauth_client" "k8s_operator" {
  # 괄호 등 특수문자는 Tailscale 키 description에서 400 invalid characters — 영숫자/공백/하이픈만.
  description = "homelab-prod k8s operator"
  scopes      = ["devices:core", "auth_keys"]
  tags        = ["tag:k8s-operator"]
}
