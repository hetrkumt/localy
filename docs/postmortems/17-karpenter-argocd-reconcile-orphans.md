# 리소스는 있는데 Missing이었다

> Karpenter NodePool의 실제 상태와 Argo CD status cache가 어긋나고, `kube-system` 전체가 orphan 경고로 잡힌 사건

## 문서 정보

- 사건 시각: 2026-07-31 22:58~23:05 KST
- 환경: Argo CD, Karpenter 0.37.0, Server-Side Apply, Amazon EKS
- 대상 Application:
  - `karpenter-controller`
  - `karpenter-provisioner`
- 대상 리소스:
  - NodePool `system`
  - NodePool `observability`
  - NodePool `workload`
  - NodePool `finops-batch`
  - EC2NodeClass `default`
- 최초 모순:
  - `kubectl get nodepool`에는 리소스가 존재하고 작동
  - Argo CD에는 `OutOfSync / Missing`
- 동시 증상: `platform-project`에 `OrphanedResourceWarning` 140개 이상
- 직접 원인:
  - Karpenter/API가 쓰는 status·hash·default field와 Git desired 간 diff
  - AppProject orphan 평가가 shared `kube-system`의 미추적 리소스까지 포함
  - Argo application-controller가 nil-pointer 이후 reconcile을 갱신하지 못함
- 진단 결정 증거:
  - live CR 존재
  - Argo `status.reconciledAt`가 수 시간 전
  - hard refresh·ignore 확대 후에도 표시 불변
  - application-controller log의 nil-pointer 오류
- 복구:
  - Karpenter API default를 Git에 명시
  - `ignoreDifferences` 확대
  - destination namespace를 `karpenter`로 변경
  - `platform-project.orphanedResources.warn=false`
  - Argo application-controller Pod 재시작
- 결과:
  - `karpenter-controller` `Synced / Healthy`
  - `karpenter-provisioner` `Synced / Healthy`
  - orphan warning condition 제거
- 주요 commit:
  - `1940f5d` — NodePool disruption budget default 정렬
  - `47afb1b` — EC2NodeClass IPv6 metadata default 정렬
  - `6c2bd2c` — provisioner sync·orphan noise 정리
- 남은 부채:
  - metadata label·annotation 전체 ignore 범위가 넓음
  - platform-project 전체 orphan warning 비활성화는 실제 orphan도 숨길 수 있음
  - application-controller nil-pointer의 제품 버그·재현 조건은 근본 수정하지 않음

---

## Executive Summary

Karpenter는 실제 cluster에서 정상적으로 node를 공급하고 있었다.

```text
NodePool:
  system
  observability
  workload
  finops-batch

EC2NodeClass:
  default

Node:
  Ready
```

그런데 Argo CD의 `karpenter-provisioner` Application은 일부 리소스를 `Missing` 또는 `OutOfSync`로 표시했다.

```text
kubectl:
  resource exists

Argo:
  resource Missing
```

동시에 `platform-project`에는 140개가 넘는 orphan warning이 있었다. 대부분은 `kube-system`에 있는 Kubernetes·EKS·여러 platform controller의 리소스로, Karpenter Application이 삭제해야 할 대상이 아니었다.

처음에는 Karpenter가 live object에 추가하는 field를 조사했다.

```text
NodePool:
  status
  hash annotation
  disruption.budgets default

EC2NodeClass:
  status
  hash annotation
  metadataOptions.httpProtocolIPv6 default

API server:
  managedFields
  generation
  resourceVersion
  uid
```

default는 Git에 명시하고 runtime field는 `ignoreDifferences`로 제외했다.

그러나 Application 상태가 바뀌지 않았다.

결정적인 단서는 `status.reconciledAt`이었다.

```text
현재 시각:
  22:xx

reconciledAt:
  수 시간 전
```

hard refresh와 sync를 요청해도 시각이 갱신되지 않았고 application-controller에는 nil-pointer 오류가 있었다.

