# `terraform destroy`도 운영 코드다

> 완전 철거를 막은 필수 입력값, PowerShell 인자 파싱, Karpenter EC2·ENI, S3 Object Lock의 숨은 상태

## 문서 정보

- 사건 시각: 2026-07-31 03:17~04:20 KST
- 대상 환경: AWS `ap-northeast-2`, `prod`
- 실행 진입점: `localy/infrastructure/environments/prod/teardown.ps1`
- Terraform 계층: L1 network → L2 EKS → L3 app integration → L4 bootstrap
- 철거 순서: L4 → L3 → L2 → L1
- 최초 실행 결과: L4·L3 성공, L2 필수 변수 누락으로 중단
- 재개 중 오류: PowerShell이 `apply.local.tfvars`를 `.local.tfvars`로 전달
- L2 지연 원인: node Security Group을 사용 중인 EC2 ENI
- 의도적 잔여: Object Lock COMPLIANCE가 적용된 Loki S3 bucket
- 최종 결과: L1~L4 Terraform state의 resource 수 0
- AWS 검증 결과: EKS, VPC, RDS, OpenSearch, Karpenter/EKS EC2 없음

---

## Executive Summary

인프라를 완전히 철거하기 위해 기존 `teardown.ps1`을 실행했다.

배포는 다음 순서로 이루어진다.

```text
L1 network
  → L2 EKS
    → L3 app integration
      → L4 bootstrap
```

철거는 dependency의 역순으로 진행해야 한다.

```text
L4 bootstrap
  → L3 app integration
    → L2 EKS
      → L1 network
```

스크립트는 Terraform destroy 전에 다음 외부 resource를 정리하도록 설계돼 있었다.

```text
ECR repositories
Karpenter/EKS EC2 instances
k8s-* Load Balancers와 Target Groups
versioned S3 objects
Argo CD Applications와 Ingress
Object Lock bucket의 Terraform state
```

L4와 L3는 정상 삭제됐다. 그러나 약 31분 뒤 L2 진입 시 Terraform이 즉시 실패했다.

```text
No value for required variable
admin_ip

No value for required variable
chatops_sre_slack_user_ids
```

`destroy`도 Terraform configuration을 로드하고 expression을 평가하므로 기본값이 없는 input variable이 필요하다. apply 때 사용한 `apply.local.tfvars`를 destroy에 전달하지 않은 것이 첫 번째 문제였다.

스크립트를 수정해 var-file을 전달하고 L2부터 재개했다. 하지만 PowerShell에서 다음 명령을 직접 실행하자:

```powershell
terraform destroy -var-file=apply.local.tfvars
```

Terraform이 실제로 받은 path는 다음이었다.

```text
.local.tfvars
```

PowerShell의 native command argument parsing 과정에서 `apply`가 손실됐다.

```text
Failed to load ".local.tfvars" as a plan file
```

전체 path를 변수에 담고 하나의 quoted argument로 전달해 해결했다.

```powershell
$vf = Join-Path (Get-Location) "apply.local.tfvars"
terraform destroy "-var-file=$vf"
```

L2 destroy가 실행된 뒤에는 EKS control plane이 먼저 삭제됐지만 node Security Group은 11분 이상 `Still destroying` 상태에 머물렀다.

```text
module.eks.aws_security_group.node:
Still destroying...
```

Security Group 자체가 느린 것이 아니었다. 해당 SG를 사용하는 ENI가 EC2 instance에 부착돼 있어 AWS가 삭제를 거부하고 기다린 것이다.

초기 pre-cleanup으로 worker를 종료했지만 L3 destroy가 오래 진행되는 동안 Karpenter가 새 instance를 만들 수 있었다. 일부 잔여 instance는 예상한 `eks:cluster-name` 기반 조회만으로는 잡히지 않았다. SG에 연결된 ENI에서 instance ID를 역추적해 5개 instance를 직접 종료했다.

```text
Security Group
  ← ENI
    ← EC2 instance
```

instance 종료 후 ENI가 detach되고 node Security Group 삭제가 완료됐다.

```text
node SG destruction complete after 11m45s
L2: 91 resources destroyed
L1: 73 resources destroyed
```

