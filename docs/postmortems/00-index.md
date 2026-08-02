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

## 시즌 2 — 재배포 가능성을 검증하면서 드러난 운영 계약

시즌 1이 “무너진 플랫폼을 어떻게 복구했는가”를 다뤘다면, 시즌 2는 복구 이후 **같은 환경을 다시 만들고 없앨 수 있는가**를 검증하는 과정에서 발견한 문제를 다룬다.

백로그 번호나 작업 순서는 글의 기준으로 사용하지 않는다. 독자가 장애의 인과관계를 따라갈 수 있도록 하나의 독립된 실패 모델마다 한 편을 배정한다. 단순 개선 작업은 별도 회고로 부풀리지 않고, 기존 회고의 후속 설계 또는 운영 런북에서 다룬다.

### 시즌 2 사건 흐름

```text
L1~L4 재배포
  → 플랫폼 컨트롤러 기동
  → Reloader의 HA 설정 계약 불일치
  → Keycloak·OAuth 자격증명의 다중 시스템 정렬
  → 빈 ECR과 이미지 태그·CPU 아키텍처 불일치
  → Argo CD의 동적 필드·소유권·reconcile 상태 오판
  → ingress-core의 인증서·webhook·VPC·subnet 의존성 연쇄 장애
  → 동일 도메인을 두 ALB가 주장한 ExternalDNS 충돌
  → Object Lock 데이터와 과거 KMS 키의 생명주기 충돌
  → 두 번째 L4→L1 철거에서 orphan Security Group 제거
```

---

### [회고 10] [Reloader는 왜 자기 이름을 요구했나: replica 수와 HA 모드의 숨은 계약](./10-reloader-ha-half-config.md)

**핵심 지식**

- Helm chart 값과 실제 컨테이너 argument의 차이
- leader election과 Pod identity
- `replicas`, `enableHA`, `POD_NAME`의 결합 조건
- CrashLoopBackOff에서 렌더링 결과를 읽는 방법

**스토리라인**

Reloader는 두 replica로 배포됐지만 `enableHA: false`였다. 그런데 렌더링된 컨테이너에는 `--enable-ha=true`가 들어갔고, HA 모드가 요구하는 `POD_NAME` 환경변수는 없었다. 프로세스는 `POD_NAME not set`으로 반복 종료됐다. Deployment의 replica 수, chart 값, 실제 args와 env를 대조해 모순을 확인했고, 현재 가용성 요구에 맞춰 단일 replica·HA 비활성으로 정렬했다.

**핵심 교훈**

Helm values의 각 필드는 독립 옵션이 아니다. 함께 만족해야 하는 런타임 계약을 렌더링 결과로 검증해야 한다.

---

### [회고 11] [Secret을 회전했더니 인증이 끊겼다: OAuth 자격증명의 양쪽 끝 맞추기](./11-oauth-secret-rotation-contract.md)

**핵심 지식**

- OAuth client credential의 issuer 측 원본과 consumer 측 복제본
- Terraform `random_password`, Secrets Manager, ESO, Keycloak client
- admin bootstrap credential과 운영 credential의 차이
- `client_credentials` grant를 이용한 기능 검증

**스토리라인**

Terraform이 user·edge OAuth secret을 새로 생성하자 Secrets Manager와 Kubernetes Secret은 갱신됐지만 Keycloak client에는 과거 값이 남았다. 반대로 Keycloak만 바꿔도 애플리케이션이 이전 secret을 사용하면 인증은 실패한다. 두 시스템을 같은 값으로 정렬한 뒤 토큰 endpoint에 `client_credentials` 요청을 보내 HTTP 200을 확인했다. 이 사건은 “Secret이 존재한다”와 “인증 관계의 양쪽 끝이 일치한다”가 다른 조건임을 보여줬다.

**핵심 교훈**

공유 자격증명의 회전은 값을 생성하는 작업이 아니라 producer와 verifier를 원자적으로 전환하는 배포 작업이다.

---