즉 마지막 단계의 문제는 desired/live diff가 아니었다.

```text
관측 대상:
  이미 정상에 가까움

관측기:
  과거 계산 결과에서 정체
```

AppProject의 orphan warning 범위와 Application destination을 정리한 뒤 Argo application-controller Pod를 재시작했다. controller가 Application을 새로 reconcile하자 Karpenter CR은 모두 `Synced`로 재평가됐다.

핵심 교훈:

> 제어면의 상태가 live API와 모순될 때는 workload를 반복 수정하기 전에 상태를 계산한 controller가 최근에 reconcile했는지 확인해야 한다.

---

# Step 1. 두 개의 Karpenter controller를 구분해야 한다

## 1.1 Karpenter controller

역할:

```text
NodePool 읽기
NodeClaim 생성
EC2 provisioning
node lifecycle 관리
```

Application:

```text
karpenter-controller
```

## 1.2 Argo CD application-controller

역할:

```text
Git desired state 계산
live resource 조회
diff 계산
Application sync/health status 기록
sync operation 수행
```

Pod:

```text
argocd-application-controller-0
```

## 1.3 이번 장애

Karpenter controller 자체가 node provisioning에 실패한 사건이 아니다.

```text
Karpenter data plane:
  작동

Argo observation/reconcile:
  정체
```

이름이 비슷해 잘못된 controller를 재시작하거나 조사할 위험이 있다.

---

# Step 2. 실제 cluster 상태를 먼저 확인하다

## 2.1 live CR inventory

```powershell
kubectl get nodepool
kubectl get ec2nodeclass
```

확인 결과 네 NodePool과 EC2NodeClass가 존재했다.

## 2.2 API version

다음도 확인했다.

```text
live apiVersion
CRD served version
CRD storage version
```

목적:

```text
Git은 v1beta1인데 cluster storage가 다른가
conversion webhook이 object를 다른 schema로 바꾸는가
동일 name의 legacy CR이 있는가
```

당시 리소스 종류와 API version 자체가 Missing의 원인은 아니었다.

## 2.3 Argo tracking

확인 대상:

```text
argocd.argoproj.io/tracking-id
instance label/annotation
Application source path
destination namespace
live root path
```

repository에는 legacy `argocd-apps` 경로와 새 `gitops` 경로가 함께 있었기 때문에 어떤 root가 실제 Application을 만들고 있는지 확인해야 했다.

---

# Step 3. 먼저 실제 diff를 줄였다

## 3.1 NodePool disruption budget

Karpenter/API는 생략된 budget을 live spec에 채웠다.

```yaml
spec:
  disruption:
    budgets:
      - nodes: "10%"
```

Git에 없고 live에만 있으면 Argo diff가 발생할 수 있다.

commit:

```text
1940f5d
fix(karpenter): pin disruption budgets to clear Argo Diff
```

네 NodePool에 default를 명시했다.

## 3.2 EC2NodeClass metadata default

live object에는 다음이 있었다.

```yaml
spec:
  metadataOptions:
    httpProtocolIPv6: disabled
```

Git에는 생략돼 있었다.

commit:

```text
47afb1b
fix(karpenter): align EC2NodeClass IPv6 default for Argo sync
```

Git에 `disabled`를 명시했다.

## 3.3 default를 명시한 이유

default를 무조건 ignore할 수도 있다.

하지만 security/runtime 의미가 있는 값은 Git에 명시하는 편이 낫다.

```text
httpTokens: required
httpPutResponseHopLimit: 1
httpEndpoint: enabled
httpProtocolIPv6: disabled
```

이렇게 하면 API default가 version에 따라 바뀌어도 운영 의도를 유지할 수 있다.

---

# Step 4. Karpenter가 정상적으로 바꾸는 field

## 4.1 status

Karpenter는 다음 상태를 기록한다.

```text
NodePool:
  conditions
  resources
  observed generation

EC2NodeClass:
  AMI
  subnet/security group resolution
  readiness conditions
```