Loki log bucket은 실패한 잔여가 아니었다.

```text
prod-eks-loki-logs-vault
Object Lock: COMPLIANCE
Retention: 90 days
```

COMPLIANCE retention이 끝나기 전에는 root account도 protected object version을 강제로 삭제할 수 없다. 따라서 무리하게 bucket 삭제를 반복하지 않고 관련 resource graph를 Terraform state에서 제거해 의도적으로 orphan으로 보존했다.

최종 검증:

```text
l1-network.tfstate          resources=0
l2-eks.tfstate              resources=0
l3-app-integration.tfstate  resources=0
l4-bootstrap.tfstate        resources=0

EKS          없음
VPC          없음
RDS          없음
OpenSearch   없음
Worker EC2   없음
```

남은 것은 retention 만료 후 별도로 삭제해야 하는 Loki vault bucket뿐이었다.

이번 사건의 핵심은 `terraform destroy`가 apply의 반대 버튼이 아니라는 점이다. destroy에도 configuration input, shell argument 규칙, cloud-side dependency, Kubernetes controller의 reconciliation, 법적 보존 정책까지 모두 반영해야 한다.

---

# Step 1. 발단 — 역순 destroy만으로는 인프라가 사라지지 않았다

## 1.1 왜 L4부터 지워야 하는가

상위 layer는 하위 layer의 output을 사용한다.

```text
L4:
  Argo bootstrap
  cluster access에 의존

L3:
  RDS, OpenSearch, Redis, MSK
  VPC/subnet/SG에 의존

L2:
  EKS, node groups, IAM
  VPC/subnet에 의존

L1:
  VPC, subnet, endpoint, route table
```

L1을 먼저 지우면 AWS가 dependency를 이유로 삭제를 거부한다.

```text
subnet in use
security group in use
network interface exists
VPC endpoint exists
```

따라서 철거 순서는 명확했다.

```powershell
$layers = @(
  "l4-bootstrap",
  "l3-app-integration",
  "l2-eks",
  "l1-network"
)
```

## 1.2 Terraform이 모르는 resource가 있다

Kubernetes controller는 Terraform state 밖에서 AWS resource를 만든다.

예:

```text
Karpenter
  → EC2 instance
  → ENI

AWS Load Balancer Controller
  → ALB/NLB
  → Target Group
  → ENI
```

Terraform이 EKS module과 VPC를 관리해도 이 runtime resource를 직접 추적하지 않을 수 있다.

따라서 destroy 전에 controller가 만든 resource를 먼저 정리해야 한다.

## 1.3 삭제 자체가 금지된 resource도 있다

Loki S3 bucket에는 Object Lock COMPLIANCE가 설정돼 있었다.

```hcl
mode = "COMPLIANCE"
days = 90
```

이는 단순한 `force_destroy=false`와 다르다.

```text
force_destroy=false:
  object를 비우면 bucket 삭제 가능

Object Lock COMPLIANCE:
  retention 전에는 protected version 삭제 불가
```

완전 철거의 정의에 예외가 필요했다.

## 1.4 최초 실행

```powershell
.\teardown.ps1 -SkipConfirm
```

스크립트는 다음 pre-cleanup을 수행했다.

1. ECR repository force-delete
2. Karpenter/EKS worker 종료
3. `k8s-*` Load Balancer와 Target Group 삭제
4. versioned S3 bucket 비우기
5. Loki Object Lock graph를 state에서 제거
6. Argo Application과 Ingress best-effort 삭제
7. L4→L1 Terraform destroy

## 1.5 L4와 L3는 성공한다

```text
L4: Destroy complete, 2 resources
L3: Destroy complete
```

RDS, MSK, OpenSearch 같은 managed service 삭제에는 시간이 오래 걸렸다.

이 긴 시간이 이후 Karpenter instance 재생성 가능 구간이 됐다.

## 1.6 L2에서 입력값 누락으로 중단된다

```text
No value for required variable
admin_ip

No value for required variable
chatops_sre_slack_user_ids
```

첫 실행은 여기서 중단됐다.

