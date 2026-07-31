# EC2는 생성됐지만 노드는 없었다

> EKS 재생성 뒤 남은 stale API endpoint와 Karpenter NodeClaim의 미등록 상태를 추적한 기록

## 문서 정보

- 사건 시각: 2026-07-30 23:22~23:35 KST
- 환경: Amazon EKS 1.30, Karpenter 0.37.0, AL2 기반 Karpenter node
- 선행 조건: 회고 1의 Karpenter controller 스케줄링 장애 복구 완료
- 영향 범위: workload·observability NodePool, Keycloak, OTel Gateway
- 최초 증상: EC2와 NodeClaim은 생성됐지만 `NODE`가 비어 있고 `READY=False`
- 직접 원인: Karpenter의 `CLUSTER_ENDPOINT`가 삭제된 이전 EKS API hostname을 가리킴
- 구조적 원인: 재생성 시 바뀌는 endpoint를 Git values에 정적으로 저장
- 응급 복구: Karpenter Deployment endpoint 갱신 후 기존 NodeClaim 재생성
- 영구 개선: L2 Terraform → SSM Parameter Store → ESO → Kubernetes Secret → Karpenter env

---

## Executive Summary

회고 1에서 Karpenter controller를 system node 위에 기동한 뒤, NodePool과 EC2NodeClass를 적용했다. Karpenter는 workload용 `c6i.large`와 observability용 `m6i.large` 인스턴스를 실제로 생성했다.

겉으로 보면 프로비저닝은 성공했다.

```text
NAME                  TYPE        ZONE              NODE   READY
observability-vxs4f   m6i.large   ap-northeast-2b          False
observability-z56d9   m6i.large   ap-northeast-2b          False
workload-p4tkw        c6i.large   ap-northeast-2c          False
workload-v96g2        c6i.large   ap-northeast-2a          False
workload-vk7zb        c6i.large   ap-northeast-2b          False
```

그러나 `NODE`가 비어 있고 `READY=False`였다. AWS에는 running EC2가 존재했지만 Kubernetes에는 system node 3대만 보였다.

이 사건의 핵심은 다음 등식이 틀렸다는 데 있다.

```text
EC2 running = Kubernetes Node Ready
```

실제 과정은 훨씬 길다.

```text
NodeClaim 생성
  → EC2 인스턴스 생성
  → user data 실행
  → kubelet 기동
  → EKS API hostname DNS 조회
  → API server TLS 연결
  → bootstrap 인증
  → Node 객체 등록
  → CNI·kube-proxy 초기화
  → Node Ready
```

당시 Karpenter Deployment에는 재생성 전 EKS endpoint가 남아 있었다.

```text
Karpenter 설정:
https://E583CF0454E256924147D1439D485B87...eks.amazonaws.com

실제 EKS endpoint:
https://A3DAFF463A698E5ECAC4DAFBC8249BF0...eks.amazonaws.com
```

Karpenter는 과거 endpoint를 새 노드의 bootstrap 정보에 주입했다. 새 EC2의 kubelet은 이미 삭제된 hostname을 조회했고 DNS에서 `NXDOMAIN`을 받았다. API server에 도달하지 못했기 때문에 IAM 인증이나 Security Group 평가까지 갈 수 없었고 Node 객체도 등록되지 않았다.

Karpenter Deployment의 `CLUSTER_ENDPOINT`를 현재 endpoint로 바꾸고 기존 NodeClaim을 재생성하자 약 1분 안에 workload 3대와 observability 2대가 모두 Ready가 됐다.

```text
ip-10-0-11-32...    Ready   workload        workload
ip-10-0-12-66...    Ready   workload        workload
ip-10-0-13-161...   Ready   workload        workload
ip-10-0-13-231...   Ready   observability   observability
ip-10-0-13-254...   Ready   observability   observability
```

즉시 복구 후에는 endpoint 하드코딩을 제거했다. L2 Terraform이 이미 `/localy/prod/eks/cluster_endpoint`를 SSM Parameter Store에 기록하고 있었으므로, ESO가 이를 Kubernetes Secret으로 동기화하고 Karpenter가 `secretKeyRef`로 읽게 했다.

