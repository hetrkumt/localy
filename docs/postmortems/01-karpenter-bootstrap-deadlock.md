# 클러스터는 살아 있는데 Pod는 뜨지 않았다

> Karpenter 부트스트랩의 닭과 달걀, 그리고 `Pending`을 증거로 읽는 법

## 문서 정보

- 사건 시각: 2026-07-30 22:33~23:09 KST
- 환경: Amazon EKS 1.30, Karpenter 0.37.0, Argo CD Multi-Source GitOps
- 영향 범위: Karpenter, External Secrets Operator, KEDA 및 워크로드·관측성 Pod
- 직접 원인: 부트스트랩 Pod가 Managed Node Group에 없는 `karpenter.sh/nodepool=system` 라벨을 요구
- 구조적 원인: 새 노드를 만드는 컨트롤러가 자신이 만든 노드의 라벨에 의존
- 복구 방식: 부트스트랩 컨트롤러를 `role=system` Managed Node Group에 배치
- 최종 상태: Karpenter 2개 replica와 ESO가 Running으로 전환

---

## Executive Summary

EKS 클러스터를 재구축한 뒤 control plane과 3대의 system node는 정상적으로 존재했다. 하지만 Keycloak, OTel Gateway, External Secrets Operator(ESO), Karpenter 등 여러 Pod가 한꺼번에 `Pending`에 머물렀다.

처음에는 `t3.medium` system node의 CPU나 메모리가 부족한 것처럼 보였다. 그러나 스케줄러가 남긴 이벤트에는 `Insufficient cpu`나 `Insufficient memory`가 없었다.

```text
0/3 nodes are available:
3 node(s) didn't match Pod's node affinity/selector.
preemption: 0/3 nodes are available:
3 Preemption is not helpful for scheduling.
```

실제 원인은 용량이 아니라 **라벨 계약의 불일치**였다.

```text
Managed Node Group:
  role=system
  karpenter.sh/nodepool 없음

Karpenter / ESO Pod:
  karpenter.sh/nodepool=system 필요
```

더 심각한 문제는 Karpenter 자신도 이 조건 때문에 실행되지 못했다는 것이다. Karpenter가 실행되어야 `karpenter.sh/nodepool` 라벨을 가진 노드를 만들 수 있는데, Karpenter는 그 라벨을 가진 노드가 있어야 실행될 수 있었다.

```text
Karpenter가 실행되어야 Karpenter 노드를 생성
          ↑                         ↓
          └── Karpenter 노드가 있어야 Karpenter 실행
```

Karpenter Pod에는 차트가 생성한 다음 node affinity도 함께 있었다.

```yaml
matchExpressions:
  - key: karpenter.sh/nodepool
    operator: DoesNotExist
```

동시에 사용자 values는 다음 조건을 추가하고 있었다.

```yaml
nodeSelector:
  karpenter.sh/nodepool: system
```

하나는 해당 라벨이 **없어야 한다**고 요구하고, 다른 하나는 해당 라벨의 값이 **system이어야 한다**고 요구했다. 같은 Pod 안에 서로 양립할 수 없는 조건이 존재했던 것이다.

해결은 기존 노드에 Karpenter 라벨을 임시로 위조하는 것이 아니었다. Karpenter, ESO, KEDA처럼 클러스터를 부트스트랩하는 컨트롤러는 Terraform이 먼저 만든 Managed Node Group의 `role=system`을 사용하도록 Git values를 수정했다. Karpenter가 정상화된 이후에만 일반 워크로드와 관측성 Pod가 Karpenter NodePool을 사용하도록 경계를 다시 세웠다.

---

# Step 1. 발단 — 노드가 있는데도 모든 것이 Pending이었다

## 1.1 최초 증상

EKS와 Argo CD가 복구된 뒤 여러 namespace에서 Pod가 동시에 `Pending`이었다.