```text
Failed to destroy layer l2-eks.
Aborting remaining layers.
```

---

# Step 2. 기반 지식 — state, configuration, live AWS는 서로 다른 상태다

## 2.1 destroy도 configuration을 평가한다

자주 생기는 오해:

```text
destroy는 state에 있는 resource를 지우기만 하므로
apply input은 필요 없다.
```

실제 Terraform 처리:

```text
configuration load
  → provider/module initialization
  → input variable evaluation
  → state refresh
  → destroy graph 생성
  → API delete
```

기본값 없는 variable은 destroy graph를 만들 때도 필요하다.

```hcl
variable "admin_ip" {
  type = string
}

variable "chatops_sre_slack_user_ids" {
  type = list(string)
}
```

따라서 apply에서 var-file을 사용했다면 destroy에서도 같은 입력 경로를 준비해야 한다.

## 2.2 state가 0이라는 말의 범위

Terraform state resource가 0이면:

```text
Terraform이 계속 관리하는 resource가 없다.
```

다음을 자동으로 증명하지는 않는다.

```text
AWS account에 관련 resource가 전혀 없다.
controller가 만든 orphan이 없다.
state rm한 resource가 실제로 삭제됐다.
```

완료 검증은 두 축으로 해야 한다.

```text
Terraform state 검증
+ AWS inventory 검증
```

## 2.3 `terraform state rm`은 삭제가 아니다

```powershell
terraform state rm aws_s3_bucket.loki_logs
```

의미:

```text
Terraform:
  이 resource를 더 이상 관리하지 않는다.

AWS:
  실제 bucket은 그대로 존재한다.
```

따라서 `state rm`은 destroy 우회 명령이 아니라 ownership 이전이다.

사용 시 문서화해야 할 항목:

- 왜 삭제할 수 없는가
- 실제 resource는 어디에 남는가
- 비용과 보안 책임자는 누구인가
- 언제 어떻게 삭제할 것인가
- 다시 import할 가능성이 있는가

## 2.4 Security Group 삭제를 막는 실제 dependency

AWS에서 node SG는 EC2 ENI에 연결된다.

```text
EC2 instance
  → primary ENI
    → node Security Group
```

SG delete:

```text
ENI가 SG 사용 중
  → DependencyViolation
  → SG 삭제 대기/실패
```

SG 로그만 보면 원인을 알기 어렵다. 역방향으로 조사해야 한다.

```text
SG ID
  → describe-network-interfaces group-id
    → Attachment.InstanceId
      → describe-instances
```

## 2.5 Kubernetes controller는 destroy 중에도 reconcile한다

Karpenter의 목표:

```text
Pending workload가 있으면 node 생성
```

운영자가 Terraform destroy를 시작했다는 사실은 Karpenter가 자동으로 알지 못한다.

```text
초기 worker 종료
  → Pod Pending
    → Karpenter가 capacity 부족 판단
      → 새 EC2 생성
```

controller를 먼저 중지하지 않으면 cleanup과 reconciliation이 경쟁할 수 있다.

## 2.6 PowerShell과 native command argument

PowerShell은 외부 실행 파일에 인자를 넘기기 전에 자체 parser를 거친다.

문제가 된 형태:

```powershell
terraform destroy -var-file=apply.local.tfvars
```

관찰된 실제 Terraform 오류:

```text
Failed to load ".local.tfvars" as a plan file
```

안전한 형태:

```powershell
$destroyArgs = @(
  "destroy",
  "-auto-approve",
  "-input=false",
  "-var-file=$localTfvars"
)

& terraform @destroyArgs
```

또는:

```powershell
terraform destroy "-var-file=$localTfvars"
```

핵심은 각 native argument를 하나의 문자열로 확정하는 것이다.

## 2.7 Object Lock COMPLIANCE

COMPLIANCE mode에서는 retention 기간 전까지 protected object version을 변경하거나 삭제할 수 없다.

```text
IAM 권한 추가
root account
bucket force destroy
```

로도 우회할 수 없다.

따라서 retention이 활성화된 bucket을 사용하는 순간 teardown 정책에도 다음 분기가 필요하다.

