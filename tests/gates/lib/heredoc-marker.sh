#!/usr/bin/env bash
# heredoc 여는 표기의 **런타임 조립기** — 코드 표면 가드의 픽스처가 공유한다.
#
# 왜 lib인가: `check-locale-collation`·`check-bats-style`의 회귀 픽스처는 "인용된 heredoc 표기가
# 뒤따르는 위반을 가리지 않는다"를 실증해야 하는데, 그 표기를 **테스트 파일에 리터럴로 적으면
# 그 파일 자신이 검출기에게 투명해진다**(고치려는 함정이 테스트를 쓰는 동안 실제로 물린다).
# 그래서 두 문자를 런타임에 조립한다. 근거가 픽스처마다 복사되면 다음 사람이 한 곳만 보고
# 리터럴로 되돌린다 — 처방이 한 소비자의 사유물이면 인접 표면은 그 처방을 못 받는다
# (선례: `tests/gates/lib/host-port.sh` 헤더의 같은 논거).
#
# ⚠️ 이 파일 자신도 두 문자를 리터럴로 담지 않는다. 담으면 같은 이유로 이 파일이 투명해진다.
#
# 사용: `. "<repo>/tests/gates/lib/heredoc-marker.sh"` 후
#       `hd="$(heredoc_marker)"; printf '%s\n' "cat ${hd}EOF" …
heredoc_marker() { local c='<'; printf '%s%s' "$c" "$c"; }