```text
NAMESPACE          NAME                                      STATUS
auth-namespace     keycloak-0                                Pending
auth-namespace     keycloak-1                                Pending
auth-namespace     keycloak-2                                Pending
external-secrets   external-secrets-*                        Pending
external-secrets   external-secrets-cert-controller-*        Pending
external-secrets   external-secrets-webhook-*                Pending
kube-system        karpenter-*                               Pending
monitoring         otel-gateway-opentelemetry-collector-*    Pending
```

이 출력만 보면 “system node 3대로는 플랫폼 전체를 수용하지 못하는 것 아닌가?”라는 가설이 자연스럽다. 특히 system node의 인스턴스 타입이 `t3.medium`이었고, 여러 HA 컨트롤러가 2개 replica로 배포되고 있었기 때문이다.

그러나 `Pending`은 원인이 아니라 결과다. Kubernetes에서 Pending은 크게 다음 범주로 나뉜다.

1. 조건에 맞는 노드가 없음
2. taint를 tolerate하지 못함
3. CPU·메모리·Pod 수가 부족함
4. PVC나 topology 조건이 충족되지 않음
5. admission 또는 스케줄러 확장 기능이 결정을 막음

따라서 Pod 목록만으로 용량 부족을 결론 내릴 수 없었다.

## 1.2 스케줄러가 남긴 첫 번째 결정적 증거

ESO Pod의 이벤트는 다음과 같았다.

```text
Warning  FailedScheduling
0/3 nodes are available:
3 node(s) didn't match Pod's node affinity/selector.
preemption:
0/3 nodes are available:
3 Preemption is not helpful for scheduling.
```

여기에는 `Insufficient cpu`도, `Insufficient memory`도 없었다. 스케줄러는 노드의 남은 자원을 계산하기도 전에 **라벨 조건 단계에서 3대 모두 탈락**시켰다.

초기 가설은 이 시점에서 다음과 같이 수정돼야 했다.

```text
초기 가설: system node의 자원이 부족하다.
수정 가설: Pod의 nodeSelector 또는 required nodeAffinity와
           실제 node label이 일치하지 않는다.
```

## 1.3 당시 판단을 어렵게 만든 점

장애가 한 Pod에 국한되지 않았다. Keycloak, OTel, ESO, Karpenter가 동시에 Pending이었기 때문에 “클러스터 전체의 노드 용량 문제”처럼 보였다.

하지만 실제로는 서로 다른 두 그룹이 섞여 있었다.

- **부트스트랩 컨트롤러:** Karpenter, ESO, KEDA
- **Karpenter 노드를 소비할 워크로드:** Keycloak, OTel 등

후자의 Pending은 Karpenter 노드가 아직 없어서 어느 정도 예상 가능한 상태였다. 진짜 비정상은 **Karpenter 자신과 ESO까지 Karpenter 노드를 기다리고 있었다는 것**이다.

---

# Step 2. 기반 지식 — 스케줄러는 어떤 순서로 후보 노드를 버리는가

## 2.1 `nodeSelector`는 희망사항이 아니라 필수 조건이다

다음 설정은 “가능하면 이 노드에 배치해 달라”는 의미가 아니다.

```yaml
nodeSelector:
  role: system
```

Pod가 배치될 노드는 반드시 `role=system`을 가져야 한다. 조건을 만족하지 않는 노드는 후보에서 제거된다.

여러 selector가 있으면 기본적으로 AND 조건이다.

```yaml
nodeSelector:
  role: system
  karpenter.sh/nodepool: system
```

이를 논리식으로 쓰면 다음과 같다.

```text
node.labels["role"] == "system"
AND
node.labels["karpenter.sh/nodepool"] == "system"
```

둘 중 하나라도 없으면 스케줄할 수 없다.

## 2.2 `requiredDuringSchedulingIgnoredDuringExecution`도 필수 조건이다

Karpenter Helm chart는 Karpenter controller가 Karpenter가 만든 노드에 올라가는 순환 의존성을 방지하기 위해 다음과 같은 affinity를 생성했다.

```yaml
nodeAffinity:
  requiredDuringSchedulingIgnoredDuringExecution:
    nodeSelectorTerms:
      - matchExpressions:
          - key: karpenter.sh/nodepool
            operator: DoesNotExist
```