Git이 소유할 field가 아니다.

## 4.2 hash annotation

Karpenter는 spec 변화와 drift를 추적하기 위한 hash annotation을 기록한다.

예:

```text
karpenter.sh/nodepool-hash
karpenter.sh/nodepool-hash-version
karpenter.k8s.aws/ec2nodeclass-hash
karpenter.k8s.aws/ec2nodeclass-hash-version
```

controller-owned runtime metadata다.

## 4.3 API metadata

```text
managedFields
generation
resourceVersion
creationTimestamp
uid
```

Kubernetes API server가 관리한다.

## 4.4 ignore 설정

NodePool:

```yaml
jqPathExpressions:
  - .status
  - .metadata.annotations
  - .metadata.labels
  - .metadata.managedFields
  - .metadata.generation
  - .metadata.resourceVersion
  - .metadata.creationTimestamp
  - .metadata.uid
  - .spec.disruption.budgets
```

EC2NodeClass:

```yaml
jqPathExpressions:
  - .status
  - .metadata.annotations
  - .metadata.labels
  - .metadata.managedFields
  - .metadata.generation
  - .metadata.resourceVersion
  - .metadata.creationTimestamp
  - .metadata.uid
  - .spec.metadataOptions.httpProtocolIPv6
```

그리고:

```yaml
syncOptions:
  - RespectIgnoreDifferences=true
```

를 적용했다.

---

# Step 5. 현재 ignore rule은 과도하게 넓다

## 5.1 annotations 전체

```yaml
- .metadata.annotations
```

Karpenter hash뿐 아니라 모든 annotation drift를 숨긴다.

숨길 수 있는 것:

```text
Argo tracking annotation
보안/정책 annotation
운영자 annotation
잘못된 controller annotation
```

## 5.2 labels 전체

```yaml
- .metadata.labels
```

숨길 수 있는 것:

```text
cost-center
ownership
environment
policy selector
application tracking
```

특히 NodePool label은 scheduling·FinOps 정책에 의미가 있을 수 있다.

## 5.3 immutable API metadata

`uid`, `creationTimestamp`, `resourceVersion` 등은 보통 Argo가 diff 정규화 과정에서 자연스럽게 처리한다. 이들을 명시적으로 ignore하는 것은 증상을 줄이기 위해 범위를 넓힌 흔적이며 최소 정책이라고 보기 어렵다.

## 5.4 더 안전한 형태

```yaml
jqPathExpressions:
  - .status
  - .metadata.annotations["karpenter.sh/nodepool-hash"]
  - .metadata.annotations["karpenter.sh/nodepool-hash-version"]
```

EC2NodeClass도 Karpenter hash key만 지정한다.

API default는 가능하면 Git에 명시한다.

따라서 현재 Synced 상태는 얻었지만 ignore policy 축소 작업이 남아 있다.

---

# Step 6. orphan warning 140개는 어디서 왔는가

## 6.1 Argo의 orphan 의미

AppProject orphan monitoring은 destination namespace에 존재하지만 해당 project의 Application이 추적하지 않는 resource를 찾는다.

```text
resource exists
AND
project Application tracking에 없음
  → orphan 후보
```

이는 반드시 불필요하거나 삭제 가능한 resource라는 뜻은 아니다.

## 6.2 `kube-system`은 shared namespace

`kube-system`에는 많은 주체가 resource를 만든다.

```text
Kubernetes/EKS 기본 addon
CoreDNS
kube-proxy
VPC CNI
AWS Load Balancer Controller
ExternalDNS
Karpenter
metrics/observability addon
Helm hook/generated resource
```

하나의 platform AppProject가 이 namespace를 광범위하게 destination으로 사용하면서:

```yaml
orphanedResources:
  warn: true
```

를 켜자 project가 추적하지 않는 140여 개 resource가 warning 대상이 됐다.

## 6.3 “false positive”의 정확한 의미

