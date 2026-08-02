# Ingress 하나가 뜨기까지

> annotation·admission webhook·ACM/WAF ARN·VPC·subnet discovery가 순서대로 실패한 `ingress-core` 연쇄 장애

## 문서 정보

- 사건 시각: 2026-07-31 22:27~22:46 KST
- 환경: Amazon EKS 1.30, AWS Load Balancer Controller, Argo CD, ALB, ACM, WAFv2
- 대상 Application: `ingress-core`
- 대상 Ingress:
  - `auth-namespace/localy-external-alb-keycloak`
  - `edge-service/localy-external-alb-edge`
  - `edge-service/localy-internal-alb-edge`
- 최초 상태: Argo CD `OutOfSync / Missing`
- 장애 계층:
  1. 잘못된 Ingress annotation key
  2. readiness gate를 Ingress annotation으로 잘못 표현
  3. AWS Load Balancer Controller webhook TLS 이상
  4. teardown 이전 ACM·WAF ARN
  5. controller의 teardown 이전 VPC ID
  6. public subnet의 cluster discovery tag 누락
- 즉시 복구:
  - invalid annotation 제거
  - namespace readiness label 추가
  - webhook TLS secret·controller Pod 재생성
  - ACM·WAF ARN 갱신
  - controller `vpcId` 갱신
  - public subnet에 cluster shared tag 추가
- 결과:
  - external·internal ALB 생성
  - `ingress-core` `Synced / Healthy`
- 후속 사건: 동일 hostname을 두 ALB가 주장한 ExternalDNS 충돌은 회고 16
- 남은 중요 부채:
  - public subnet cluster tag의 live 수정이 Terraform에 아직 반영되지 않음
  - ALB controller VPC ID와 Ingress ACM/WAF ARN이 여전히 Git에 하드코딩
  - 사용되지 않는 `patch-ingress.yaml`에 stale ARN이 남아 있음

---

## Executive Summary

`ingress-core`는 Argo CD에서 하나의 `Missing` 상태로 보였다.

그러나 원인은 하나가 아니었다.

```text
Ingress manifest
  → Kubernetes API validation
    → AWS LBC admission webhook
      → Ingress object 저장
        → AWS LBC reconcile
          → ACM/WAF 조회
            → VPC 선택
              → subnet discovery
                → ALB 생성
                  → Ingress status.address
```

각 단계는 앞 단계가 성공해야 실행된다.

처음에는 잘못된 annotation 때문에 Kubernetes API가 Ingress를 받아들이지 않았다. 이를 제거하자 이번에는 AWS Load Balancer Controller admission webhook의 TLS 문제가 드러났다.

webhook을 복구하고 나니 teardown 이전 ACM certificate와 WAF ACL ARN이 manifest에 남아 있었다. ARN을 현재 AWS resource로 갱신한 뒤 Ingress object는 생성됐지만 `ADDRESS`는 비어 있었다.

controller event와 log를 확인하자 AWS Load Balancer Controller가 이전 VPC ID를 사용하고 있었다. 현재 VPC로 바꾼 뒤에도 public subnet discovery 조건이 충족되지 않아 internet-facing ALB를 만들지 못했다.

마지막으로 public subnet에 cluster discovery tag를 추가하고 controller를 현재 VPC로 재기동하자 external·internal ALB가 생성됐다.

```text
처음:
  Ingress object 자체가 없음

중간:
  Ingress object는 있음
  ADDRESS 없음

마지막:
  Ingress object 있음
  ALB hostname 있음
  ingress-core Synced/Healthy
```

이 사건에서 중요한 것은 오류를 하나 고칠 때마다 새로운 오류가 나타났다는 사실이다.

이는 수정이 장애를 만든 것이 아니다.

```text
앞 단계 실패가 뒤 단계 검증을 가리고 있었음
```

Ingress는 YAML 한 장이 아니다.

```text
Kubernetes schema
admission webhook
controller runtime configuration
AWS IAM
ACM/WAF identity
VPC/subnet topology
subnet tags
backend Service/Pod
DNS
```

