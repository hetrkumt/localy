# Localy EKS·GitOps 트러블슈팅 회고록 — 시리즈 목차

## 문서 목적

이 시리즈는 EKS 재생성 이후 인프라와 GitOps 제어면을 복구하면서 발생한 장애를 단순 작업 일지가 아닌 **원인·검증·재발 방지 중심의 기술 회고**로 정리한다.

문서마다 다음 질문에 답한다.

1. 사용자가 관찰한 최초 증상은 무엇이었는가?
2. 시스템 내부에서는 어떤 의존 관계가 깨졌는가?
3. 초기 가설과 실패한 시도는 왜 틀렸는가?
4. 어떤 증거가 진짜 원인을 입증했는가?
5. 응급 복구와 영구 해결은 어떻게 달랐는가?
6. 같은 장애를 다시 만들지 않으려면 무엇을 자동화해야 하는가?

단순 PowerShell 인용부호 실수나 명령어 오타는 독립 회고로 다루지 않는다. 다만 그것이 Secret JSON 손상이나 Terraform 입력 누락처럼 **실제 시스템 상태를 깨뜨렸거나 자동화 설계의 결함을 드러낸 경우**에는 원인 사슬에 포함한다.

---

## 전체 사건 흐름

```text
EKS 및 L1~L4 재구축
  → Argo CD GitOps 제어면 복구
  → 플랫폼 Pod Pending
  → Karpenter 부트스트랩 및 노드 조인 실패
  → Keycloak DB 인증·초기화 실패
  → OTel 기동·인증·OpenSearch 적재 실패
  → Secret 소유권과 RDS 비밀번호 SSOT 정리
  → Karpenter endpoint의 SSM·ESO 전환
  → 전체 상태 점검에서 DNS·Reloader·서비스 Missing 발견
  → teardown 자동화 보강 후 L4→L1 완전 철거
```

---

## 제안 목차

### [회고 1] [클러스터는 살아 있는데 Pod는 뜨지 않았다: Karpenter 부트스트랩의 닭과 달걀](./01-karpenter-bootstrap-deadlock.md)

**핵심 지식**

- EKS Managed Node Group과 Karpenter NodePool의 역할 분리
- `nodeSelector`, affinity, taint/toleration
- 부트스트랩 컨트롤러의 스케줄링 의존성
- Kubernetes `FailedScheduling` 이벤트 해석

**스토리라인**

EKS 시스템 노드는 `role=system` 라벨만 가지고 있었지만 Karpenter와 일부 플랫폼 컨트롤러는 `karpenter.sh/nodepool=system`을 요구했다. 해당 라벨은 Karpenter가 만든 노드에만 생기는데, 정작 Karpenter 자신이 스케줄되지 못해 새 노드를 만들 수 없었다. 용량 부족처럼 보였던 Pending을 스케줄러 이벤트로 분해하여 라벨 불일치임을 확인하고, 부트스트랩 컨트롤러를 Managed Node Group의 `role=system`에 배치해 순환 의존성을 끊었다.

**핵심 교훈**

새 노드를 만드는 컨트롤러는 자신이 만드는 노드에 의존하면 안 된다.

---

### [회고 2] [EC2는 생성됐지만 노드는 없었다: EKS 재생성 후 stale API endpoint 추적](./02-karpenter-stale-cluster-endpoint.md)

**핵심 지식**

- Karpenter NodeClaim과 EC2 인스턴스 생명주기
- kubelet bootstrap과 EKS API endpoint
- DNS `NXDOMAIN`과 노드 등록 실패
- 런타임 패치와 Git 영구 수정의 차이

**스토리라인**

Karpenter가 EC2를 정상 생성했지만 새 노드는 Kubernetes에 등록되지 않았다. 기존 Git values에는 삭제된 EKS 클러스터의 endpoint(`E583CF…`)가 남아 있었고, 재생성된 클러스터는 다른 endpoint(`A3DAFF…`)를 사용했다. 새 인스턴스의 kubelet은 존재하지 않는 호스트를 향해 접속하며 등록에 실패했다. Deployment의 `CLUSTER_ENDPOINT`를 수정하고 NodeClaim을 재생성해 복구한 뒤, endpoint를 Git에 하드코딩하는 구조 자체를 제거하는 후속 작업으로 이어졌다.

**핵심 교훈**