Argo 입장에서는 추적되지 않은 resource라는 판정이 맞을 수 있다.

하지만 운영 관점에서는:

```text
Karpenter가 소유하지 않음
다른 addon/EKS가 소유
삭제하면 안 됨
현재 Application 조치 대상이 아님
```

이므로 Karpenter incident에 비실행 가능한 noise였다.

따라서 엄밀히는:

```text
Argo 탐지 오류
```

라기보다:

```text
AppProject scope가 너무 넓어 경고의 의미가 약해짐
```

에 가깝다.

---

# Step 7. cluster-scoped resource와 destination namespace

## 7.1 NodePool과 EC2NodeClass

이 리소스들은 cluster-scoped다.

```text
metadata.namespace 없음
```

## 7.2 Application destination

기존:

```yaml
destination:
  namespace: kube-system
```

변경:

```yaml
destination:
  namespace: karpenter
```

## 7.3 무엇이 바뀌고 무엇은 안 바뀌는가

바뀌지 않는 것:

```text
NodePool/EC2NodeClass의 실제 Kubernetes scope
리소스에 namespace가 생기는 것 아님
```

바뀌는 것:

```text
Application의 administrative destination
namespace가 생략된 namespaced companion resource의 기본 위치
Argo의 destination/orphan 문맥
```

즉 이 변경은 cluster-scoped CR을 `karpenter` namespace 안으로 옮긴 것이 아니다.

## 7.4 목적

Karpenter provisioner Application을 shared system namespace와 논리적으로 분리해 orphan 평가와 운영 가독성을 개선했다.

```text
controller workload:
  kube-system

provisioning CR Application destination:
  karpenter
```

다만 AppProject 안의 다른 Application이 계속 `kube-system`을 사용하므로 destination 변경 하나만으로 project 전체 orphan noise가 사라지는 것은 아니다.

---

# Step 8. orphan warning을 껐다

## 8.1 변경

```yaml
orphanedResources:
  warn: false
```

commit:

```text
6c2bd2c
fix(karpenter): clear provisioner OutOfSync and kube-system orphan noise
```

## 8.2 이 설정이 하지 않는 것

```text
resource 삭제 안 함
prune 활성화 안 함
resource ownership 변경 안 함
Karpenter 동작 변경 안 함
```

warning condition을 억제한다.

Application의:

```text
prune=false
Delete=false
Prune=false
```

정책도 유지됐다.

## 8.3 coarse suppression의 위험

platform-project 전체에서 warning을 끄면 실제 orphan도 경고되지 않는다.

예:

```text
과거 chart에서 남은 ClusterRole
삭제된 addon의 Service
stale webhook configuration
orphan Secret
```

회고 15의 stale webhook, 회고 14의 Reloader PDB처럼 실제 cleanup 대상이 숨어도 UI warning이 없다.

## 8.4 더 나은 대안

```text
shared kube-system 전용 project와 owned namespace project 분리
addon별 dedicated namespace
AppProject orphan ignore를 group/kind/name으로 제한
별도 scheduled orphan inventory
managed-by/owner label 정책
```

warning 전체 비활성화는 당시 noise를 줄인 응급 운영 결정이지 이상적인 최종 정책은 아니다.

---

# Step 9. diff를 고쳐도 상태가 변하지 않았다

## 9.1 기대

```text
Git default 정렬
ignoreDifferences 적용
hard refresh
sync
  → Synced
```

## 9.2 실제

```text
live NodePool은 존재
Git revision은 최신
ignore rule도 Application spec에 있음
하지만 status는 여전히 Missing/OutOfSync
```

## 9.3 반복 수정의 위험

이 상황에서 manifest를 계속 넓게 ignore하면:

```text
실제 원인과 무관한 field까지 숨김
tracking metadata를 가림
향후 drift 탐지 약화
```

현재 rule이 metadata 전체로 넓어진 이유도 이 진단 과정과 연결된다.

상태가 재계산되지 않는다면 diff rule을 더 바꿔도 효과가 없다.

