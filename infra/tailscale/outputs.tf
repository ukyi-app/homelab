output "operator_oauth_client_id" {
  value     = tailscale_oauth_client.k8s_operator.id
  sensitive = true
}
output "operator_oauth_client_secret" {
  value     = tailscale_oauth_client.k8s_operator.key
  sensitive = true
}