---

# Step 1. 발단 — NodeClaim은 생겼는데 Node는 생기지 않았다

## 1.1 첫 번째 성공 신호

Karpenter controller가 Running이 된 뒤에도 처음에는 NodePool이 없었다. UTF-8이 손상된 kustomization과 잘못된 discovery tag·node role·disruption 설정을 수정하고 NodePool을 적용하자 다음 리소스가 만들어졌다.

```text
NodePools:
  system
  workload
  observability
  finops-batch

EC2NodeClass:
  Ready

NodeClaims:
  workload / observability 여러 개 launched
```

Karpenter 로그와 AWS EC2 상태만 보면 노드 프로비저닝이 진행되는 것처럼 보였다. 실제로 각 NodeClaim에는 provider ID가 할당됐고 대응하는 EC2 인스턴스도 running이었다.

## 1.2 하지만 Kubernetes 관점에서는 실패였다

3분이 넘도록 NodeClaim 상태는 다음과 같았다.

```text
NODE    <empty>
READY   False
```

`kubectl get nodes`에는 기존 Managed Node Group 3대만 존재했다.

```text
NAME                  ROLE     NODEPOOL
ip-10-0-11-18...      system
ip-10-0-12-29...      system
ip-10-0-13-9...       system
```

새 EC2는 존재하지만 Kubernetes Node 객체가 없었다. 이 차이가 조사 범위를 결정했다.

```text
Karpenter가 EC2를 못 만들었는가?          아니오
EC2가 부팅되지 않았는가?                 아니오
부팅한 EC2의 kubelet이 클러스터에 등록됐는가?  아니오
```

문제는 프로비저닝 앞단이 아니라 **node bootstrap과 registration 구간**에 있었다.

## 1.3 사용자 영향

NodePool별 capacity가 없었기 때문에 다음 Pod는 계속 Pending이었다.

```text
auth-namespace   keycloak-0/1/2
monitoring       otel-gateway-opentelemetry-collector-*
```

Karpenter controller가 살아났어도 capacity가 Kubernetes에 등록되지 않으면 스케줄러 입장에서는 사용할 노드가 없는 것과 같다.

---

# Step 2. 기반 지식 — EC2 인스턴스가 Kubernetes Node가 되기까지

## 2.1 NodeClaim의 세 단계

Karpenter NodeClaim 상태를 이해하려면 다음 단계를 분리해야 한다.

### Launch

AWS API를 통해 EC2를 만들고 provider ID를 얻는다.

```text
Launched=True
providerID=aws:///ap-northeast-2x/i-...
```

### Register

EC2에서 실행된 kubelet이 Kubernetes API에 접속해 Node 객체를 생성하거나 기존 객체와 연결된다.

```text
Registered=True
status.nodeName=<node-name>
```

### Initialize / Ready

CNI, kube-proxy, 기본 taint 처리와 노드 상태 보고가 완료돼 workload를 받을 수 있다.

```text
Initialized=True
Ready=True
```

이번 사건은 Launch까지 성공하고 Register에서 멈춘 경우였다.

```text
Initialized=False, Registered=False
```

## 2.2 Karpenter의 `clusterEndpoint`가 왜 노드 생성에 영향을 주는가

Karpenter AWS provider는 EC2NodeClass와 클러스터 설정을 바탕으로 node bootstrap용 user data를 생성한다. AL2 계열에서는 개념적으로 다음 정보가 필요하다.

```text
cluster name
API server endpoint
cluster CA
kubelet arguments
```

새 인스턴스는 이 정보로 kubelet kubeconfig를 준비하고 API server에 연결한다. endpoint가 틀리면 EC2 생성 자체는 성공하지만 kubelet은 잘못된 서버를 향한다.

이것이 다음 상태가 동시에 가능했던 이유다.

```text
AWS EC2: running
Karpenter NodeClaim: launched
Kubernetes Node: 없음
```