### [회고 12] [매니페스트는 이미지를 가리켰지만 레지스트리는 비어 있었다: 배포 산출물의 SSOT](./12-ecr-image-artifact-ssot.md)

**핵심 지식**

- ECR repository와 image artifact의 생명주기 차이
- Git SHA, 고정 tag, `latest`의 의미
- CI build/push와 GitOps image pin의 연결
- teardown 이후 재배포에서 코드와 artifact가 갖는 비대칭성

**스토리라인**

인프라와 GitOps 선언은 복구됐지만 ECR은 철거 과정에서 비워졌다. 매니페스트의 `newTag`와 CI가 실제로 push하는 tag도 일치하지 않아 Pod는 실행할 이미지를 찾을 수 없었다. image pin 파일을 기준으로 필요한 이미지를 점검·재빌드하는 스크립트를 만들고, CI가 GitOps 고정 tag와 운영 편의용 `latest`를 함께 push하도록 정렬했다.

**핵심 교훈**

GitOps는 배포할 artifact를 선언할 뿐 artifact 자체를 보존하지 않는다. 재구축 가능성에는 이미지 공급망도 포함돼야 한다.

---

### [회고 13] [노드는 준비됐는데 컨테이너가 실행되지 않았다: CPU 아키텍처도 배포 계약이다](./13-cpu-architecture-deployment-contract.md)

**핵심 지식**

- OCI image platform과 EC2 instance architecture
- Karpenter NodePool 요구조건
- `linux/amd64` 단일 이미지와 multi-arch manifest
- 스케줄 성공과 컨테이너 실행 성공의 차이

**스토리라인**

Karpenter workload NodePool은 Graviton 계열을 허용했지만 CI가 만든 서비스 이미지는 `linux/amd64`뿐이었다. 스케줄러 관점에서는 정상 노드였지만 kubelet은 해당 CPU에서 이미지를 실행할 수 없었다. 즉시 복구에서는 NodePool과 workload·Job의 selector를 amd64로 제한했고, CI도 buildx의 플랫폼을 명시했다. multi-arch 이미지는 가능한 대안이지만 검증되지 않은 상태에서 NodePool만 arm64로 넓히지 않도록 경계를 남겼다.

**핵심 교훈**

스케줄링 요구조건과 이미지 빌드 플랫폼은 서로 다른 저장소에 있어도 하나의 배포 계약이다.

---

### [회고 14] [실제 리소스는 정상인데 Argo CD는 왜 OutOfSync였나: 동적 필드와 제어권 경계](./14-argocd-dynamic-fields-ownership.md)

**핵심 지식**

- desired state와 controller-mutated state
- ESO default/status, KEDA replica, generated Secret
- `ignoreDifferences`와 `RespectIgnoreDifferences`
- 강제 reconcile annotation이 만드는 자기 드리프트

**스토리라인**

워크로드와 ExternalSecret은 정상 동작했지만 Argo CD에는 OutOfSync가 누적됐다. 원인은 장애 난 리소스가 아니라 ESO가 기본값과 status를 기록하고, KEDA가 Deployment replica를 바꾸며, ESO가 생성한 Secret data를 소유하는 정상 동작이었다. 여기에 임시 `force-sync` annotation이 Git에 없는 변경으로 남아 드리프트를 증폭했다. 컨트롤러별 쓰기 권한을 구분해 동적 필드만 무시하고, 임시 annotation과 orphan PDB를 제거했다.

**핵심 교훈**

모든 차이를 제거하는 것이 GitOps 정합성은 아니다. 정상적으로 변해야 하는 필드의 주인을 명시하는 것이 정합성이다.

---

### [회고 15] [Ingress 하나가 뜨기까지: annotation·webhook·인증서·VPC·subnet의 연쇄 장애](./15-ingress-core-dependency-chain.md)

**핵심 지식**

- Kubernetes annotation qualified name 규칙
- AWS Load Balancer Controller admission webhook TLS
- ALB controller의 VPC discovery
- subnet tag와 internet-facing/internal ALB
- ACM·WAF ARN처럼 재생성 때 바뀌는 식별자

**스토리라인**

