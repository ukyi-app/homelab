#!/usr/bin/env bash
# 실제 배포 룰을 합성 계수로 replay한다. 클러스터·webhook·구독 계정은 호출하지 않는다.
# AIOps 실패가 deadman으로 발화했던 결함과 진짜 deadman 장애, 무라벨 이전 계열을 함께 대조한다.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STACK="$ROOT/platform/victoria-stack/prod"
# shellcheck source=tests/gates/lib/vmalert-e2e.sh
. "$ROOT/tests/gates/lib/vmalert-e2e.sh"
vme_scenario "webhook-e2e-net-$$" "$STACK" "$STACK/rules/core.yaml" core.yaml
yq -o=json '.' "$VME_RULES" > "$VME_TMP/deployed.json"
python3 - "$VME_TMP" <<'PY'
import json
from pathlib import Path
import sys
import time

root = Path(sys.argv[1])
names = {'DeadmanswitchRelayUnreachable', 'AlertmanagerWebhookDeliveryFailed', 'DeadmanswitchDeliveryMetricsMissing'}
source = json.loads((root / 'deployed.json').read_text())
rules = [r for g in source['groups'] for r in g['rules'] if r.get('alert') in names]
assert len(rules) == 3 and {r['alert'] for r in rules} == names, 'webhook rule roster changed'
assert all(r['for'] == ('15m' if r['alert'] == 'DeadmanswitchDeliveryMetricsMissing' else '5m')
           for r in rules), 'webhook delay contract changed'
(root / 'selected.json').write_text(json.dumps({'groups': [{'name': 'webhook', 'rules': rules}]}))
start = (int(time.time()) // 60) * 60 - 3600
end = start + 1800
(root / 'range.txt').write_text(str(start) + ' ' + str(end))
samples = []
for scenario, receiver, integration, growing in (
    ('aiops-failed', 'aiops', 'webhook', True),
    ('deadman-failed', 'deadmanswitch', 'webhook', True),
    ('deadman-healthy', 'deadmanswitch', 'webhook', False),
    ('aiops-healthy', 'aiops', 'webhook', False),
    ('legacy-failed', None, 'webhook', True),
    ('other-failed', 'future-receiver', 'webhook', True),
    ('telegram-failed', 'telegram', 'telegram', True),
    ('typo-metric', 'deadmanswitc', 'webhook', False),
    ('am-down', None, 'webhook', False),
    ('other-pod', None, 'webhook', False),
):
    labels = {'scenario': scenario, 'instance': scenario + ':9093', 'namespace': 'observability',
              'pod': 'alertmanager-' + scenario}
    if scenario == 'other-pod':
        labels['pod'] = 'unrelated-exporter'
    metric = {'__name__': 'alertmanager_notifications_failed_total', 'integration': integration,
              'reason': 'other', **labels}
    if receiver is not None:
        metric['receiver_name'] = receiver
    samples.append({'metric': metric, 'timestamps': [t * 1000 for t in range(start - 900, end + 61, 60)],
                    'values': [i if growing else 0 for i, _ in enumerate(range(start - 900, end + 61, 60))]})
    samples.append({'metric': {'__name__': 'up', **labels},
                    'timestamps': samples[-1]['timestamps'],
                    'values': [0 if scenario == 'am-down' else 1] * len(samples[-1]['timestamps'])})
    if scenario not in ('am-down', 'other-pod'):
        total = {'__name__': 'alertmanager_notifications_total', 'integration': 'webhook', **labels}
        if scenario != 'legacy-failed':
            total['receiver_name'] = 'deadmanswitc' if scenario == 'typo-metric' else 'deadmanswitch'
        samples.append({'metric': total, 'timestamps': samples[-1]['timestamps'],
                        'values': [0] * len(samples[-1]['timestamps'])})
(root / 'fixture.jsonl').write_text('\n'.join(json.dumps(s) for s in samples) + '\n')
PY
yq -P '.' "$VME_TMP/selected.json" > "$VME_TMP/webhook.yaml"
read -r FROM TO < "$VME_TMP/range.txt" || [ -n "${TO:-}" ]
VM="webhook-e2e-vm-$$"
vme_leg "$VM" "$VME_TMP/fixture.jsonl"
vme_replay "$VM" "$VME_VA_VER" "$VME_TMP/webhook.yaml" "$VME_EVAL" "$VME_LOOKBACK" "$FROM" "$TO"
vme_query_args 'count by (alertname,scenario) (count_over_time(ALERTS{alertstate="firing"}[2h]))'
curl "${VME_QUERY_ARGS[@]}" > "$VME_TMP/firing.json"
# 동결 결함 식이 같은 AIOps 입력에서 양성인지 검사해 회귀 표본의 감지력을 보증한다.
vme_query_args 'increase(alertmanager_notifications_failed_total{integration="webhook"}[15m]) > 0' "$TO"
curl "${VME_QUERY_ARGS[@]}" > "$VME_TMP/buggy.json"
python3 - "$VME_TMP" <<'PY'
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
def result(name):
    value = json.loads((root / name).read_text())
    assert value['status'] == 'success' and value['data']['resultType'] == 'vector'
    return value['data']['result']
actual = {(v['metric']['alertname'], v['metric']['scenario']) for v in result('firing.json')}
expected = {('DeadmanswitchRelayUnreachable', 'deadman-failed')}
expected |= {('AlertmanagerWebhookDeliveryFailed', s) for s in ('aiops-failed', 'legacy-failed', 'other-failed')}
expected |= {('DeadmanswitchDeliveryMetricsMissing', s) for s in ('legacy-failed', 'typo-metric')}
assert actual == expected, (actual, expected)
assert {v['metric']['scenario'] for v in result('buggy.json')} == {
    'aiops-failed', 'deadman-failed', 'legacy-failed', 'other-failed'
}, 'original defect is not reproduced by the fixture'
print('PASS webhook replay: 10 scenarios, receiver isolation, missing metric guard, original defect reproduced')
PY