## 2.3 EKS cluster name은 같아도 endpoint는 같지 않다

클러스터를 삭제하고 같은 이름 `prod-eks`로 다시 만들어도 EKS control plane은 새로운 identity를 갖는다.

재생성 전:

```text
E583CF0454E256924147D1439D485B87
```

재생성 후:

```text
A3DAFF463A698E5ECAC4DAFBC8249BF0
```

따라서 다음 가정은 안전하지 않다.

```text
cluster name이 같으므로 API endpoint도 계속 같다.  (잘못된 가정)
```

EKS endpoint는 생성된 control plane의 출력값이며, 재생성 가능한 구성에서는 동적으로 전달해야 한다.

## 2.4 DNS 오류와 네트워크 오류는 다르다

잘못된 hostname이 이미 삭제돼 DNS에서 존재하지 않으면 다음 단계로 진행할 수 없다.

```text
kubelet
  → DNS query
  → NXDOMAIN
  → IP 주소를 얻지 못함
  → TCP 연결 시도 자체가 없음
  → TLS·IAM·RBAC 평가도 없음
```

반대로 DNS가 정상이라면 그다음에 Security Group, route, NACL, TLS, IAM bootstrap을 확인해야 한다.

장애 계층을 순서대로 확인하지 않으면 뒤쪽 계층을 불필요하게 수정하게 된다.

## 2.5 Parameter Store와 Secrets Manager의 구분

EKS endpoint는 비밀값이 아니다.

```text
EKS API endpoint     → 구성값
RDS password         → 비밀값
```

따라서 원본 저장소는 SSM Parameter Store가 적절하다. 이 환경의 L2 Terraform은 이미 endpoint를 다음 경로에 기록하고 있었다.

```hcl
resource "aws_ssm_parameter" "eks_cluster_endpoint" {
  name  = local.ssm_paths["eks_cluster_endpoint"]
  type  = "String"
  value = module.eks.cluster_endpoint
}
```

실제 parameter path:

```text
/localy/prod/eks/cluster_endpoint
```

Kubernetes Secret으로 전달한 것은 값이 비밀이기 때문이 아니라 Helm Deployment의 env를 `secretKeyRef`로 주입하고 ESO 변경 감지를 활용하기 위한 구현 선택이었다.

---

# Step 3. CCTV 추적 — 새 노드가 과거 클러스터를 찾아간 순간

## 3.1 Karpenter가 NodeClaim을 생성한다

workload와 observability Pod 수요에 따라 Karpenter가 NodeClaim 5개를 만들었다.

```text
workload-p4tkw
workload-v96g2
workload-vk7zb
observability-vxs4f
observability-z56d9
```

EC2 API 호출은 성공했다. instance type, subnet, security group, IAM instance profile이 결정됐고 인스턴스가 running으로 전환됐다.

## 3.2 user data에 stale endpoint가 들어간다

당시 Karpenter Deployment 환경에는 과거 endpoint가 남아 있었다.

```text
CLUSTER_ENDPOINT=
https://E583CF0454E256924147D1439D485B87.gr7.ap-northeast-2.eks.amazonaws.com
```

Karpenter는 이 정보를 새 인스턴스 bootstrap 설정에 사용했다.

## 3.3 인스턴스 OS와 kubelet은 정상적으로 기동한다

EC2가 running이고 SSM Run Command에 응답했으므로 다음은 확인됐다.

```text
인스턴스 전원·하이퍼바이저    정상
기본 OS 부팅                 정상
VPC 기본 통신                정상
SSM agent                    정상
```

이 상태는 “인스턴스가 정상”이라는 인상을 주지만 Kubernetes node registration까지 보장하지 않는다.

## 3.4 kubelet이 과거 hostname을 조회한다

kubelet이 참조한 endpoint는 `E583CF…`였다. 실제 EKS API는 `A3DAFF…`였다.

```text
kubelet target: E583CF...
live endpoint:  A3DAFF...
```

