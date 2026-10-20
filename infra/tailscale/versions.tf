terraform {
  required_version = "= 1.16.6"

  required_providers {
    tailscale = {
      source  = "tailscale/tailscale"
      version = "= 0.29.2"
    }
  }
}
