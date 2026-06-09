#!/usr/bin/env bats
load test_helper

CI="$BOOTSTRAP_DIR/cloud-init.yaml"

@test "cloud-init exists and is valid YAML" {
  [ -f "$CI" ]
  run yq -e '.' "$CI"
  [ "$status" -eq 0 ]
}

@test "first line is the #cloud-config shebang" {
  run head -n1 "$CI"
  [ "$output" = "#cloud-config" ]
}

@test "zram is configured via systemd-zram-generator with zstd" {
  run yq -e '.write_files[] | select(.path == "/etc/systemd/zram-generator.conf") | .content' "$CI"
  [ "$status" -eq 0 ]
  [[ "$output" == *"zram0"* ]]
  [[ "$output" == *"zstd"* ]]
}

@test "journald SystemMaxUse is capped" {
  run yq -e '.write_files[] | select(.path == "/etc/systemd/journald.conf.d/cap.conf") | .content' "$CI"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SystemMaxUse="* ]]
}

@test "both storage dirs are created" {
  run yq -e '.runcmd | @json' "$CI"
  [[ "$output" == *"/var/lib/rancher/k3s-storage/internal"* ]]
  [[ "$output" == *"/var/lib/rancher/k3s-storage/bulk"* ]]
}

@test "zram-generator package is installed and sshd enabled" {
  run yq -e '.packages | @json' "$CI"
  [[ "$output" == *"systemd-zram-generator"* ]]
  [[ "$output" == *"openssh-server"* ]]
}