과거 EKS control plane이 삭제되면서 `E583CF…` hostname은 더 이상 유효한 endpoint가 아니었다. 노드에서 조회했을 때 DNS는 `NXDOMAIN`을 반환했다.

```text
E583CF...eks.amazonaws.com → NXDOMAIN
A3DAFF...eks.amazonaws.com → 현재 EKS endpoint
```

## 3.5 registration 이전에 연결이 끊긴다

DNS 조회 실패로 kubelet은 API server IP를 얻지 못했다.

```text
DNS 실패
  → TCP 443 연결 없음
  → TLS handshake 없음
  → bootstrap token/IAM 인증 없음
  → CSR 없음
  → Node object 없음
```

NodeClaim controller는 EC2 provider ID는 알고 있었지만 대응하는 Node 객체를 찾지 못했다.

```text
Initialized=False
Registered=False
NODE=<empty>
READY=False
```

## 3.6 스케줄러는 새 capacity가 존재하지 않는 것으로 본다

AWS 콘솔에 인스턴스 5대가 있어도 scheduler는 Kubernetes Node API에 등록된 객체만 사용한다.

```text
AWS capacity: 증가
Kubernetes schedulable capacity: 변화 없음
```

그 결과 Keycloak과 OTel Gateway는 계속 Pending이었다.

---

# Step 4. 삽질과 해결 — 인증을 고쳤지만 노드는 오지 않았다

## 4.1 첫 번째 오진: EKS access entry 문제

NodeClaim이 `Registered=False`였으므로 먼저 Karpenter node IAM role의 EKS access entry를 의심했다.

확인 과정:

```text
aws eks list-access-entries
aws eks describe-access-entry
aws eks list-associated-access-policies
kubectl get configmap aws-auth
```

당시 access entry에 `system:bootstrappers`가 없고 associated policy도 비어 있는 상태를 발견했다. 이를 root cause로 판단하고 다음을 수정했다.

- access entry에 `system:bootstrappers`, `system:nodes` 추가
- `AmazonEKSNodePolicy` 연결
- `aws-auth`에 Karpenter node role 추가
- 기존 NodeClaim 삭제 후 재생성

이 변경은 node 인증 구성을 보강한다는 점에서는 타당할 수 있었지만, **이번 장애의 직접 원인은 아니었다.**

## 4.2 왜 오진임을 인정해야 했는가

인증 설정을 수정하고 새 NodeClaim을 만들어도 상태가 바뀌지 않았다.

```text
Registered=False
NODE=<empty>
```

인증이 유일한 원인이었다면 새 인스턴스는 API server까지 도달한 뒤 등록됐어야 한다. 실패가 그대로라는 사실은 조사 계층을 앞쪽으로 되돌려야 한다는 신호였다.

더 중요한 문제는 당시 kubelet이 API server에 **도달조차 하지 못했다**는 점이다. DNS에서 실패했다면 access entry는 평가되지 않는다.

```text
실제 실패 지점: DNS
수정한 지점:    API 인증
```

뒤쪽 계층을 먼저 수정한 셈이다.

## 4.3 두 번째 조사: Security Group과 endpoint 접근성

다음으로 Karpenter node security group과 EKS cluster security group을 비교했다.

- node egress
- cluster SG ingress
- endpoint private/public access
- subnet과 route
- CSR 생성 여부

하지만 이 역시 직접 원인을 설명하지 못했다. 네트워크 ACL이나 SG가 차단했다면 hostname은 IP로 해석되고 TCP timeout 또는 connection 오류가 발생해야 한다. 실제 증거는 hostname 해석 실패였다.

## 4.4 결정적 조사: 실행 중인 노드에서 kubelet과 DNS를 직접 본다

EC2는 SSM agent에 연결돼 있었기 때문에 SSM Run Command로 다음을 확인할 수 있었다.

```bash
journalctl -u kubelet -n 80 --no-pager
cat /etc/resolv.conf
getent hosts <endpoint>
dig +short <endpoint> @10.0.0.2
grep -R endpoint /etc/kubernetes/
```

이 조사에서 kubelet이 참조하는 endpoint와 현재 EKS endpoint가 다르다는 사실이 드러났다.