`ingress-core`의 Missing은 단일 원인이 아니었다. 잘못된 annotation key가 API validation을 통과하지 못했고, 클러스터 재생성 뒤 webhook TLS secret과 endpoint가 깨졌으며, 매니페스트에는 삭제된 ACM·WAF ARN과 과거 VPC ID가 남아 있었다. 이를 고친 뒤에도 public subnet의 cluster tag가 부족해 ALB subnet discovery가 실패했다. API validation에서 AWS resource discovery까지 계층별 증거를 따라가며 외부·내부 ALB를 모두 생성했다.

**핵심 교훈**

Ingress는 YAML 한 장이 아니라 Kubernetes API, admission, controller 설정, AWS 네트워크 자원의 합성 결과다.

---

### [회고 16] [같은 도메인을 두 ALB가 주장했다: ExternalDNS의 마지막 writer 문제](./16-externaldns-hostname-ownership.md)

**핵심 지식**

- ExternalDNS source와 TXT registry
- Route 53 Alias record
- external/internal Ingress의 hostname 소유권
- reconcile loop와 last-writer 효과

**스토리라인**

외부 ALB와 내부 ALB가 모두 생성됐지만 두 Ingress가 `feifo.click`을 hostname으로 사용했다. ExternalDNS는 두 객체를 유효한 source로 보았고, public Route 53 A record를 internal ALB로 반복 갱신했다. exclude annotation만으로 해결을 시도했으나 충돌을 명확히 제거하기 위해 내부 host를 `internal.feifo.click`로 분리했다. 이후 `feifo.click`은 external ALB, 내부 이름은 internal ALB를 가리키는지 Route 53과 HTTPS redirect로 검증했다.

**핵심 교훈**

DNS 자동화에서는 레코드 값보다 먼저 “누가 이 hostname을 소유하는가”가 유일해야 한다.

---

### [회고 17] [리소스는 있는데 Missing이었다: Argo CD reconcile 정체와 orphan 경고의 범위](./17-karpenter-argocd-reconcile-orphans.md)

**핵심 지식**

- Argo Application status cache와 live resource
- cluster-scoped CR의 destination namespace
- AppProject `orphanedResources`
- Server-Side Apply와 managed fields
- controller 재시작이 필요한 상태와 불필요한 상태

**스토리라인**

네 개 NodePool과 EC2NodeClass는 실제 클러스터에 존재하고 정상 동작했지만 `karpenter-provisioner` Application은 OutOfSync/Missing으로 표시됐다. 동시에 destination이 `kube-system`인 platform project가 자신이 관리하지 않는 140여 개 리소스를 orphan으로 경고했다. ignore 설정을 넓혀도 상태가 바뀌지 않은 이유는 application-controller reconcile이 nil pointer 오류 이후 과거 시각에 멈춰 있었기 때문이다. orphan 평가 범위를 바로잡고 controller를 재시작하자 모든 Karpenter CR이 Synced로 재평가됐다.

**핵심 교훈**

제어면의 관측 결과가 실제 상태와 모순될 때는 리소스를 반복 수정하기 전에 관측기를 갱신하고 캐시 시각을 확인해야 한다.

---

### [회고 18] [새 KMS 키로는 옛 로그를 열 수 없었다: Object Lock과 암호 키의 생명주기](./18-loki-object-lock-legacy-kms.md)

**핵심 지식**

- S3 SSE-KMS와 객체별 KMS key binding
- Object Lock COMPLIANCE
- KMS pending deletion과 crypto-shredding
- IAM S3 권한과 KMS decrypt 권한의 분리
- IAM role 재생성 후 stale principal ID

**스토리라인**

재배포 후 Loki bucket의 기본 암호화는 새 KMS 키를 사용했지만, Object Lock으로 보존된 기존 객체는 옛 키로 암호화돼 있었다. 철거 때 삭제 예약된 옛 키 때문에 compactor가 `KMSInvalidStateException`으로 기동하지 못했다. 키 삭제를 취소하고 다시 활성화하자 backend가 복구됐지만, key policy에는 삭제된 과거 IRSA의 RoleId가 남아 있었다. 현재 role ARN으로 policy를 정렬하고 Terraform에 legacy key policy를 명시해 다음 재배포에서도 같은 객체를 읽을 수 있게 했다.