```text
삭제 가능한 일반 resource
삭제 불가능해 보존할 regulated resource
```

---

# Step 3. CCTV 추적 — 어느 상태가 다음 삭제를 붙잡았는가

## 3.1 최초 pre-cleanup

ECR:

```powershell
aws ecr delete-repository `
  --repository-name $repo `
  --force
```

Karpenter/EKS EC2:

```text
karpenter.sh/nodepool
karpenter.sh/nodeclaim
karpenter.sh/managed-by
karpenter.k8s.aws/ec2nodeclass
eks:cluster-name
```

여러 tag key를 합쳐 instance ID set을 만들었다.

Load Balancer:

```text
LoadBalancerName starts_with k8s-
TargetGroupName starts_with k8s-
```

S3:

```text
current object
object version
delete marker
```

를 모두 지우도록 했다.

## 3.2 Object Lock bucket은 state에서 분리한다

Loki 관련 address:

```text
aws_s3_bucket_policy.loki_logs
aws_s3_bucket_lifecycle_configuration.loki_logs_lifecycle
aws_s3_bucket_server_side_encryption_configuration.loki_logs
aws_s3_bucket_public_access_block.loki_logs
aws_s3_bucket_object_lock_configuration.loki_logs
aws_s3_bucket_versioning.loki_logs
aws_s3_bucket.loki_logs
```

이 graph를 L3 state에서 제거했다.

실제 bucket:

```text
s3://prod-eks-loki-logs-vault
```

은 보존했다.

## 3.3 Argo reconciliation을 중지한다

클러스터가 살아 있으면:

```powershell
kubectl delete applications.argoproj.io `
  --all -n argocd --wait=false

kubectl delete ingress --all -A --wait=false

kubectl delete targetgroupbindings.elbv2.k8s.aws `
  --all -A --wait=false
```

목표:

```text
삭제 중 controller가 AWS resource를 다시 만들지 못하게 함
```

단, Application 삭제만으로 이미 실행 중인 Karpenter Deployment가 즉시 중지된다는 보장은 없다.

## 3.4 L2는 configuration 단계에서 실패한다

스크립트의 최초 형태:

```powershell
terraform destroy -auto-approve -input=false
```

오류:

```text
admin_ip is not set
chatops_sre_slack_user_ids is not set
```

AWS delete API에 도달하기 전 실패였다.

## 3.5 var-file 지원을 추가한다

```powershell
$localTfvars = Join-Path $layerPath "apply.local.tfvars"

if (Test-Path $localTfvars) {
  $destroyArgs += "-var-file=$localTfvars"
}
```

파일이 없을 때 L2 destroy graph를 로드하기 위한 placeholder도 추가했다.

```powershell
$destroyArgs += "-var=admin_ip=127.0.0.1/32"
$destroyArgs += `
  "-var=chatops_sre_slack_user_ids=[`"U00000000`"]"
```

placeholder는 destroy 전용이다. apply에 사용하면 안 된다.

## 3.6 첫 재개 명령은 PowerShell에서 깨진다

실행:

```powershell
terraform destroy `
  -auto-approve `
  -input=false `
  -var-file=apply.local.tfvars
```

오류:

```text
Failed to load ".local.tfvars" as a plan file
GetFileAttributesEx .local.tfvars:
The system cannot find the file specified.
```

Terraform이 `apply.local.tfvars`가 아니라 `.local.tfvars`를 받았다는 증거다.

## 3.7 quoted full path로 재개한다

```powershell
$vf = Join-Path (Get-Location) "apply.local.tfvars"

terraform destroy `
  -auto-approve `
  -input=false `
  "-var-file=$vf"
```

L2 destroy plan이 정상 생성됐다.

## 3.8 Managed Node Group 삭제가 오래 걸린다

```text
aws_eks_node_group.this:
Still destroying...
10m10s
```

이는 AWS managed node group의 instance drain/termination과 관련된 대기였다.

## 3.9 EKS control plane은 삭제되지만 node SG가 남는다

```text
EKS cluster:
Destruction complete after 3m21s

node SG:
Still destroying...
```

node SG:

```text
sg-0d522ec213321913c
```

10분 이상 삭제되지 않았다.

## 3.10 SG에서 ENI를 역추적한다

```powershell
aws ec2 describe-network-interfaces `
  --filters "Name=group-id,Values=$sg"
```

확인 항목:

```text
NetworkInterfaceId
Status
Description
InterfaceType
Attachment.InstanceId
```

ENI가 5개 EC2 instance에 연결돼 있었다.

```text
i-0758070ddd577fada
i-0fa5c238681ad2458
i-0e65963f541153d82
i-0c7c3f6dd0ddbd2e4
i-0621857cbd4429d57
```

## 3.11 잔여 EC2를 종료한다

```powershell
aws ec2 terminate-instances `
  --instance-ids $ids
```

instance 종료 후:

```text
EC2 terminated
  → ENI detached/deleted
    → node SG delete 가능
```

결과:

```text
node SG destruction complete after 11m45s
Destroy complete! Resources: 91 destroyed.
OK: l2-eks destroyed
```

## 3.12 L1을 이어서 삭제한다

VPC endpoint, route table, subnet, security group, VPC가 순서대로 제거됐다.

```text
Destroy complete! Resources: 73 destroyed.
OK: l1-network destroyed
RESUME TEARDOWN COMPLETE
```

## 3.13 Terraform state를 검증한다

S3 backend의 각 state를 읽어 resource 수를 확인했다.

```text
l1-network.tfstate          0
l2-eks.tfstate              0
l3-app-integration.tfstate  0
l4-bootstrap.tfstate        0
```

## 3.14 AWS inventory를 별도로 검증한다

확인 결과:

```text
EKS clusters       없음
prod VPC           없음
RDS                없음
OpenSearch         없음
running worker EC2 없음
```

Loki Object Lock bucket은 의도대로 남았다.

---

# Step 4. 삽질과 해결 — 실패 원인마다 복구 방법이 달랐다

## 4.1 단순 retry로 해결되지 않은 필수 변수

최초 스크립트는 destroy 실패 시 worker와 Load Balancer를 다시 정리한 뒤 Terraform을 재시도했다.

하지만 input variable 누락은 AWS dependency 문제가 아니다.

```text
같은 command 재시도
  → 같은 configuration error
```

오류를 계층별로 분류해야 했다.

```text
configuration/input error
shell parsing error
AWS dependency error
immutable retention policy
```

## 4.2 파일이 있는데 Terraform이 못 찾은 이유

`apply.local.tfvars`는 실제로 존재했다.

문제는 filesystem이 아니라 argument boundary였다.

```text
입력: apply.local.tfvars
전달: .local.tfvars
```

native command를 호출할 때는 실행 문자열이 아니라 최종 argument array를 검토해야 한다.

## 4.3 node SG를 직접 지우려 하면 안 되는 이유

SG가 ENI에 연결된 상태에서는 delete-security-group을 반복해도 해결되지 않는다.

```text
SG 삭제 실패
  → SG를 강제로 삭제
```

가 아니라:

```text
SG
  → ENI
    → owning EC2
      → EC2 종료
        → ENI 해제
          → SG 삭제
```

순서로 처리해야 한다.

## 4.4 초기 worker cleanup이 충분하지 않았던 이유

cleanup은 한 번의 snapshot이었다.

```text
t0: worker 조회
t1: worker 종료
t2~t30: L3 managed service destroy
t31: L2 destroy
```

t2~t30 동안 cluster controller가 새 worker를 만들 수 있다.

그래서 L2 바로 전에 다시 조회해야 한다.

```powershell
if ($layer -eq "l2-eks") {
  # re-scavenge worker instances
}
```

## 4.5 tag 하나만 믿으면 누락된다

Karpenter와 EKS node의 tag는 생성 주체와 버전에 따라 다를 수 있다.

```text
eks:cluster-name
karpenter.sh/nodepool
karpenter.sh/nodeclaim
karpenter.sh/managed-by
karpenter.k8s.aws/ec2nodeclass
```

이번에는 tag query에 잡히지 않은 잔여를 SG→ENI→instance 경로로 찾았다.

