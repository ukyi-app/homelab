resource "tailscale_oauth_client" "k8s_operator" {
  description = "Tailscale Kubernetes operator (homelab-prod)"
  scopes      = ["devices:core", "auth_keys"]
  tags        = ["tag:k8s-operator"]
}
