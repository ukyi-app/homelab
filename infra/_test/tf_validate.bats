#!/usr/bin/env bats

@test "make tf-validate exits 0 across all roots" {
  run make tf-validate
  [ "$status" -eq 0 ]
  [[ "$output" == *"cloudflare: validated"* ]]
  [[ "$output" == *"tailscale: validated"* ]]
  [[ "$output" == *"github: validated"* ]]
}