비교:

```powershell
aws eks describe-cluster `
  --name prod-eks `
  --query "cluster.endpoint"

aws ssm get-parameter `
  --name /localy/prod/eks/cluster_endpoint `
  --query Parameter.Value

kubectl -n kube-system get deploy karpenter `
  -o jsonpath="{...CLUSTER_ENDPOINT...}"
```

결과:

```text
EKS live:   A3DAFF...
SSM:        A3DAFF...
Karpenter:  E583CF...
```

Terraform과 SSM은 새 클러스터를 알고 있었다. Git/Helm을 통해 배포된 Karpenter만 과거 값을 갖고 있었다.

## 4.5 응급 복구

Karpenter Deployment의 endpoint를 현재 값으로 변경했다.

```powershell
$ep = "https://A3DAFF463A698E5ECAC4DAFBC8249BF0.gr7.ap-northeast-2.eks.amazonaws.com"

kubectl -n kube-system set env deployment/karpenter `
  CLUSTER_ENDPOINT=$ep

kubectl -n kube-system rollout status deployment/karpenter `
  --timeout=120s
```

기존 NodeClaim은 이미 stale endpoint로 만든 user data를 가진 인스턴스와 연결돼 있었다. Deployment env만 고쳐도 기존 EC2의 bootstrap 설정은 자동으로 바뀌지 않는다. 따라서 기존 NodeClaim을 삭제해 새 설정으로 인스턴스를 다시 만들었다.

```powershell
kubectl delete nodeclaims --all
```

## 4.6 복구 검증

새 NodeClaim으로 생성된 노드는 1분 이내에 등록되기 시작했다.

초기:

```text
workload node        Ready
observability node   NotReady → Ready 전환 중
```

최종:

```text
ip-10-0-11-32...    Ready   workload        workload
ip-10-0-12-66...    Ready   workload        workload
ip-10-0-13-161...   Ready   workload        workload
ip-10-0-13-231...   Ready   observability   observability
ip-10-0-13-254...   Ready   observability   observability
```

영향받던 Pod의 상태도 바뀌었다.

```text
Keycloak:
Pending → Running

OTel Gateway:
Pending → CrashLoopBackOff
```

OTel의 CrashLoopBackOff는 실패가 남았다는 의미지만, **스케줄링과 node registration 문제는 해결됐다는 증거**였다. Pod가 노드에 배치돼 컨테이너 실행 단계까지 진입했기 때문이다. 이후 OTel 설정 오류는 별도 회고에서 다룬다.

## 4.7 1차 영구 수정: Git의 endpoint 교체

런타임 패치만 하면 Argo CD가 과거 Git 값으로 되돌릴 수 있다. 먼저 values의 endpoint를 현재 값으로 갱신했다.

```yaml
settings:
  clusterEndpoint: "https://A3DAFF...eks.amazonaws.com"
```

이 조치는 현재 클러스터에 대해서는 재발을 막지만, 다음 EKS 재생성에는 다시 stale 값이 된다. 따라서 완전한 영구 해결은 아니었다.

## 4.8 최종 개선: endpoint의 SSOT를 SSM으로 이동

L2 Terraform은 클러스터 생성 직후 실제 endpoint를 SSM에 저장한다.

```hcl
resource "aws_ssm_parameter" "eks_cluster_endpoint" {
  name  = local.ssm_paths["eks_cluster_endpoint"]
  type  = "String"
  value = module.eks.cluster_endpoint
}
```

ESO용 SecretStore는 Parameter Store를 사용한다.

```yaml
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: karpenter-ssm-store
  namespace: kube-system
spec:
  provider:
    aws:
      service: ParameterStore
      region: ap-northeast-2
```

ExternalSecret은 SSM 값을 Kubernetes Secret으로 동기화한다.

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: karpenter-cluster-settings
  namespace: kube-system
spec:
  target:
    name: karpenter-cluster-settings
    creationPolicy: Owner
  data:
    - secretKey: clusterEndpoint
      remoteRef:
        key: /localy/prod/eks/cluster_endpoint
```

