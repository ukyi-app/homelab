// kubectl 하위 명령 앞에 둘 수 있는 것은 전역 플래그뿐이다(1.36.5 `kubectl options`). 그 밖의 플래그(-A 등)가 앞에 있으면
// kubectl은 그 자리를 플러그인 이름으로 보고 "flags cannot be placed before plugin name"으로 거부한다.
// 함정: 스텁이 argv를 그대로 맞추기만 하면 이 순서 결함을 못 잡는다(T12-05 운영에서 data list가 깨졌다). 스텁과 시험이 같이 쓴다.
const GLOBAL_BOOL = new Set(["--disable-compression", "--insecure-skip-tls-verify", "--match-server-version", "--warnings-as-errors"]);
const GLOBAL_VALUE = new Set([
  "--as", "--as-group", "--as-uid", "--as-user-extra", "--cache-dir", "--certificate-authority", "--client-certificate", "--client-key",
  "--cluster", "--context", "--kubeconfig", "--kuberc", "--log-flush-frequency", "-n", "--namespace", "--password", "--profile",
  "--profile-output", "--request-timeout", "-s", "--server", "--tls-server-name", "--token", "--user", "--username", "-v", "--v", "--vmodule",
]);

// 하위 명령 앞에 놓인 전역이 아닌 첫 플래그. 없으면 null. args는 kubectl 뒤의 인자다.
export function kubectlLeadingProblem(args: string[]): string | null {
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (!a.startsWith("-")) return null;
    const name = a.split("=")[0];
    if (GLOBAL_BOOL.has(name)) continue;
    if (GLOBAL_VALUE.has(name)) {
      if (!a.includes("=")) i++;
      continue;
    }
    return a;
  }
  return null;
}
