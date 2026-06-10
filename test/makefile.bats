#!/usr/bin/env bats

@test "make verify runs the foundation checks and passes" {
  run make verify
  [ "$status" -eq 0 ]
}

@test "unimplemented targets still exit non-zero (cannot fake success)" {
  # bootstrap (M2) and up/host-up (M1) are now implemented; only down remains a stub.
  run make down
  [ "$status" -ne 0 ]
}

@test "bootstrap delegates to scripts/bootstrap.sh (dry-run)" {
  run make -n bootstrap
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'scripts/bootstrap.sh'
}

@test "make help lists every declared target" {
  run make help
  [ "$status" -eq 0 ]
  for t in bootstrap up down verify host-up; do
    echo "$output" | grep -q "$t"
  done
}

@test "up delegates to the host-substrate orchestrator (dry-run shows host-up.sh)" {
  run make -n up
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'infra/k3s-bootstrap/host-up.sh'
}

@test "host-up delegates to the host-substrate orchestrator (dry-run shows host-up.sh)" {
  run make -n host-up
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'infra/k3s-bootstrap/host-up.sh'
}