Karpenter는 더 이상 Git에 endpoint 문자열을 저장하지 않는다.

```yaml
controller:
  env:
    - name: CLUSTER_ENDPOINT
      valueFrom:
        secretKeyRef:
          name: karpenter-cluster-settings
          key: CLUSTER_ENDPOINT
```

최종 데이터 흐름:

```text
EKS 생성
  → Terraform output
    → SSM /localy/prod/eks/cluster_endpoint
      → ESO
        → Secret karpenter-cluster-settings
          → Karpenter CLUSTER_ENDPOINT
            → 새 node bootstrap
```

## 4.9 최종 개선 과정에서 남은 별도 문제

ESO Secret은 실제 SSM endpoint와 일치했고 Karpenter Deployment도 최종적으로 `secretKeyRef`를 사용했다.

```text
CLUSTER_ENDPOINT
secret=karpenter-cluster-settings/CLUSTER_ENDPOINT
```

다만 Argo CD 2.9의 Multi-Source manifest generation 과정에서 `failed to get git client`, nil pointer, EOF가 발생해 live Deployment 컷오버는 수동으로 수행했다. 이는 endpoint SSOT 설계의 오류와는 다른 GitOps reconciliation 문제이며 회고 8에서 별도로 다룬다.

---

# Step 5. 넥스트 스텝 — 동적 출력값을 정적 입력으로 되돌리지 말라

## 5.1 가장 중요한 설계 원칙

> 인프라가 생성할 때 결정되는 값을 Git에 복사해 상수로 만들면, 다음 재생성에서 Git이 과거 인프라를 복원하려 한다.

이번 사건의 잘못된 흐름:

```text
EKS endpoint 출력
  → 사람이 Git values에 복사
    → EKS 재생성
      → Git에는 과거 endpoint 유지
```

개선된 흐름:

```text
EKS endpoint 출력
  → Terraform이 SSM 갱신
    → ESO가 클러스터로 전달
      → Karpenter가 현재 값 사용
```

## 5.2 임시 식별자와 안정 식별자를 구분한다

### 상대적으로 안정적인 값

```text
cluster logical name: prod-eks
AWS region: ap-northeast-2
SSM parameter path: /localy/prod/eks/cluster_endpoint
```

### 재생성 시 달라질 수 있는 값

```text
EKS API endpoint hostname
OIDC issuer ID
cluster security group ID
subnet·ENI·instance ID
certificate authority data
```

후자는 Terraform output, SSM, remote state 등 런타임 연결 계층을 통해 전달해야 한다.

## 5.3 NodeClaim 장애 진단 순서

### 1단계: NodeClaim 상태를 단계별로 분리한다

```powershell
kubectl get nodeclaims
kubectl describe nodeclaim <name>
```

확인할 조건:

```text
Launched
Registered
Initialized
Ready
providerID
nodeName
```

### 2단계: EC2 존재 여부를 확인한다

```powershell
aws ec2 describe-instances `
  --instance-ids <instance-id> `
  --query "Reservations[].Instances[].{id:InstanceId,state:State.Name,ip:PrivateIpAddress}"
```

판단:

```text
EC2 없음       → launch/IAM/quota/subnet/AMI 조사
EC2 running    → bootstrap/registration 조사
```

### 3단계: 실패 계층을 앞에서부터 확인한다

```text
OS boot
  → DNS
  → route/SG/NACL
  → TLS/CA
  → IAM/bootstrap auth
  → CSR/Node registration
  → CNI initialization
```

뒤쪽 계층을 먼저 수정하지 않는다.

### 4단계: source of truth를 세 방향으로 비교한다

```powershell
# 실제 EKS
aws eks describe-cluster --name prod-eks `
  --query "cluster.endpoint"

# Terraform이 내보낸 공유 값
aws ssm get-parameter `
  --name /localy/prod/eks/cluster_endpoint `
  --query Parameter.Value