재생성 때 바뀌는 런타임 식별자를 Git 상수로 취급하면 복구 자동화가 과거 상태를 재주입한다.

---

### [회고 3] [비밀번호를 맞췄더니 데이터베이스가 없었다: Keycloak 장애의 연쇄 원인](./03-keycloak-password-and-database-chain.md)

**핵심 지식**

- Terraform `random_password`와 RDS master password
- AWS Secrets Manager, ESO, Kubernetes Secret의 전달 경로
- 인증 실패와 데이터베이스 부재 오류의 구분
- PostgreSQL 인스턴스와 논리 Database의 차이

**스토리라인**

Keycloak CrashLoop은 하나의 장애가 아니었다. 먼저 Terraform state의 비밀번호, RDS master password, Secrets Manager 값이 어긋났다. 수동 복구 과정에서는 Secret JSON 구조까지 손상되어 ESO가 `password` 속성을 읽지 못했다. Terraform `-replace=random_password.db_password`로 RDS와 Secrets Manager를 다시 같은 값으로 맞추자 에러가 `database "keycloak" does not exist`로 바뀌었다. 이는 인증 문제가 해결됐음을 보여주는 중요한 단서였다. 같은 RDS 인스턴스에 `keycloak` 논리 DB를 생성하면서 Keycloak 3개 Pod가 정상화됐다.

**핵심 교훈**

에러 메시지가 바뀌는 것은 실패가 아니라 원인 계층을 하나 통과했다는 증거일 수 있다.

---

### [회고 4] [응급 SQL을 재현 가능한 초기화로: Keycloak DB bootstrap Job 정식화](./04-keycloak-database-bootstrap-job.md)

**핵심 지식**

- `aws_db_instance.db_name`의 한계
- Private RDS와 Terraform 실행 위치의 네트워크 경계
- 멱등한 PostgreSQL DB 생성
- Argo CD sync wave와 hook
- Secret을 환경변수 대신 파일로 전달하는 패턴

**스토리라인**

응급 복구에서는 일회성 Kubernetes Job으로 `CREATE DATABASE keycloak OWNER postgres`를 실행했다. 하지만 RDS를 다시 만들면 같은 장애가 반복된다. L3 Terraform 실행 환경은 private RDS에 접근할 수 없으므로 PostgreSQL provider를 추가하는 방식도 적절하지 않았다. ESO가 만든 자격증명을 파일로 마운트하고, DB 존재 여부를 먼저 검사한 뒤 필요할 때만 생성하는 GitOps Job을 작성했다. SecretStore → ExternalSecret → DB Job → Keycloak 순서를 sync wave로 명시해 재구축 가능한 초기화 절차로 바꿨다.

**핵심 교훈**

응급처치가 성공했다면 다음 질문은 “이 작업이 다음 재구축에도 자동 재현되는가?”여야 한다.

---

### [회고 5] [Secret의 값이 아니라 소유권이 충돌했다: Argo CD와 ESO의 이중 제어](./05-argocd-eso-secret-ownership-conflict.md)

**핵심 지식**

- ExternalSecret과 생성된 Secret의 소유 관계
- Argo CD resource tracking label
- ESO metadata propagation
- Kubernetes optimistic concurrency와 `resourceVersion`
- `template.metadata`, `ignoreDifferences`, `creationPolicy`

**스토리라인**

ESO는 Secrets Manager 값을 정상적으로 읽었지만 `could not update Secret`과 `SecretSyncedError`가 반복됐다. ExternalSecret에 붙은 Argo tracking label이 생성된 Secret으로 복사되면서 Argo와 ESO가 같은 Secret을 자신의 관리 대상으로 인식했다. 두 컨트롤러가 같은 객체를 갱신해 `the object has been modified` 충돌이 발생했다. `spec.target.template.metadata`로 tracking label 전파를 차단하고, 생성 Secret의 관리자를 ESO로 한정했으며 Argo에는 동적 필드를 무시하도록 설정했다.

**핵심 교훈**

선언형 시스템에서 장애 원인은 값 자체보다 “어떤 컨트롤러가 그 값을 쓸 권한을 갖는가”일 수 있다.

---

### [회고 6] [Running은 성공이 아니었다: OTel Collector에서 OpenSearch 적재까지의 세 번의 실패](./06-otel-opensearch-end-to-end-failures.md)

**핵심 지식**

