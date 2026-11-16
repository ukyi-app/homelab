#!/usr/bin/env python3
"""관리자 단말에 찍기 직전의 정제. 표준 입력을 줄 단위로 읽어 표준 출력에 쓴다. run.sh와 node-cgroup.sh가 쓴다.

파드와 파드 안 프로세스의 명령줄은 믿지 않는 입력이다. 바이트 단위로 C0·DEL만 지우면 UTF-8로 적힌 C1(U+0080~U+009F)과
서식 문자(방향 뒤집기, 폭 없는 문자, 태그)가 남는다. 그래서 UTF-8로 풀어 유니코드 범주로 지운다.

- 남기는 제어 문자는 줄바꿈과 탭뿐이다.
- UTF-8이 아닌 바이트는 U+FFFD로 바꾼다. 날것의 0x80~0x9F 바이트를 C1 제어로 읽는 단말이 있다.
- 지우는 범주는 platform/olive-o02/files/o02.py의 DROP_CATEGORIES와 같다(바꾸면 함께 바꾼다).
"""
import sys
import unicodedata

DROP_CATEGORIES = ("Cc", "Cf", "Cs", "Co", "Cn", "Zl", "Zp")


def sanitize(data: bytes) -> bytes:
    text = data.decode("utf-8", errors="replace")
    kept = "".join(c for c in text if c in "\n\t" or unicodedata.category(c) not in DROP_CATEGORIES)
    return kept.encode("utf-8")


def main() -> None:
    out = sys.stdout.buffer
    # 줄마다 바로 내보낸다. 오래 도는 단계의 출력이 끝까지 쌓였다 한꺼번에 나오지 않게 한다.
    for line in sys.stdin.buffer:
        out.write(sanitize(line))
        out.flush()


if __name__ == "__main__":
    main()