# Karpenter가 현재 사용하는 값
kubectl -n kube-system get deploy karpenter -o yaml |
  Select-String -Pattern "CLUSTER_ENDPOINT|clusterEndpoint" -Context 0,3
```

세 값이 같아야 한다.

### 5단계: 노드 내부 증거를 확보한다

SSM이 가능하면:

```bash
journalctl -u kubelet -n 100 --no-pager
cat /etc/resolv.conf
getent hosts <eks-endpoint>
curl -vk --connect-timeout 3 <eks-endpoint>/healthz
```

## 5.4 모니터링·알람 개선

다음 상태는 조기에 감지할 수 있다.

### NodeClaim registration 지연

```text
Launched=True
Registered=False
age > 2~3분
```

### EC2와 Kubernetes node 수 차이

```text
Karpenter-tagged running EC2 수
>
Karpenter Node 수
```

### endpoint drift

정기 검증:

```text
EKS live endpoint
==
SSM endpoint
==
Karpenter env가 참조하는 Secret 값
```

단, Secret의 실제 값을 로그나 모니터링 레이블에 노출하지 않는 일반 원칙은 유지한다. EKS endpoint는 비밀이 아니지만 동일 검증 패턴을 다른 민감 설정에 재사용할 수 있기 때문이다.

## 5.5 배포·재구축 acceptance criteria

EKS 재생성이 끝났다고 판단하려면 control plane 생성 성공만 확인해서는 안 된다.

```text
[ ] Terraform L2 output의 endpoint와 SSM 값이 일치
[ ] Karpenter가 SSM/ESO에서 endpoint를 읽음
[ ] Karpenter controller Running
[ ] EC2NodeClass Ready
[ ] NodePool 생성
[ ] NodeClaim Launched=True
[ ] NodeClaim Registered=True
[ ] NodeClaim Ready=True
[ ] workload·observability node가 kubectl get nodes에 표시
[ ] 대표 workload가 Pending에서 다음 단계로 전환
```

## 5.6 재발 방지 체크리스트

- [ ] EKS endpoint를 Git values에 직접 저장하지 않는다.
- [ ] OIDC issuer와 CA data도 재생성 가능 값으로 취급한다.
- [ ] Terraform이 생성한 동적 값을 SSM에 게시한다.
- [ ] ESO가 Parameter Store 값을 읽을 최소 권한을 갖는다.
- [ ] Karpenter env가 literal `value`가 아니라 `valueFrom`을 사용한다.
- [ ] endpoint Secret 변경 시 Karpenter rollout 경로를 보장한다.
- [ ] NodeClaim 재생성 전 기존 인스턴스의 진단 로그를 수집한다.
- [ ] `Registered=False`를 곧바로 IAM 문제로 단정하지 않는다.
- [ ] DNS → 네트워크 → TLS → 인증 순서로 조사한다.
- [ ] Git desired state와 live Deployment를 모두 확인한다.

---

## 최종 원인 트리

```text
Keycloak·OTel Pending 지속
│
├─ Kubernetes에 workload/observability node 없음
│  │
│  ├─ NodeClaim 생성 성공
│  ├─ EC2 running 성공
│  └─ Node registration 실패
│     │
│     ├─ kubelet이 stale EKS hostname 사용
│     │  ├─ Karpenter CLUSTER_ENDPOINT = E583CF...
│     │  └─ 실제 EKS endpoint = A3DAFF...
│     │
│     └─ stale hostname DNS NXDOMAIN
│        └─ API server에 도달하기 전에 실패
│
├─ 구조적 원인
│  └─ 재생성 시 바뀌는 endpoint를 Git에 하드코딩
│
├─ 오진
│  ├─ EKS access entry / aws-auth
│  └─ Security Group
│
└─ 영구 개선
   └─ Terraform → SSM → ESO → Secret → Karpenter
```

## 한 문장으로 남기는 교훈

**클라우드에서 인스턴스가 `running`이라는 것은 VM이 켜졌다는 뜻일 뿐, 그 VM이 Kubernetes의 일부가 됐다는 뜻은 아니다.**