의미는 다음과 같다.

> `karpenter.sh/nodepool` 라벨이 없는 노드만 후보로 인정한다.

그런데 사용자 values에서 반대 조건을 넣었다.

```yaml
nodeSelector:
  karpenter.sh/nodepool: system
```

최종 Pod에는 다음 두 조건이 동시에 존재했다.

```text
karpenter.sh/nodepool 라벨이 없어야 함
AND
karpenter.sh/nodepool 라벨 값이 system이어야 함
```

어떤 노드도 이 조건을 동시에 만족할 수 없다. Managed Node Group에 라벨을 임시로 추가하더라도 첫 번째 조건에서 탈락한다.

## 2.3 Managed Node Group과 Karpenter NodePool은 같은 “노드”지만 역할이 다르다

이 환경은 두 종류의 worker node를 사용하도록 설계됐다.

### Managed Node Group

Terraform이 EKS와 함께 먼저 만든다.

```hcl
resource "aws_eks_node_group" "this" {
  node_group_name = "${var.cluster_name}-system-nodes"

  labels = {
    "role" = "system"
  }

  scaling_config {
    desired_size = 3
    min_size     = 2
    max_size     = 4
  }
}
```

목적:

- Karpenter controller 실행
- ESO, KEDA 등 핵심 플랫폼 컨트롤러 실행
- Karpenter가 아직 없어도 클러스터 제어면 유지

### Karpenter NodePool

Karpenter controller가 실행된 이후 수요에 따라 만든다.

목적:

- 애플리케이션 워크로드
- 관측성 워크로드
- workload별 taint와 label을 이용한 격리

`karpenter.sh/nodepool`은 후자의 출처와 소속을 나타내는 라벨이다. 이 라벨을 Managed Node Group에 임의로 붙이면 당장의 selector를 통과시킬 수는 있어도 노드의 실제 소유 모델과 라벨의 의미가 어긋난다.

## 2.4 Taint와 toleration은 이번 직접 원인이 아니었다

Pod에는 다음 toleration이 있었다.

```yaml
tolerations:
  - key: system-only
    operator: Equal
    value: "true"
    effect: NoSchedule
```

하지만 당시 3개 system node에는 taint가 없었다.

```text
NAME                  TAINTS
ip-10-0-11-18...      <none>
ip-10-0-12-29...      <none>
ip-10-0-13-9...       <none>
```

toleration은 특정 taint가 있는 노드에 들어갈 자격을 주지만, nodeSelector를 만족시키지는 않는다. 이번 사건에서 toleration은 무해했지만 해결책도 아니었다.

## 2.5 Preemption이 도움이 되지 않았던 이유

이벤트에는 다음 문장이 있었다.

```text
Preemption is not helpful for scheduling.
```

Preemption은 낮은 우선순위 Pod를 축출해 CPU나 메모리를 확보하는 방식이다. 하지만 이번에는 자원이 부족한 것이 아니라 모든 노드가 라벨 조건을 위반했다. 기존 Pod를 아무리 제거해도 노드 라벨은 바뀌지 않는다.

스케줄러는 정확히 “축출로 해결할 수 없는 문제”라고 말하고 있었다.

---

# Step 3. CCTV 추적 — 스케줄링 실패 순간을 0.1초 단위로 재구성하다

## 3.1 EKS가 system node 3대를 준비한다

Terraform은 세 AZ에 Managed Node Group 인스턴스를 생성했다. 각 노드는 Ready였으며 다음 라벨을 가졌다.

```text
role=system
eks.amazonaws.com/nodegroup=prod-eks-system-nodes
```

다음 라벨은 없었다.

```text
karpenter.sh/nodepool
```

여기까지는 정상이다. 해당 노드들은 Karpenter가 만든 노드가 아니기 때문이다.

## 3.2 Argo CD가 Helm values를 사용해 Karpenter Pod를 만든다