---

# Step 10. `reconciledAt`가 결정적인 증거였다

## 10.1 Application status

확인:

```powershell
kubectl get application karpenter-provisioner `
  -n argocd `
  -o jsonpath='{.status.reconciledAt}'
```

값이 현재 시각보다 수 시간 뒤처져 있었다.

## 10.2 의미

`status.reconciledAt`는 application-controller가 마지막으로 desired/live 비교를 완료한 시각의 단서다.

```text
Git push:
  최신

live resource:
  최신

Application status:
  과거 reconcile 결과
```

이 경우 Argo UI의 Missing은 현재 API 사실이 아니라 stale observation일 수 있다.

## 10.3 hard refresh가 충분하지 않았음

다음을 요청했다.

```text
argocd.argoproj.io/refresh=hard
sync operation
root refresh
```

그러나 reconcile timestamp와 status가 갱신되지 않았다.

refresh 요청이 controller에 의해 처리돼야 효과가 있는데 controller loop 자체가 정체돼 있었다.

---

# Step 11. nil-pointer와 reconcile 정체

## 11.1 application-controller 오류

application-controller가 Karpenter Application을 처리하는 과정에서 nil-pointer 오류를 남겼다.

그 뒤 Application의 상태 계산이 정상적으로 완료되지 않았다.

```text
reconcile 시작
  → 내부 오류/panic
    → status update 미완료
      → 이전 Missing/OutOfSync 표시 유지
```

## 11.2 왜 resource에는 영향이 적었는가

NodePool과 EC2NodeClass는 이미 Kubernetes API에 존재했다.

Karpenter controller는 이 CR을 읽어 계속 동작했다.

```text
Argo application-controller 실패:
  GitOps 관측·sync 제어면 영향

Karpenter controller:
  existing CR 기반 provisioning 지속
```

따라서 node가 정상인 것과 Argo status가 stale인 것이 동시에 가능했다.

## 11.3 원인과 복구를 구분

Pod 재시작은 정체를 해소했다.

하지만 nil-pointer가 발생한 제품 코드 경로, Argo version, Multi-Source/SSA 조합의 근본 버그를 수정한 것은 아니다.

```text
복구:
  controller process/cache 재구성

근본 수정:
  bug 재현
  stack trace 보존
  version upgrade/patch 검증
```

후자는 남아 있다.

---

# Step 12. application-controller 재시작

## 12.1 실행 전 조건

다음을 먼저 확인했다.

```text
live Karpenter CR 정상
Git desired 최신
Application spec 최신
ignore policy 반영
hard refresh 무응답
reconciledAt stale
controller error 존재
```

## 12.2 실행

```powershell
kubectl delete pod argocd-application-controller-0 `
  -n argocd

kubectl rollout status `
  statefulset/argocd-application-controller `
  -n argocd
```

새 Pod가 준비된 뒤 hard refresh와 sync를 다시 요청했다.

## 12.3 왜 첫 조치로 하면 안 되는가

controller 재시작은 증거를 지우고 다른 Application reconcile에도 영향을 줄 수 있다.

먼저 재시작하면:

```text
원인 stack trace 유실
실제 manifest diff 미확인
일시적 회복을 근본 해결로 오판
동시에 진행 중인 sync operation 영향
```

따라서 stale timestamp와 controller 오류가 확인된 뒤 사용해야 한다.

---

# Step 13. 캐시가 다시 계산된 뒤 결과

## 13.1 Karpenter Applications

```text
karpenter-controller:
  Synced
  Healthy

karpenter-provisioner:
  Synced
  Healthy
```

## 13.2 resource

```text
NodePool/system:
  Synced

NodePool/observability:
  Synced

NodePool/workload:
  Synced

NodePool/finops-batch:
  Synced

EC2NodeClass/default:
  Synced
```

## 13.3 orphan

```text
platform-project:
  orphan warning condition 없음