**핵심 교훈**

보존 기간이 데이터보다 짧은 암호 키는 보존 정책을 무효화한다. 데이터와 키의 생명주기를 함께 설계해야 한다.

---

### [회고 19] [한 글자가 플랫폼 Application 전체를 막았다: 보이지 않는 YAML control character 추적](./19-yaml-c1-control-character.md)

**핵심 지식**

- UTF-8 C1 control character
- Argo CD Multi-Source manifest generation
- Kustomize의 오류 위치 해석
- 바이트 검사와 화면상 문자열의 차이

**스토리라인**

Grafana용 Secret은 준비됐지만 kube-prometheus-stack은 manifest를 생성하지 못했다. 오류는 `network-policy.yaml: control characters are not allowed`였으나 일반적인 ASCII 제어문자 검사에서는 아무것도 나오지 않았다. UTF-8 바이트열을 조사해 주석 안의 `C2 80` C1 문자를 찾았고, 깨진 주석을 정상 ASCII 문장으로 교체하자 Kustomize build와 Grafana ExternalSecret 동기화가 재개됐다.

**핵심 교훈**

화면에 보이는 텍스트가 파일의 실제 바이트를 모두 설명하지는 않는다. 파서 오류가 재현되면 문자열이 아니라 인코딩 계층까지 내려가야 한다.

---

### 기존 회고 9에 추가할 후속 에필로그

두 번째 철거에서는 L4→L3→L2가 정상 완료됐지만 L1 VPC 삭제가 19분간 멈췄다. AWS Load Balancer Controller가 만든 `k8s-traffic-*` Security Group이 Terraform과 Kubernetes 양쪽의 소유권 밖에 남아 있었기 때문이다. 해당 orphan SG를 확인·삭제하자 VPC가 즉시 제거됐다. 이 사건은 별도 회고로 분리하지 않고 **회고 9의 “orphan sweep은 태그 종류별로 수행해야 한다”는 후속 사례**로 추가한다.

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

원인이 `replicas: 2`, `enableHA: false`, `POD_NAME` 누락의 조합으로 확인됐다. 시즌 2 **회고 10**으로 승격한다.

### C. 서비스 Application Missing

서비스 자체의 Missing은 복구됐지만, 과정에서 확인한 원인은 Secret schema, 이미지 부재, CPU architecture, 동적 필드 drift 등 서로 달랐다. 하나의 “서비스 Missing” 회고로 뭉치지 않고 시즌 2의 관련 사건에 나눠 기록한다.

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
10. 회고 10 — Reloader HA 설정 계약
11. 회고 11 — OAuth secret 회전
12. 회고 12 — ECR artifact SSOT
13. 회고 13 — CPU architecture 계약
14. 회고 14 — Argo CD 동적 필드와 제어권
15. 회고 15 — ingress-core 연쇄 장애
16. 회고 16 — ExternalDNS hostname 충돌
17. 회고 17 — Karpenter reconcile·orphan 오판
18. 회고 18 — Object Lock과 legacy KMS
19. 회고 19 — YAML control character

시즌 2는 실제 복구 순서를 이해하려면 회고 10부터 번호대로 읽는 것이 좋다. 개별적으로 가장 독립적인 글은 **회고 13(CPU architecture)**과 **회고 16(ExternalDNS)**이고, 제어면을 깊게 이해하려면 **회고 14→17** 순서가 적합하다.

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
- [x] 시즌 2 목차 초안
- [x] 회고 9 두 번째 철거 에필로그
- [x] 회고 10 본문
- [x] 회고 11 본문
- [x] 회고 12 본문
- [x] 회고 13 본문
- [x] 회고 14 본문
- [x] 회고 15 본문
- [x] 회고 16 본문
- [x] 회고 17 본문
- [x] 회고 18 본문
- [x] 회고 19 본문