완전한 teardown은 tag 기반 조회와 dependency 기반 조회를 함께 사용해야 한다.

## 4.6 Object Lock을 실패로 처리하지 않은 이유

Object Lock은 장애가 아니라 요구사항이다.

```text
90일 동안 로그 변경·삭제 방지
```

teardown 때문에 이를 우회하려 하면 compliance 설계와 충돌한다.

따라서 완료 상태를 다음처럼 정의했다.

```text
삭제 가능한 infra: 모두 삭제
보존 의무 resource: state에서 분리하고 명시적으로 인계
```

## 4.7 `state rm`의 위험

잘못 사용하면 실제 AWS resource가 영구 orphan이 된다.

이번 bucket은 이름과 retention 이유를 script 마지막에 출력했다.

```text
NOTE: Orphan Object-Lock bucket may remain:
s3://prod-eks-loki-logs-vault
Delete manually after retention expires.
```

그러나 출력만으로 충분하지 않다. 후속 owner, 만료일, 비용 경보까지 관리해야 한다.

## 4.8 중단 지점부터 재개한 이유

L4와 L3 state는 이미 0이었다.

전체 스크립트를 처음부터 재실행하는 대신 L2→L1을 재개했다.

Terraform destroy는 state 기준으로 재실행 가능하지만, pre-cleanup의 직접 AWS delete와 `state rm`도 idempotent해야 안전하다.

```text
resource 없음
  → skip/success

resource 있음
  → delete
```

구조가 필요하다.

---

# Step 5. 넥스트 스텝 — teardown의 완료 조건을 코드로 만든다

## 5.1 실행 phase를 분리한다

권장 구조:

```text
Phase 0: identity와 target 검증
Phase 1: controller 정지
Phase 2: controller-owned AWS resource 정리
Phase 3: L4→L1 Terraform destroy
Phase 4: orphan inventory
Phase 5: completion report
```

## 5.2 account와 cluster guardrail

`-SkipConfirm`만으로 production 삭제를 허용하면 위험하다.

실행 전 최소 검증:

```text
AWS account ID
region
environment
backend key
EKS cluster name
caller ARN
```

예:

```powershell
if ($accountId -ne $ExpectedAccountId) {
  throw "Unexpected AWS account"
}
```

CI에서는 별도 approval과 short-lived role을 사용한다.

## 5.3 Karpenter를 먼저 정지한다

worker를 종료하기 전에:

```text
Karpenter Deployment scale 0
Argo Application auto-sync 중지/삭제
workload scale-down
NodePool/NodeClaim 정리
```

를 수행해야 reconciliation race를 줄일 수 있다.

클러스터 API가 사라진 뒤에는 이 작업을 할 수 없으므로 순서가 중요하다.

## 5.4 L2 직전 worker 재검증

```text
[ ] Karpenter/EKS running instance 0
[ ] node SG 사용 ENI 0
[ ] k8s-* Load Balancer 0
[ ] k8s-* Target Group 0
```

하나라도 남으면 Terraform destroy 전에 owner를 찾아 제거한다.

## 5.5 tag와 ENI를 함께 사용한다

권장 탐지:

```text
1. known node tag로 instance 조회
2. node SG로 ENI 조회
3. ENI attachment에서 instance 조회
4. Auto Scaling Group과 managed node group 조회
```

tag taxonomy 변경에도 견딜 수 있다.

## 5.6 PowerShell argument helper

외부 실행은 string interpolation 대신 argument array로 통일한다.

```powershell
$args = @(
  "destroy"
  "-auto-approve"
  "-input=false"
  "-var-file=$localTfvars"
)

Write-Host ("terraform " + ($args -join " "))
& terraform @args
```

민감한 `-var`가 있다면 log에서 값을 masking한다.

## 5.7 var-file 정책

```text
apply.local.tfvars 존재:
  동일 파일 사용

파일 없음:
  destroy graph 평가에만 필요한 safe placeholder 사용

실제 삭제 선택에 영향을 주는 variable:
  placeholder 금지
```

