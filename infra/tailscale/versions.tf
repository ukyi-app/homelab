terraform {
  required_version = ">= 1.9.0"
  required_providers {
    tailscale = {
      source  = "tailscale/tailscale"
      version = "~> 0.18"
    }
  }
}