이 구성요소가 합성된 결과다.

---

# Step 1. `Missing`은 원인을 설명하지 않는다

## 1.1 Argo CD가 보여 준 상태

```text
Application:
  ingress-core

Sync:
  OutOfSync

Resource:
  Missing
```

`Missing`은 desired resource가 live cluster에 없다는 뜻이다.

그러나 왜 없는지는 설명하지 않는다.

```text
가능한 원인:
  sync를 실행하지 않음
  namespace가 없음
  AppProject 권한 부족
  API validation 실패
  admission webhook 거부
  apply operation 중단
```

## 1.2 Application 전체 상태보다 sync result

진단에서는 다음을 확인했다.

```text
.status.operationState.syncResult.resources[]
.status.conditions[]
.status.resources[]
```

각 Ingress apply message를 분리해야 했다.

```text
Application Missing
  → 어떤 resource가 Missing인가
    → API apply가 왜 실패했는가
```

## 1.3 첫 번째 원인은 AWS가 아니었다

ALB가 없으니 AWS IAM이나 subnet부터 조사하고 싶어진다.

하지만 당시 Ingress object 자체가 API server에 저장되지 않았다.

```text
kubectl get ingress:
  대상 없음
```

이 단계에서는 AWS ALB provisioning이 시작조차 되지 않는다.

---

# Step 2. annotation key가 Kubernetes API 검증을 통과하지 못했다

## 2.1 문제가 된 annotation

Keycloak Ingress에는 다음 형태의 annotation이 있었다.

```yaml
alb.ingress.kubernetes.io/target-health.alb.ingress.k8s.aws/keycloak: "enabled"
```

Kubernetes annotation key 형식:

```text
<optional-dns-prefix>/<name>
```

예:

```text
alb.ingress.kubernetes.io/scheme
```

prefix:

```text
alb.ingress.kubernetes.io
```

name:

```text
scheme
```

## 2.2 왜 invalid인가

문제 key는 slash 뒤 name 부분에 다시 slash를 포함했다.

```text
prefix:
  alb.ingress.kubernetes.io

name:
  target-health.alb.ingress.k8s.aws/keycloak
                                     ^
                                     추가 slash
```

qualified name 규칙에 맞지 않는다.

따라서 AWS Load Balancer Controller가 annotation 의미를 해석하기 전 Kubernetes API validation에서 거부된다.

## 2.3 제거

이 annotation은 유효한 AWS LBC 설정도 아니어서 수정이 아니라 제거했다.

```yaml
# 삭제
alb.ingress.kubernetes.io/target-health.alb.ingress.k8s.aws/keycloak: "enabled"
```

## 2.4 교훈

annotation은 자유 형식 map처럼 보이지만 key와 value 모두 계약이 있다.

```text
Kubernetes:
  key 문법 검증

controller:
  자신이 지원하는 key와 value 해석
```

문법을 통과하는 것과 controller가 의미를 이해하는 것도 별개다.

---

# Step 3. readiness gate를 잘못된 resource에 선언했다

## 3.1 기존 선언

```yaml
elbv2.k8s.aws/pod-readiness-gate-inject: "enabled"
```

이 문자열 자체는 qualified name 형식에 맞는다.

그러나 AWS LBC의 readiness gate injection은 Ingress annotation이 아니라 Namespace label로 사용해야 한다.

## 3.2 올바른 위치

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: edge-service
  labels:
    elbv2.k8s.aws/pod-readiness-gate-inject: "enabled"
```

`auth-namespace`에는 이미 같은 label이 있었다.

```yaml
metadata:
  name: auth-namespace
  labels:
    elbv2.k8s.aws/pod-readiness-gate-inject: "enabled"
```

edge-service namespace manifest를 추가하고 overlay resource에 포함했다.

## 3.3 readiness gate의 역할

target type이 `ip`일 때 AWS LBC는 Pod readiness에 target group 상태를 연결할 수 있다.

```text
Pod process Ready
AND
ALB target health Ready
  → Pod Ready