모든 required variable을 placeholder로 대체해도 안전한 것은 아니다. count, for_each, provider alias, resource selector에 영향을 주는 값은 apply 당시 값과 같아야 한다.

## 5.8 resume 가능한 checkpoint

각 layer 완료 후 machine-readable checkpoint를 남긴다.

```json
{
  "l4-bootstrap": "destroyed",
  "l3-app-integration": "destroyed",
  "l2-eks": "pending",
  "l1-network": "pending"
}
```

다만 checkpoint보다 Terraform remote state가 우선 원본이어야 한다.

## 5.9 Object Lock orphan registry

최소 기록:

```text
resource ARN
bucket name
state rm 시각
retention mode
최대 retain-until-date
monthly cost
owner
delete runbook
alert date
```

Object version마다 retain-until-date가 다를 수 있으므로 bucket 설정의 90일만 보고 삭제 가능일을 계산하면 안 된다.

## 5.10 teardown acceptance criteria

### Terraform

```text
[ ] L4 state resources=0
[ ] L3 state resources=0
[ ] L2 state resources=0
[ ] L1 state resources=0
```

### AWS

```text
[ ] EKS cluster 없음
[ ] node group 없음
[ ] Karpenter/EKS EC2 없음
[ ] node SG 사용 ENI 없음
[ ] k8s Load Balancer/Target Group 없음
[ ] prod VPC/subnet/endpoint 없음
[ ] RDS/OpenSearch/Redis/MSK 없음
[ ] ECR repository 정책에 맞게 삭제됨
```

### 의도적 orphan

```text
[ ] registry에 기록
[ ] owner 지정
[ ] 비용 확인
[ ] retention 만료 후 삭제 일정 등록
```

## 5.11 재발 방지 체크리스트

- [ ] apply와 destroy의 var-file 입력을 동일하게 관리한다.
- [ ] native command 인자는 배열로 전달한다.
- [ ] L4→L1 역순을 강제한다.
- [ ] controller를 EC2 cleanup 전에 중지한다.
- [ ] L2 직전에 worker를 다시 조회한다.
- [ ] tag 조회와 SG/ENI 역추적을 함께 사용한다.
- [ ] Terraform retry 전에 오류 유형을 분류한다.
- [ ] `state rm`을 resource 삭제로 간주하지 않는다.
- [ ] Object Lock orphan을 별도 registry로 관리한다.
- [ ] state 0과 AWS inventory 0을 각각 검증한다.
- [ ] `-SkipConfirm` 실행에 account guardrail을 둔다.
- [ ] 실패 지점부터 안전하게 재개할 수 있게 만든다.

---

## 최종 원인 트리

```text
prod 인프라 완전 철거 지연
│
├─ L2 destroy 시작 실패
│  ├─ admin_ip 필수 variable 누락
│  ├─ chatops_sre_slack_user_ids 누락
│  └─ destroy에도 configuration input 필요
│
├─ var-file 전달 실패
│  ├─ apply.local.tfvars는 존재
│  ├─ PowerShell native argument parsing
│  └─ Terraform은 .local.tfvars를 받음
│
├─ node Security Group 삭제 지연
│  ├─ SG를 사용하는 ENI 존재
│  ├─ ENI가 잔여 EC2 instance에 부착
│  ├─ 초기 cleanup 이후 instance 존재/재생성
│  └─ tag 조회만으로 일부 잔여 누락
│
├─ 삭제 불가능한 Loki bucket
│  ├─ Object Lock COMPLIANCE
│  ├─ 90일 retention
│  └─ Terraform state에서 의도적으로 분리
│
└─ 해결
   ├─ apply.local.tfvars를 destroy에 전달
   ├─ quoted full-path argument 사용
   ├─ SG→ENI→EC2 역추적 후 instance 종료
   ├─ L2→L1 destroy 재개
   ├─ L1~L4 state resources=0 확인
   └─ AWS inventory와 의도적 orphan 별도 검증
```

## 한 문장으로 남기는 교훈

**배포 자동화만큼 철거 자동화도 입력값·controller reconciliation·cloud dependency·보존 정책을 이해하고, 실패 지점부터 안전하게 재개할 수 있는 운영 코드여야 한다.**