당시 values가 `karpenter.sh/nodepool=system`을 요구하면서 최종 Pod spec은 개념적으로 다음과 같이 합성됐다.

```yaml
spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: karpenter.sh/nodepool
                operator: DoesNotExist

  nodeSelector:
    karpenter.sh/nodepool: system
    kubernetes.io/os: linux
    role: system
```

## 3.3 scheduler가 첫 번째 노드를 평가한다

노드 `ip-10-0-11-18`:

```text
role=system                         → 통과
kubernetes.io/os=linux             → 통과
karpenter.sh/nodepool=system       → 실패: 라벨 없음
```

nodeSelector 단계에서 탈락한다.

## 3.4 두 번째와 세 번째 노드도 같은 이유로 탈락한다

세 노드는 동일한 Managed Node Group 설정으로 만들어졌으므로 결과도 같았다.

```text
후보 3대
  → nodeSelector 불일치 3대
  → 최종 후보 0대
```

설령 노드에 `karpenter.sh/nodepool=system`을 수동으로 추가했더라도 차트의 `DoesNotExist` 조건 때문에 node affinity 단계에서 탈락했을 것이다.

## 3.5 Karpenter가 Pending이므로 새로운 NodePool 노드를 만들 주체가 사라진다

이 시점부터 장애가 자기 증폭을 시작한다.

```text
Karpenter Pending
  → NodeClaim 생성·조정 불가
  → workload/observability node 생성 불가
  → Keycloak·OTel Pending 지속
```

ESO도 같은 잘못된 selector를 사용했다.

```text
ESO Pending
  → ExternalSecret 동기화 불가
  → Secret을 기다리는 앱의 기동 조건도 충족 불가
```

단순한 Karpenter Pod 한 개의 스케줄링 실수가 노드 프로비저닝과 Secret 전달 경로를 동시에 막는 플랫폼 장애로 확장됐다.

---

# Step 4. 삽질과 해결 — 노드에 라벨을 붙이지 않고 계약을 고친 이유

## 4.1 실패 가능성이 높은 접근: 기존 노드에 Karpenter 라벨 추가

가장 빠르게 떠오르는 해결책은 다음과 같다.

```powershell
kubectl label node <system-node> karpenter.sh/nodepool=system
```

하지만 이 방법은 채택하지 않았다.

### 이유 1: Karpenter Pod의 조건이 이미 모순이었다

nodeSelector는 라벨이 있어야 한다고 요구하고, required nodeAffinity는 없어야 한다고 요구했다. 라벨을 추가하면 selector는 통과하지만 affinity에서 탈락한다.

### 이유 2: 라벨의 의미를 훼손한다

Managed Node Group을 Karpenter NodePool 노드처럼 보이게 만든다. 스케줄링 정책과 운영자의 관찰 결과가 실제 인프라 소유 관계와 달라진다.

### 이유 3: 재구축 시 사라지는 런타임 패치다

노드를 교체하거나 클러스터를 다시 만들면 라벨은 사라진다. Git에는 잘못된 values가 남아 있으므로 장애가 반복된다.

## 4.2 영구 수정: 부트스트랩 컨트롤러의 의존 방향을 바로잡는다

Karpenter values에서 잘못된 selector를 제거했다.

### Before

```yaml
nodeSelector:
  role: "system"
  karpenter.sh/nodepool: "system"
```

### After

```yaml
# Bootstrap on EKS managed system nodes (role=system).
# Do NOT require karpenter.sh/nodepool=system — that label only appears on
# Karpenter-provisioned nodes.
nodeSelector:
  role: "system"
  kubernetes.io/os: "linux"
```

ESO도 같은 원칙을 적용했다.

```yaml
# Schedule on managed system NG (role=system) until Karpenter pools exist.
nodeSelector:
  role: system
```

KEDA의 operator, metrics server, webhook도 `role=system`으로 통일했다.

이 변경으로 의존 방향은 다음처럼 단방향이 됐다.

```text
Terraform
  → Managed Node Group(role=system)
      → Karpenter / ESO / KEDA
          → Karpenter NodePool
              → application / observability workloads
```