```

rolling update 중 새 Pod가 ALB target으로 준비되기 전에 기존 Pod가 사라지는 위험을 줄인다.

## 3.4 label 추가만으로 기존 Pod가 바뀌지는 않는다

readiness gate는 Pod admission 시 주입된다.

```text
Namespace label 추가
  → 이후 생성되는 matching Pod에 적용
```

이미 존재하는 Pod spec에 소급 주입되지 않는다. 완전한 검증에는 workload rollout 후 Pod `spec.readinessGates` 확인이 필요하다.

---

# Step 4. AWS Load Balancer Controller webhook TLS

## 4.1 annotation을 고친 뒤 새 실패

manifest 문법이 정상화되자 API request는 admission 단계까지 진행했다.

이때 AWS Load Balancer Controller webhook이 정상 응답하지 못했다.

조사 대상:

```text
ValidatingWebhookConfiguration
MutatingWebhookConfiguration
webhook Service
webhook Endpoints
aws-load-balancer-controller Pods
aws-load-balancer-tls Secret
caBundle
```

## 4.2 재생성 뒤 왜 깨질 수 있는가

webhook TLS는 다음 값이 서로 맞아야 한다.

```text
webhook server certificate
private key
WebhookConfiguration caBundle
Service DNS SAN
```

EKS와 controller를 teardown/redeploy하는 과정에서 다음 조합이 생길 수 있다.

```text
Secret은 과거 인증서
WebhookConfiguration은 새/다른 CA
Pod는 stale Secret mount
```

그러면 API server가 webhook을 신뢰하지 못한다.

## 4.3 복구

실행한 복구:

```text
aws-load-balancer-tls Secret 삭제
controller Pod 재생성
Deployment rollout 대기
새 Secret 확인
webhook caBundle 존재 확인
Service Endpoint 확인
```

개념적인 명령:

```powershell
kubectl delete secret aws-load-balancer-tls `
  -n kube-system

kubectl delete pod `
  -n kube-system `
  -l app.kubernetes.io/name=aws-load-balancer-controller

kubectl rollout status `
  deployment/aws-load-balancer-controller `
  -n kube-system
```

## 4.4 삭제 후 자동 재생성 전제

이 조치는 chart/controller 설치 방식이 TLS Secret을 다시 만들 수 있다는 전제에 의존한다.

운영 runbook에는 삭제 전에 다음을 확인해야 한다.

```text
누가 Secret을 생성하는가
Helm hook/cert generation Job이 재실행되는가
cert-manager가 소유하는가
controller가 자체 생성하는가
```

재생성 주체 없이 Secret만 삭제하면 장애가 악화된다.

---

# Step 5. ACM과 WAF ARN은 재생성 가능한 identity였다

## 5.1 stale ARN

Ingress manifest에는 teardown 이전 resource ARN이 있었다.

과거 ACM:

```text
arn:aws:acm:ap-northeast-2:533003975005:
certificate/ba159581-fb9b-4097-9a49-45a8568fe6da
```

현재 ACM:

```text
arn:aws:acm:ap-northeast-2:533003975005:
certificate/6f155ea4-0e3c-4d7f-a2d4-652d1dfe263b
```

과거 WAF ACL ID:

```text
19272c25-c193-4fee-8d24-c8ebda74014d
```

현재 WAF ACL ID:

```text
13be1902-bae5-4e13-8163-0bf56f2d4aca
```

## 5.2 이름이 같아도 ARN은 다르다

teardown 후 같은 논리 이름으로 resource를 다시 만들 수 있다.

```text
Name:
  prod-ingress-waf

old ARN:
  .../old-id

new ARN:
  .../new-id
```

Git에 old ARN이 남으면 controller는 존재하지 않는 resource를 참조한다.

## 5.3 current value 확인

다음 source를 교차 확인했다.

```text
AWS ACM list/describe
AWS WAFv2 list-web-acls
SSM /localy/prod/apps/acm/cert_arn
Terraform output/state
```