```

이는 orphan resource가 물리적으로 0개라는 뜻이 아니다. warning을 끄고 scope noise를 제거한 결과다.

## 13.4 범위 밖 잔여

`root-app-of-apps`에는 child `gateway-service` Application path drift가 남아 있었다.

Karpenter target이 정상화됐다고 root 전체 문제까지 해결됐다고 과장하지 않고 별도 범위로 남겼다.

---

# Step 14. 세 종류의 문제를 분리해야 했다

## 14.1 실제 desired/live diff

```text
NodePool disruption budget
EC2NodeClass httpProtocolIPv6
Karpenter hash/status metadata
```

조치:

```text
default 명시
좁은 ignore
```

## 14.2 orphan scope noise

```text
shared kube-system
project가 추적하지 않는 140+ resource
```

조치:

```text
project/namespace scope 재설계
당시에는 warning suppression
```

## 14.3 stale observer

```text
live exists
Argo says Missing
reconciledAt stale
nil-pointer
```

조치:

```text
application-controller 복구
```

이 세 문제에 같은 해결책을 적용할 수 없다.

---

# Step 15. 진단 의사결정 트리

```text
Argo가 Missing이라고 표시
│
├─ kubectl에서도 없음
│  ├─ sync 미실행?
│  ├─ API/admission 실패?
│  ├─ namespace/RBAC?
│  └─ 실제 Missing 조사
│
└─ kubectl에는 있음
   ├─ GVK/name/namespace 일치?
   ├─ tracking-id 일치?
   ├─ Application source/path 최신?
   ├─ destination/cluster 일치?
   ├─ status.reconciledAt 최신?
   │
   ├─ 최신
   │  └─ diff/tracking/cache normalization 조사
   │
   └─ stale
      ├─ refresh annotation 처리 여부
      ├─ application-controller logs
      ├─ queue/operation 상태
      └─ 증거 보존 후 controller 복구
```

---

# Step 16. 더 나은 orphan 정책

## 16.1 project를 책임 경계로 분리

현재 `platform-project`는:

```text
source repo wildcard 포함
destination namespace wildcard
cluster resource wildcard
namespace resource wildcard
```

운영 범위가 매우 넓다.

개선:

```text
system-addons-project:
  kube-system
  orphan warning 제한/ignore 명시

karpenter-project:
  karpenter namespace
  NodePool/EC2NodeClass

observability-project:
  monitoring/loki

security-project:
  cert-manager/kyverno/ESO
```

## 16.2 ignore list를 구체화

AppProject가 지원하는 orphan ignore 규칙으로 EKS 기본 resource 또는 알려진 generated kind만 제외할 수 있다.

```text
group
kind
name pattern
```

지원 문법은 사용 중인 Argo CD version에서 확인해야 한다.

## 16.3 별도 inventory

UI warning을 끄더라도 정기적으로 다음을 점검한다.

```text
tracking metadata 없는 resource
ownerReference 없는 namespaced resource
삭제된 Helm release의 잔재
stale webhook/ClusterRole/PDB/Secret
생성 시각이 오래된 unknown owner
```

warning suppression이 orphan 관리의 종료가 되어서는 안 된다.

---

# Step 17. 더 나은 ignore policy

## 17.1 controller-owned key만

NodePool:

```yaml
jqPathExpressions:
  - .status
  - .metadata.annotations["karpenter.sh/nodepool-hash"]
  - .metadata.annotations["karpenter.sh/nodepool-hash-version"]
```

EC2NodeClass:

```yaml
jqPathExpressions:
  - .status
  - .metadata.annotations["karpenter.k8s.aws/ec2nodeclass-hash"]
  - .metadata.annotations["karpenter.k8s.aws/ec2nodeclass-hash-version"]