## 4.3 Git 수정과 live 복구가 동시에 끝나지는 않았다

Git values를 수정한 뒤 ESO의 새 ReplicaSet은 `ContainerCreating`으로 전환됐다. 이는 새 selector가 실제 Deployment에 반영되고 system node가 후보로 선택됐다는 증거였다.

```text
external-secrets-86dbdb9896-*   ContainerCreating
```

반면 Karpenter의 기존 Pod는 여전히 20분 이상 된 Pending 상태였다.

```text
karpenter-controller   OutOfSync   Missing
karpenter-*            Pending
```

원인은 nodeSelector 수정이 틀린 것이 아니라 Argo CD sync 경로의 별도 장애였다. AWS Load Balancer Controller webhook TLS 문제와 Argo CD의 Server-Side Apply diff panic이 겹치면서 Karpenter Deployment가 과거 spec에 머물렀다.

이 부분은 본 사건의 직접 원인이 아니지만 중요한 운영 교훈을 남겼다.

> Git의 desired state를 고쳤다고 live state가 즉시 고쳐진 것은 아니다.

서비스 복구를 위해 live Deployment의 nodeSelector를 `role=system`으로 직접 패치했고, Karpenter 2개 replica가 Running으로 전환됐다.

```text
karpenter … 1/1 Running (2 replicas)
nodeSelector: role=system, kubernetes.io/os=linux
```

직접 패치는 영구 해결이 아니라 운영상 bridge였다. 영구 해결의 기준은 Git values이며, Argo sync 문제는 별도 후속 장애로 추적했다.

## 4.4 검증

복구 후 ESO controller와 관련 구성 요소가 Running으로 전환됐다.

```text
external-secrets-*                   1/1 Running
external-secrets-cert-controller-*   1/1 Running
external-secrets-webhook-*           1/1 Running
```

Karpenter controller도 system node에서 실행됐다.

```text
karpenter-*   1/1 Running
```

이후 NodePool과 NodeClaim을 생성하는 다음 단계로 진행할 수 있었다. 다만 그 과정에서 EC2는 생성됐지만 stale EKS endpoint 때문에 노드가 등록되지 않는 별개의 장애가 드러났다. 해당 사건은 회고 2에서 다룬다.

---

# Step 5. 넥스트 스텝 — 부트스트랩 계층을 명시적으로 설계하라

## 5.1 가장 중요한 아키텍처 원칙

> 어떤 컨트롤러가 리소스 X를 생성한다면, 그 컨트롤러의 기동 조건이 X에 의존해서는 안 된다.

이번 환경에 적용하면:

- Karpenter는 Karpenter NodePool에 의존하면 안 된다.
- ESO가 workload Secret의 전제라면 ESO는 workload node에 의존하면 안 된다.
- autoscaler가 capacity를 만든다면 autoscaler 자체 capacity는 별도로 보장해야 한다.

## 5.2 노드 라벨은 단순한 문자열이 아니라 계약이다

이번 장애에서는 다음 두 라벨이 비슷해 보였지만 의미가 달랐다.

```text
role=system
  → 이 클러스터에서 system workload를 수용하는 운영 목적

karpenter.sh/nodepool=<name>
  → Karpenter가 생성·관리하는 NodePool 소속
```

둘 다 “system 노드”처럼 보인다는 이유로 대체해서는 안 된다. 라벨 이름에는 노드의 **목적**, **출처**, **소유자** 중 무엇을 표현하는지 명확한 규칙이 필요하다.

## 5.3 `Pending` 진단 체크리스트

### 1단계: 이벤트를 먼저 본다

```powershell
kubectl describe pod -n <namespace> <pod> |
  Select-String -Pattern "FailedScheduling|Insufficient|taint|affinity|selector" -Context 0,8
```

### 2단계: 메시지별로 분기한다