AWS에서 실제 `ISSUED` 상태인 certificate와 현재 WAF ARN으로 manifest를 갱신했다.

## 5.4 하드코딩은 아직 남아 있다

값은 현재 resource로 맞췄지만 구조적으로 완성된 해결은 아니다.

현재 base manifest는 ARN을 문자열로 저장한다.

```yaml
alb.ingress.kubernetes.io/certificate-arn: "<current-arn>"
alb.ingress.kubernetes.io/wafv2-acl-arn: "<current-arn>"
```

다음 teardown/redeploy에서 다시 바뀔 수 있다.

더 나은 구조:

```text
Terraform output/SSM
  → 검증된 render 또는 GitOps PR
    → Ingress manifest 갱신
```

Secret이 아니므로 ESO로 Kubernetes Secret에 옮기는 것만으로 Ingress annotation에 자동 주입되지는 않는다. Kustomize replacement, CI render, Terraform-generated values, config management plugin 등 명시적인 전달 경로가 필요하다.

---

# Step 6. webhook 복구 후에도 ALB는 생기지 않았다

## 6.1 상태 변화

이전:

```text
Ingress object Missing
```

수정 후:

```text
Ingress object 존재
ADDRESS 비어 있음
```

이 변화는 중요하다.

```text
API/admission 계층:
  통과

AWS reconcile 계층:
  실패 중
```

## 6.2 다음 증거는 Ingress event와 controller log

```powershell
kubectl describe ingress <name> -n <namespace>

kubectl logs deployment/aws-load-balancer-controller `
  -n kube-system
```

이 단계부터는 Argo sync message보다 AWS LBC reconcile event가 직접 증거다.

---

# Step 7. controller가 이전 VPC를 보고 있었다

## 7.1 controller runtime args

AWS Load Balancer Controller Deployment의 args를 확인했다.

```text
--cluster-name=prod-eks
--aws-region=ap-northeast-2
--aws-vpc-id=<old-vpc-id>
```

Git values에도 stale VPC ID가 있었다.

## 7.2 현재 VPC

EKS cluster와 SSM에서 현재 값을 확인했다.

```text
/localy/prod/network/vpc_id
  → vpc-014fcff74608cfdbc
```

values 수정:

```yaml
clusterName: "prod-eks"
region: "ap-northeast-2"
vpcId: "vpc-014fcff74608cfdbc"
```

## 7.3 stale VPC가 미치는 영향

controller는 target ALB를 만들 subnet과 security group을 VPC 범위에서 찾는다.

```text
old VPC ID
  → 현재 EKS subnet을 검색하지 못함
  → subnet discovery 실패
  → ALB 미생성
```

Ingress spec이 완벽해도 controller의 cluster topology input이 틀리면 AWS resource는 만들어지지 않는다.

## 7.4 Git 값과 live args를 모두 확인

values file을 수정한 사실만으로 완료가 아니다.

```text
Git values
  → Argo Application
    → Helm render
      → Deployment rollout
        → container args
