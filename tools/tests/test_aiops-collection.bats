#!/usr/bin/env bats
# 외부 관측 명령 대역으로 수집부터 공개 증거까지 확인한다.
bats_require_minimum_version 1.5.0
load helpers/aiops
setup() {
  aiops_setup; seed_incident
  REPO="$BATS_TEST_TMPDIR/repo"; mkdir -p "$REPO"
  printf 'fixture\n' > "$REPO/README.md"
  git -C "$REPO" init -q; git -C "$REPO" add .
  git -C "$REPO" -c user.name=Test -c user.email=test@example.invalid commit -qm fixture
  REVISION="$(git -C "$REPO" rev-parse HEAD)"
}

@test "live collection selects pod status and bounded logs without exporting secrets" {
  cat > "$BATS_TEST_TMPDIR/kubectl" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *' get pods '*) printf '%s\n' '{"items":[{"metadata":{"name":"vmalert","namespace":"monitoring"},"spec":{"containers":[{"name":"app","env":[{"name":"PASSWORD","value":"must-never-leak"}]}]},"status":{"phase":"Pending","containerStatuses":[{"name":"app","restartCount":3,"state":{"waiting":{"reason":"ImagePullBackOff"}}}]}}]}' ;;
  *' get events '*) printf '%s\n' '{"items":[]}' ;;
  *' logs '*) printf '%s\n' 'password=another-private-value' 'image fetch failed' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$BATS_TEST_TMPDIR/kubectl"
  jq -n --arg bin "$BATS_TEST_TMPDIR/kubectl" '{mode:"replay",collection:{kubectl:$bin,kubeconfig:"fixture"}}' > "$BATS_TEST_TMPDIR/config.json"
  run aiops collect-live --incident "$INCIDENT" --repo "$REPO" --revision "$REVISION" --config "$BATS_TEST_TMPDIR/config.json"
  [ "$status" -eq 0 ]
  jq -e '.incident.evidence.items | any(.kind == "state" and ((.data.message // "") | contains("ImagePullBackOff")))' <<< "$output"
  run grep -E 'must-never-leak|another-private-value' <<< "$output"
  [ "$status" -eq 1 ]
  run aiops show --incident "$INCIDENT"
  [ "$status" -eq 0 ]
  jq -e '.incident.evidence.partial == true and (.incident.evidence.omitted | any(.reason == "metrics-not-configured"))' <<< "$output"
}