```text
Insufficient cpu/memory
  → requests, allocatable, autoscaler 상태 확인

didn't match Pod's node affinity/selector
  → Pod selector와 node labels 비교

had untolerated taint
  → node taints와 Pod tolerations 비교

unbound immediate PersistentVolumeClaims
  → PVC, StorageClass, topology 확인
```

### 3단계: 실제 Pod spec을 본다

Helm values만 보면 chart가 추가한 affinity를 놓칠 수 있다.

```powershell
kubectl get pod -n <namespace> <pod> -o yaml |
  Select-String -Pattern "nodeSelector|affinity|tolerations" -Context 0,12
```

### 4단계: 노드의 실제 상태와 비교한다

```powershell
kubectl get nodes --show-labels
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints
```

### 5단계: 컨트롤러가 만드는 대상에 컨트롤러 자신이 의존하는지 확인한다

```text
Karpenter → Karpenter NodePool?
ESO → Secret이 있어야 뜨는 workload node?
Ingress controller → 자신이 관리하는 admission/webhook 경로?
```

## 5.4 배포 전 자동 검증 항목

다음 검증을 CI 또는 pre-deploy 단계에 추가할 수 있다.

### Helm 렌더 결과 검사

```powershell
helm template karpenter oci://public.ecr.aws/karpenter/karpenter `
  --version 0.37.0 `
  -f apps/karpenter/values-prod.yaml > rendered.yaml
```

렌더 결과에서 같은 label key에 대한 모순을 검사한다.

```text
nodeSelector: key=value
required nodeAffinity: key DoesNotExist
```

### 부트스트랩 dependency test

Karpenter NodePool이 하나도 없는 상태에서 다음 Pod가 system node에 스케줄 가능한지 검증한다.

- Karpenter controller
- ESO controller/webhook/cert-controller
- KEDA operator/metrics server/webhook
- Argo CD 핵심 구성 요소

### 재구축 acceptance criterion

```text
1. Managed Node Group만 존재
2. Karpenter controller Running
3. ESO Ready
4. NodePool/NodeClaim 생성 가능
5. 그 이후 workload 배포
```

## 5.5 재발 방지 체크리스트

- [ ] Karpenter controller는 Managed Node Group의 `role=system`만 요구한다.
- [ ] ESO와 KEDA도 Karpenter NodePool이 없어도 기동할 수 있다.
- [ ] `karpenter.sh/nodepool`은 Karpenter가 관리하는 노드에만 사용한다.
- [ ] chart 기본 affinity와 사용자 `nodeSelector`를 렌더 결과에서 함께 검토한다.
- [ ] Pending을 볼 때 용량을 추측하기 전에 `FailedScheduling` 이벤트를 확인한다.
- [ ] Git 변경 후 live Deployment spec이 실제로 바뀌었는지 검증한다.
- [ ] Argo sync 실패 시 런타임 패치와 Git 영구 수정의 상태를 별도로 기록한다.
- [ ] Karpenter가 없는 cold-start 상태를 재구축 테스트에 포함한다.

---

## 최종 원인 트리

```text
플랫폼·워크로드 Pod 대량 Pending
│
├─ 직접 원인
│  └─ Pod selector와 실제 node label 불일치
│     ├─ Node: role=system
│     └─ Pod: karpenter.sh/nodepool=system 요구
│
├─ 설정 모순
│  ├─ nodeSelector: karpenter.sh/nodepool=system
│  └─ required nodeAffinity: karpenter.sh/nodepool DoesNotExist
│
├─ 구조적 원인
│  └─ Karpenter가 자신이 생성할 노드에 의존
│
├─ 확산 요인
│  ├─ Karpenter Pending → workload node 생성 불가
│  └─ ESO Pending → Secret 동기화 경로 중단
│
└─ 복구 지연 요인
   └─ Argo sync가 별도 webhook/SSA 오류로 live spec을 갱신하지 못함
```

## 한 문장으로 남기는 교훈

**새 노드를 만드는 컨트롤러는 “미래에 자신이 만들 노드”가 아니라 “이미 존재하도록 보장된 부트스트랩 노드” 위에서 실행되어야 한다.**