```

## 17.2 default는 desired에 명시

```text
disruption budget
metadata options
```

처럼 운영 의미가 있는 default는 Git에 남긴다.

## 17.3 managedFields는 진단에 사용

`.metadata.managedFields`는 diff 대상에서 제외할 수 있지만 먼저 manager별 field ownership을 분석하는 증거로 사용해야 한다.

```text
argocd-controller
karpenter
kubectl
```

수동 `--force-conflicts`가 Argo field ownership을 가져갔는지도 확인한다.

---

# Step 18. application-controller 운영 Runbook

## 18.1 재시작 전

```text
[ ] Application YAML/status 저장
[ ] controller log와 stack trace 저장
[ ] reconciledAt 기록
[ ] current Git revision 기록
[ ] operationState 기록
[ ] live resource inventory 저장
[ ] 다른 진행 중 sync 확인
```

## 18.2 재시작 판단

```text
hard refresh가 처리되지 않음
reconciledAt가 충분히 오래됨
controller error/panic 존재
repo-server/API connectivity는 정상
live resource와 status가 명백히 모순
```

## 18.3 재시작 후

```text
[ ] StatefulSet Ready
[ ] reconcile timestamp 갱신
[ ] Application revision 최신
[ ] resource별 sync 재평가
[ ] operation 정상 종료
[ ] controller error 재발 여부
[ ] 다른 Application 영향 확인
```

## 18.4 근본 후속

```text
Argo CD version 확인
nil-pointer stack trace 분류
known issue 검색
upgrade release note 검토
staging에서 재현
Multi-Source/SSA 조합 test
```

---

# Step 19. 재발 방지 Gate

```text
[ ] NodePool/EC2NodeClass API default Git 명시
[ ] Karpenter hash key만 ignore
[ ] metadata 전체 ignore 금지
[ ] Application destination dedicated namespace
[ ] shared kube-system orphan 정책 문서화
[ ] orphan warning off 시 별도 inventory
[ ] reconciledAt freshness alert
[ ] application-controller panic alert
[ ] refresh annotation 장기 잔존 검사
[ ] root/child Application drift 분리
```

특히 `reconciledAt` freshness는 UI의 녹색/빨간색보다 먼저 제어면 정체를 알려줄 수 있다.

---

## 최종 원인 트리

```text
Karpenter CR은 있는데 Argo에서 Missing/OutOfSync
│
├─ 실제 diff
│  ├─ NodePool disruption.budgets API default
│  ├─ EC2NodeClass httpProtocolIPv6 API default
│  ├─ Karpenter hash annotations
│  ├─ status
│  └─ SSA managed fields
│
├─ orphan warning 140+
│  ├─ platform-project orphan warn=true
│  ├─ shared kube-system destination
│  ├─ EKS·Kubernetes·여러 addon resource 혼재
│  └─ 탐지는 맞지만 Karpenter 조치에는 비실행 가능한 noise
│
├─ reconcile 정체
│  ├─ live resource 존재
│  ├─ Argo status는 Missing
│  ├─ reconciledAt 수 시간 전
│  ├─ hard refresh 무응답
│  └─ application-controller nil-pointer
│
├─ 복구
│  ├─ API default Git 명시
│  ├─ ignoreDifferences 확대
│  ├─ destination=karpenter
│  ├─ orphan warning 비활성화
│  ├─ application-controller 재시작
│  └─ 새 reconcile/sync
│
├─ 결과
│  ├─ karpenter-controller Synced/Healthy
│  ├─ karpenter-provisioner Synced/Healthy
│  └─ orphan warning condition 제거
│
└─ 남은 부채
   ├─ annotation/label 전체 ignore
   ├─ project 전체 orphan warning off
   ├─ nil-pointer 근본 원인 미수정
   ├─ reconciledAt freshness monitoring 없음
   └─ shared kube-system ownership 모델 미분리
```

## 한 문장으로 남기는 교훈

**live API와 Argo CD status가 모순될 때는 리소스를 반복 수정하기 전에 `reconciledAt`과 application-controller 오류를 확인해야 하며, orphan 경고는 resource의 존재가 아니라 project의 책임 범위가 올바른지를 먼저 물어야 한다.**