- OpenTelemetry Collector 설정 스키마
- `http.auth`와 SigV4
- IRSA credential chain
- OpenSearch index template과 field mapping
- SS4O data stream, `flatten_attributes`
- 수신 성공과 exporter 성공의 독립 검증

**스토리라인**

첫 번째 실패는 Collector 0.98에서 `auth` 위치가 잘못되어 프로세스가 기동하지 못한 것이었다. 이를 `http.auth`로 옮기자 이번에는 OpenSearch SigV4 자격증명이 없어 exporter가 실패했고, OTel 전용 IRSA role과 정책을 추가했다. Pod가 Running이 된 뒤에도 probe span을 보내자 `KeywordFieldMapper cannot be cast to ObjectMapper`가 발생했다. 처음 시도한 `traces_index`는 해당 버전에 존재하지 않는 옵션이라 효과가 없었다. 실제 원인은 `ss4o_traces_template`과 OTel 문서 구조의 매핑 충돌이었고, 기존 data stream과 template을 제거한 뒤 `flatten_attributes` 설정으로 적재를 검증했다.

**핵심 교훈**

관측 파이프라인은 `프로세스 기동 → 데이터 수신 → 인증 → 저장 성공 → 조회 가능`을 각각 검증해야 한다.

---

### [회고 7] [비밀번호의 주인은 한 명이어야 한다: RDS·Secrets Manager·ESO SSOT 설계](./07-rds-password-ssot.md)

**핵심 지식**

- Secret SSOT와 복제본의 구분
- Terraform state의 민감정보
- RDS password rotation
- Secrets Manager JSON schema
- ESO refresh와 애플리케이션 재시작

**스토리라인**

장애의 출발점이었던 RDS와 Secrets Manager의 비밀번호 드리프트를 재발 방지 관점에서 정리했다. `random_password.db_password`를 유일한 원본으로 두고 RDS와 Secrets Manager가 같은 값을 참조하도록 명시했다. ESO와 Kubernetes Secret은 쓰기 주체가 아니라 하위 소비 경로로 정의했다. 수동 `put-secret-value`, RDS console 변경, Kubernetes Secret 직접 수정은 금지하고, 로테이션은 Terraform `-replace`로만 수행하도록 태그·주석·검증 스크립트에 남겼다.

**핵심 교훈**

여러 시스템에 같은 비밀번호가 존재해도 원본은 하나여야 하며, 나머지는 모두 파생된 복제본이어야 한다.

---

### [회고 8] [하드코딩 제거는 끝이 아니었다: SSM→ESO→Karpenter와 Argo Multi-Source 장애](./08-karpenter-endpoint-eso-argocd-multisource.md)

**핵심 지식**

- SSM Parameter Store와 Secrets Manager의 용도 구분
- ESO의 ParameterStore provider
- Helm values의 `secretKeyRef`
- Argo CD Multi-Source Application의 `ref`와 `path`
- desired state 생성 실패와 live state 유지
- GitOps 실패 시 수동 컷오버의 위험

**스토리라인**

EKS endpoint의 원본은 이미 L2 Terraform이 관리하는 SSM Parameter Store에 있었다. ESO로 이를 Secret으로 옮기고 Karpenter의 `CLUSTER_ENDPOINT`를 `secretKeyRef`로 읽도록 바꿨다. 그러나 Argo Application이 Helm chart, values 전용 Git ref, ESO manifest path를 결합하는 과정에서 `failed to get git client`, nil pointer, EOF를 내며 desired manifest 생성에 실패했다. Git은 새 설정이지만 live Deployment는 과거 평문 endpoint로 계속 Running이었다. 동일 Git source의 `ref`와 `path`를 합쳐 source 구성을 단순화하고, 마지막에는 live Deployment를 Secret 참조로 컷오버해 기능을 복구했다.

**주의할 점**

현재 기록만으로는 Argo의 정확한 내부 결함을 확정할 수 없다. 문서 본문에서는 “같은 저장소를 두 번 참조해서 원천적으로 잘못됐다”가 아니라, **현재 Argo 2.9 환경에서 관찰된 특정 Multi-Source manifest generation 실패**로 표현하고 로그와 재현 조건을 분리해야 한다.

**핵심 교훈**

Git에 올바른 선언이 있다는 사실과 클러스터가 그 선언을 실행 중이라는 사실은 다르다.

---

