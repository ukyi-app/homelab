# 인증은 환경변수 GITHUB_TOKEN 하나(owner의 gh auth token 또는 만료 있는 fine-grained PAT).
# tools/tf-github.sh로만 실행한다. 래퍼가 GITHUB_APP_* 셋을 지운다. 셋이 모두 있으면 provider가 토큰보다
# App 인증을 먼저 쓴다. 토큰을 -var로 넘기면 값이 plan 파일에 남는다(설계 C.3.9).
provider "github" {
  owner = "ukyi-app"
}