```

최종적으로 live Deployment args에 현재 VPC ID가 들어갔는지 확인했다.

---

# Step 8. VPC를 고치자 subnet tag 문제가 드러났다

## 8.1 subnet discovery

AWS LBC는 scheme에 따라 적절한 subnet을 찾는다.

internet-facing:

```text
kubernetes.io/role/elb=1
public route/IGW
충분한 가용 영역
```

internal:

```text
kubernetes.io/role/internal-elb=1
private subnet
충분한 가용 영역
```

환경과 controller version/configuration에 따라 cluster ownership tag도 discovery 경계에 사용된다.

```text
kubernetes.io/cluster/prod-eks=shared
```

## 8.2 실제 subnet 상태

private subnet에는 다음이 있었다.

```text
kubernetes.io/role/internal-elb=1
kubernetes.io/cluster/prod-eks=shared
karpenter.sh/discovery=prod-eks
```

public subnet에는:

```text
kubernetes.io/role/elb=1
```

만 있고 cluster tag가 없었다.

## 8.3 live 복구

public subnet 세 개에 다음 tag를 추가했다.

```text
kubernetes.io/cluster/prod-eks=shared
```

그리고 route table이 실제 public route인지 확인했다.

```text
0.0.0.0/0 → Internet Gateway
```

tag 이름만 `public`이라고 해서 실제 public subnet인 것은 아니다. route와 public IP 동작도 함께 확인해야 한다.

## 8.4 중요한 미완료

현재 Terraform network module의 public subnet tags:

```hcl
public_subnet_tags = {
  "kubernetes.io/role/elb" = 1
}
```

private에는 cluster tag가 있지만 public에는 아직 코드화되지 않았다.

```hcl
private_subnet_tags = {
  "kubernetes.io/role/internal-elb"           = 1
  "kubernetes.io/cluster/${var.env_name}-eks" = "shared"
}
```

즉 이번 public subnet cluster tag 수정은 live AWS에는 적용됐지만 Terraform SSOT에는 반영되지 않았다.

다음 재배포에서 재발 가능하다.

필요한 후속 수정:

```hcl
public_subnet_tags = {
  "kubernetes.io/role/elb"                    = 1
  "kubernetes.io/cluster/${var.env_name}-eks" = "shared"
}
```

실제 사용 중인 AWS LBC version의 discovery 규칙과 multi-cluster 공유 정책을 검토한 뒤 반영해야 한다.

---

# Step 9. readiness label과 backend contract

## 9.1 ALB가 생성돼도 backend가 정상이라는 뜻은 아니다

Ingress가 참조한 Service:

```text
auth-namespace/keycloak
edge-service/edge-service
```

확인 항목:

```text
Service 존재
port 일치
EndpointSlice에 Ready endpoint 존재
target-type=ip
Pod security/network policy
health check path
readiness gate
```

## 9.2 Namespace label 추가

`edge-service` Namespace에 readiness gate injection label을 추가했다.

이것은 ALB 생성의 직접 조건이라기보다 안전한 rollout과 target registration 계약이다.

```text
Ingress 생성:
  ALB provisioning

readiness gate:
  Pod가 ALB target으로 준비됐는지 rollout에 반영
```

두 문제를 같은 것으로 혼동하면 안 된다.

---

# Step 10. Argo operation이 과거 실패에 멈춰 있었다

## 10.1 Git을 고쳐도 바로 반영되지 않았다

초기 sync operation은 invalid annotation/webhook 오류로 실패하거나 진행 중 상태에 남아 있었다.

Git의 최신 revision을 hard refresh해도 기존 `.operation`이 남으면 새 sync 요청이 기대대로 진행되지 않을 수 있다.

## 10.2 수행한 조치

```text
stuck operation 제거
hard refresh
latest revision 확인
Ingress server-side apply
Argo sync 재요청
```

수동 apply는 Git desired와 동일한 manifest를 먼저 live에 전달하는 bridge였다.

## 10.3 임시 annotation 정리

reconcile을 자극하기 위해 추가한:

```text
force-reconcile=<timestamp>
kubectl.kubernetes.io/last-applied-configuration
```

을 최종적으로 제거했다.

그렇지 않으면 회고 14와 같은 OutOfSync drift가 다시 남는다.

---

# Step 11. 최종 결과

## 11.1 Kubernetes

```text
세 Ingress object 생성
status.loadBalancer.ingress.hostname 채워짐
backend Service 확인
```

## 11.2 AWS

```text
internet-facing ALB 생성
internal ALB 생성
ACM certificate 연결
WAF ACL 연결
현재 VPC/subnet 사용
```

## 11.3 Argo CD

```text
ingress-core:
  Synced
  Healthy
```

## 11.4 아직 끝이 아니었다

ALB 생성 후 Route 53을 확인하자 `feifo.click`이 internal ALB를 가리키는 별도 문제가 드러났다.

```text
ALB provisioning:
  성공

DNS ownership:
  실패