### [회고 9] [`terraform destroy`도 운영 코드다: 완전 철거를 막은 세 가지 숨은 상태](./09-terraform-destroy-hidden-state.md)

**핵심 지식**

- Terraform 계층별 역순 destroy
- 필수 variable과 `-var-file`
- PowerShell argument parsing
- Karpenter EC2와 Security Group ENI 의존성
- S3 Object Lock COMPLIANCE
- Terraform state에서 의도적으로 분리한 orphan

**스토리라인**

L4→L1 철거 스크립트는 ECR, Load Balancer, Karpenter 인스턴스, S3를 선제 정리했지만 실제 실행에서 세 가지 문제가 드러났다. 첫째, L2의 필수 변수는 destroy에서도 필요했지만 `apply.local.tfvars`를 전달하지 않았다. 둘째, PowerShell에서 var-file 인자가 잘못 파싱됐다. 셋째, 긴 L3 destroy 동안 Karpenter 노드가 다시 생겼고 일부 인스턴스에는 예상한 `eks:cluster-name` 태그가 없어 node security group ENI가 10분 이상 삭제되지 않았다. 스크립트를 보완하고 남은 EC2를 종료해 L1~L4 state를 모두 0으로 만들었다. Loki 버킷은 Object Lock COMPLIANCE 때문에 의도적으로 state에서 분리해 보존했다.

**핵심 교훈**

배포 자동화만큼 철거 자동화도 반복 실행 가능하고, 실패 지점부터 안전하게 재개할 수 있어야 한다.

---

## 후속 조사 후 별도 회고 여부를 결정할 사건

### A. node-local-dns 전 노드 CrashLoop

철거 전 health snapshot에서 모든 node-local-dns Pod가 CrashLoopBackOff였다. 정확한 로그와 설정 diff를 수집하지 못했으므로 현재 정보만으로 원인을 단정하지 않는다. 다음 재배포에서 재현되면 아래를 수집한 뒤 독립 회고 여부를 결정한다.

- 이전 컨테이너 로그
- DaemonSet args와 ConfigMap
- CoreDNS Service IP 및 kubelet `clusterDNS`
- hostNetwork, local listen IP, iptables 충돌
- chart 버전과 EKS 1.30 호환성

### B. Reloader CrashLoop

Reloader가 Degraded였으며, 이 때문에 Secret 변경 후 자동 rollout이 보장되지 않았다. 당시 정확한 stack trace가 없어 별도 회고로 확정하지 않는다.

### C. 서비스 Application Missing

order, payment, cart, user, product, gateway 서비스가 OutOfSync/Missing이었다. 초기 기록에는 AppProject whitelist 문제 단서가 있었지만 전체 서비스의 공통 원인과 개별 원인을 충분히 검증하지 못했다. 재배포 후 동기화 실패 로그를 수집하여 하나의 GitOps 정책 회고 또는 서비스별 문제로 분류한다.

---

## 권장 집필 순서

독자가 원인 사슬을 따라가기 쉬운 순서는 다음과 같다.

1. 회고 1 — Karpenter 부트스트랩 순환 의존성
2. 회고 2 — stale cluster endpoint와 노드 조인
3. 회고 3 — Keycloak 인증·DB 부재 연쇄 장애
4. 회고 4 — DB bootstrap 정식화
5. 회고 5 — Argo·ESO Secret 소유권 충돌
6. 회고 6 — OTel→OpenSearch end-to-end 장애
7. 회고 7 — RDS 비밀번호 SSOT
8. 회고 8 — endpoint 동적 주입과 Multi-Source
9. 회고 9 — teardown 자동화

가장 교육적이고 독립적으로 완결되는 첫 글은 **회고 6(Otel→OpenSearch)**, 전체 복구 서사의 시작점으로 적합한 첫 글은 **회고 1(Karpenter 부트스트랩)**이다.

---

## 작성 상태

- [x] 시리즈 목차 초안
- [x] 사건별 로그·명령·코드 근거 대조 — 생략 (운영 재개에 불필요; 작성 중 로그·코드 대조로 대체)
- [x] 회고 1 본문
- [x] 회고 2 본문
- [x] 회고 3 본문
- [x] 회고 4 본문
- [x] 회고 5 본문
- [x] 회고 6 본문
- [x] 회고 7 본문
- [x] 회고 8 본문
- [x] 회고 9 본문
