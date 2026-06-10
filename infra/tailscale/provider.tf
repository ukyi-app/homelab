provider "tailscale" {
  oauth_client_id     = var.ts_bootstrap_oauth_id
  oauth_client_secret = var.ts_bootstrap_oauth_secret
  scopes              = ["all"]
}
