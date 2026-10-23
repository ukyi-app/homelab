// 값 안에서 Secret 객체를 찾는다. 출력·요청 본문·저장소 파일 내용에 시크릿이 실리는 것을 막는 데 쓴다.
import { isSecret } from "./secret";

export function findSecretPath(x: unknown, path: string): string | null {
  if (isSecret(x)) return path;
  if (Array.isArray(x)) {
    for (let i = 0; i < x.length; i++) {
      const p = findSecretPath(x[i], `${path}[${i}]`);
      if (p) return p;
    }
  } else if (x && typeof x === "object") {
    for (const [k, v] of Object.entries(x)) {
      const p = findSecretPath(v, `${path}.${k}`);
      if (p) return p;
    }
  }
  return null;
}
