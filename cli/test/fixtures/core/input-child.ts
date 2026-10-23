// adapters.test.ts의 하위 프로세스. 파이프 stdin으로 시크릿 입력을 읽어 결과만 한 줄로 낸다(값은 내지 않는다).
import { readSecretInput } from "../../../src/core/input";

try {
  const s = readSecretInput(false, () => {}, "값: ");
  process.stdout.write(`ok ${s.sha256Prefix(12)}\n`);
} catch (e) {
  process.stdout.write(`error: ${(e as Error).message}\n`);
}
