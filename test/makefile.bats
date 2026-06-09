#!/usr/bin/env bats

@test "make verify runs the foundation checks and passes" {
  run make verify
  [ "$status" -eq 0 ]
}

@test "unimplemented targets exit non-zero (cannot fake success)" {
  run make bootstrap
  [ "$status" -ne 0 ]
  run make up
  [ "$status" -ne 0 ]
  run make down
  [ "$status" -ne 0 ]
  run make host-up
  [ "$status" -ne 0 ]
}

@test "make help lists every declared target" {
  run make help
  [ "$status" -eq 0 ]
  for t in bootstrap up down verify host-up; do
    echo "$output" | grep -q "$t"
  done
}