```

이는 Ingress 생성 계층과 다른 ExternalDNS hostname ownership 문제다. 회고 16에서 분리해 다룬다.

---

# Step 12. 임시방편과 영구 해결

## 12.1 코드에 반영된 것

```text
invalid Ingress annotation 제거
readiness gate를 Namespace label로 이동
edge Namespace manifest 추가
현재 ACM ARN 반영
현재 WAF ARN 반영
현재 VPC ID 반영
internal/external Ingress 구분
```

## 12.2 live에만 반영된 것

```text
public subnet cluster shared tag
webhook TLS Secret 재생성
일시적 server-side apply
stuck operation cleanup
```

webhook TLS는 runtime 복구 행위이므로 runbook 대상이다.

그러나 public subnet tag는 infrastructure desired state이므로 Terraform에 반영돼야 한다.

## 12.3 현재 하드코딩된 재생성 identity

```text
apps/alb-controller/values-prod.yaml:
  vpcId

apps/ingress-core/base/*.yaml:
  certificate ARN
  WAF ACL ARN
```

주석에 “SSM과 맞춰라”라고 써도 자동 정합성이 생기지 않는다.

```text
문서화된 수동 동기화
≠ SSOT 자동 전달
```

## 12.4 사용되지 않는 stale overlay file

`apps/ingress-core/overlays/prod/patch-ingress.yaml`에는 과거 ACM·WAF ARN이 남아 있다.

현재 `kustomization.yaml`은 이 patch를 참조하지 않는다.

```yaml
resources:
  - ../../base
```

따라서 현재 render에는 영향이 없다.

하지만 파일명이 prod patch이고 값이 stale이므로 미래에 누군가 다시 연결하면 장애가 재발한다.

선택:

```text
파일 삭제
또는 현재 값/동적 생성 경로로 갱신
또는 명확히 archived 표기
```

이 cleanup은 아직 남아 있다.

---

# Step 13. 더 나은 아키텍처

## 13.1 재생성 identity 전달

목표:

```text
Terraform creates:
  VPC
  ACM certificate
  WAF ACL

Terraform publishes:
  SSM parameters / outputs

GitOps render consumes:
  검증된 current values
```

가능한 방식:

```text
CI가 Terraform/SSM 값을 읽어 manifests PR 생성
Kustomize replacement용 generated ConfigMap
ApplicationSet/plugin으로 environment values 생성
Terraform이 별도 values artifact를 생성
```

중요한 것은 Git과 live AWS 사이에 사람의 복사 작업만 남기지 않는 것이다.

## 13.2 ALB controller VPC auto-discovery

환경에 따라 `vpcId`를 생략하고 controller가 instance metadata 또는 AWS API로 찾게 할 수 있다.

그러나 다음을 검증해야 한다.

```text
controller Pod에서 IMDS 접근 가능
IMDSv2 hop limit
여러 VPC ambiguity 없음
IRSA/AWS API 권한
managed node와 Fargate 차이
```

명시적 VPC ID는 deterministic하지만 갱신 공급망이 필요하다.

## 13.3 subnet tag Terraform gate

CI 또는 Terraform test:

```text
public subnet:
  role/elb=1
  cluster tag policy 충족
  IGW route

private subnet:
  role/internal-elb=1
  cluster tag policy 충족
  NAT/private route

각 scheme:
  서로 다른 AZ 최소 2개
```

## 13.4 webhook certificate lifecycle

```text
설치/upgrade:
  cert generation owner 명확

검증:
  Secret 존재
  certificate SAN
  caBundle 일치
  Service Endpoint 존재

복구:
  chart별 지원 절차로 rotation
```

Secret 삭제·Pod restart만을 보편적 해결책으로 문서화하면 안 된다.

---

# Step 14. 진단 순서

## 14.1 계층 1 — manifest render

```text
[ ] kustomize build 성공
[ ] namespace/name 확인
[ ] annotation key 문법 확인
[ ] overlay가 실제로 포함되는지 확인
[ ] stale patch 중복 확인
```

## 14.2 계층 2 — API/admission

```text
[ ] server-side dry-run 성공
[ ] webhook Service/Endpoint 존재
[ ] TLS Secret/caBundle 정상
[ ] webhook timeout/denied 없음
```

개념적 명령:

```powershell
kubectl apply --dry-run=server -f <ingress.yaml>
```

## 14.3 계층 3 — Kubernetes object

```text
[ ] Ingress object 존재
[ ] ingressClassName=alb
[ ] backend Service/port 존재
[ ] event에 model build 오류 없음
```

## 14.4 계층 4 — controller

```text
[ ] AWS LBC Pod Ready
[ ] clusterName/region/vpcId 현재 값
[ ] IRSA role 정상
[ ] reconcile log 확인
```

## 14.5 계층 5 — AWS dependency

```text
[ ] ACM certificate 존재·ISSUED
[ ] hostname이 certificate SAN에 포함
[ ] WAF ACL 존재·REGIONAL
[ ] VPC ID 현재 EKS와 일치
[ ] subnet role/cluster tag
[ ] route table과 AZ 수
```

## 14.6 계층 6 — data plane

```text
[ ] ALB state=active
[ ] listener 80/443
[ ] target group target healthy
[ ] security group path
[ ] backend response
```

## 14.7 계층 7 — DNS

```text
[ ] public hostname owner 하나
[ ] Route 53 alias가 external ALB
[ ] internal hostname 분리
[ ] HTTPS redirect/login smoke
```

DNS는 회고 16의 별도 ownership 계층이다.

---

# Step 15. 재배포 전 Gate

```text
[ ] Terraform public/private subnet tags 검증
[ ] SSM VPC ID == EKS VPC ID
[ ] ALB controller live arg == SSM VPC ID
[ ] ACM ARN == 현재 ISSUED certificate
[ ] WAF ARN == 현재 REGIONAL ACL
[ ] Ingress server dry-run 통과
[ ] webhook TLS/Endpoint 정상
[ ] backend Namespace readiness label
[ ] stale overlay patch 없음
[ ] external/internal hostname 유일
```

이 gate를 Argo sync 전에 실행하면 연쇄 장애를 앞에서 끊을 수 있다.

---

## 최종 원인 트리

```text
ingress-core OutOfSync / Missing
│
├─ Kubernetes API validation
│  └─ annotation name에 추가 slash
│     └─ Ingress object 저장 실패
│
├─ admission webhook
│  ├─ AWS LBC webhook TLS Secret/CA 이상
│  └─ API server가 webhook을 신뢰·호출하지 못함
│
├─ manifest semantics
│  ├─ readiness injection을 Ingress annotation으로 선언
│  └─ 실제 계약은 Namespace label
│
├─ AWS resource identity
│  ├─ stale ACM certificate ARN
│  └─ stale WAFv2 ACL ARN
│
├─ controller topology
│  └─ stale VPC ID
│     └─ 현재 EKS subnet 검색 실패
│
├─ network discovery
│  ├─ public subnet role/elb tag 존재
│  ├─ public subnet cluster tag 누락
│  └─ live tag 추가 후 ALB discovery 성공
│
├─ operation state
│  ├─ 과거 Argo sync operation 잔존
│  └─ hard refresh/operation cleanup/재sync
│
├─ 결과
│  ├─ external ALB 생성
│  ├─ internal ALB 생성
│  └─ ingress-core Synced/Healthy
│
└─ 남은 부채
   ├─ public subnet cluster tag Terraform 미반영
   ├─ VPC/ACM/WAF Git 하드코딩
   ├─ unused stale patch-ingress.yaml
   ├─ webhook rotation runbook 보강
   └─ DNS hostname 충돌은 회고 16
```

## 한 문장으로 남기는 교훈

**Ingress는 YAML 한 장이 아니라 API validation부터 webhook, controller configuration, AWS identity, VPC와 subnet까지 이어지는 dependency graph이며, `Missing` 하나를 고치려면 가장 앞 계층부터 순서대로 증거를 확인해야 한다.**
