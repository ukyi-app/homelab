{{/*
자식 Application 공통 규칙(설계 C.3.3 "root 아래 wave와 규칙").

자식 Application을 더하는 방법: templates/<이름>.yaml 하나에 Application 하나(또는 같은 티켓의 몇 개)를 둔다.
- metadata.namespace는 argocd, sync-wave는 설계 C.3.1 표의 "순서" 열.
- 자기 저장소 source는 repoURL에 homelab.repoURL을 쓰고 targetRevision은 main을 직접 적는다.
- 외부 Helm 차트는 chart와 고정 semver를 쓴다. chart를 쓰면 repoURL은 Helm 저장소, targetRevision은 semver다(설계 B.8 E2).
- retry는 homelab.retry를 쓴다. 봇 자리만 예외다(bot-slot.yaml).
- resources-finalizer는 기본으로 붙이지 않는다. 붙이면 Application 삭제가 그 리소스 삭제로 번진다.
- CreateNamespace를 쓰지 않는다. ns와 PSA 라벨은 namespaces(wave -9)가 만든다.
- Application spec에 zero-value(false, 0, 빈 문자열)를 적지 않는다. 컨트롤러 정규화가 지우고 selfHeal이 다시 넣어
  플립플롭한다(설계 B.8 E2). 끄고 싶은 불리언은 키를 빼서 끈다.
- root → 자식 Application → 리소스로 selfHeal이 사슬로 걸린다. 그래서 Application 하나를 잠시 끄는 것은 Git 변경
  밖에서는 안 되고, kubectl로 라이브를 바꾸는 장애 주입은 약 5초 만에 되돌려져 거짓 PASS를 낸다(설계 B.8 E2).
  장애 주입 시험은 Git PR로 하거나 Argo CD 밖 자원(외부 계정·네트워크)에서 한다.
- 클러스터 값(values-prod.yaml·values-vm.yaml)은 Helm 차트인 구성 요소에만 넘긴다(사용자 결정 2026-10-19, T07,
  설계 E8 VM 격리 1번 A안). 넘기는 길은 spec.source.helm.valuesObject 하나다. 클러스터 값이 필요한 평문
  매니페스트는 platform/<이름>/에 Chart.yaml을 둔 작은 로컬 차트로 감싼다. Kustomize·평문 디렉터리는 클러스터
  값을 받지 않는다. 그 차트 안 ExternalSecret target.template의 이중 중괄호는 Helm이 렌더하지 않게 이스케이프한다.
*/}}

{{/*
자기 저장소 주소. targetRevision은 값으로 열지 않고 템플릿마다 main을 직접 적는다.
값으로 열어 두면 values 파일 한 줄로 브랜치를 가리킬 수 있다(L31).
*/}}
{{- define "homelab.repoURL" -}}
https://github.com/ukyi-app/homelab
{{- end }}

{{/*
모든 자식 Application의 retry: limit 10, backoff 30s에서 최대 5m(factor는 기본 2라 적지 않는다).
retry가 소진되면 Argo CD는 다시 시도하지 않는다. 그때는 명시 sync가 필요하다(설계 B.8 E2).
*/}}
{{- define "homelab.retry" -}}
limit: 10
backoff:
  duration: 30s
  maxDuration: 5m
{{- end }}
