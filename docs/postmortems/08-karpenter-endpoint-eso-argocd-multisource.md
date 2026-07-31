# 하드코딩 제거는 끝이 아니었다

> SSM→ESO→Karpenter 전환과 Argo CD Multi-Source manifest generation 실패를 분리해 추적한 기록

## 문서 정보

- 사건 시각: 2026-07-31 02:21~03:17 KST
- 환경: Argo CD 2.9 계열, Karpenter 0.37.0, ESO, SSM Parameter Store
- 선행 사건: 회고 2의 stale EKS API endpoint
- 설계 목표: EKS 재생성 후 endpoint를 Git 수정 없이 Karpenter에 전달
- 데이터 원본: `/localy/prod/eks/cluster_endpoint`
- 전달 경로: Terraform → SSM → ESO → Secret → Karpenter env
- Git 변경 상태: remote `main` 반영 완료
- ESO 상태: `SecretSynced`, SSM 값과 Secret 값 일치
- Argo 증상: `ComparisonError`, `failed to get git client`, nil pointer, EOF, App `Unknown`
- live 증상: Karpenter는 Running이지만 이전 literal endpoint를 계속 사용
- 기능 복구: Deployment를 `secretKeyRef`로 직접 컷오버
- 미해결 항목: Argo manifest generation 오류의 정확한 내부 root cause

---

## Executive Summary

회고 2에서는 Karpenter가 삭제된 EKS endpoint를 사용해 새 EC2 node를 클러스터에 등록하지 못했다.

```text
old endpoint: E583CF...
new endpoint: A3DAFF...
```

당시에는 Karpenter Deployment와 Git values의 URL을 현재 endpoint로 직접 바꿔 복구했다. 하지만 다음 EKS 재생성에서 같은 문제가 반복될 구조였다.

조사 결과 L2 Terraform은 이미 실제 EKS endpoint를 SSM Parameter Store에 기록하고 있었다.

```text
/localy/prod/eks/cluster_endpoint
```

따라서 다음 자동 전달 경로를 구현했다.

```text
EKS 생성
  → Terraform이 SSM 갱신
    → ESO가 Kubernetes Secret 생성
      → Karpenter CLUSTER_ENDPOINT가 Secret 참조
```

Git에서는 literal `clusterEndpoint`를 제거하고 다음 env를 사용했다.

```yaml
- name: CLUSTER_ENDPOINT
  valueFrom:
    secretKeyRef:
      name: karpenter-cluster-settings
      key: CLUSTER_ENDPOINT
```

ESO 측은 정상적으로 동작했다.

```text
SSM endpoint == Kubernetes Secret endpoint
ExternalSecret = SecretSynced
```

Helm local rendering도 `secretKeyRef`를 포함했다. Git commit `671830c`는 remote main에 반영됐다.

그러나 live Deployment를 확인한 결과는 다음과 같았다.

```text
CLUSTER_ENDPOINT secret=/
```

이 출력은 Secret 값이 비어 있다는 뜻이 아니었다. 조회 명령이 `valueFrom.secretKeyRef`만 출력했는데 live env에는 여전히 literal `value=https://A3DAFF...`만 있었기 때문에 name과 key가 빈 문자열로 표시된 것이다.

```text
Git desired:
  valueFrom.secretKeyRef

Live Deployment:
  value: https://A3DAFF...
```

Karpenter Pod가 Running인 것도 새 설정이 성공했다는 증거가 아니었다. 174분 전에 생성된 이전 ReplicaSet이 정상 동작 중이었다.

Git 변경이 live에 도달하지 않은 이유는 Argo CD가 Multi-Source Application의 desired manifest를 생성하지 못했기 때문이다.

```text
Git commit              성공
Source fetch/render      실패
Desired manifest 계산   실패
Live diff                불가
Sync                     불가
기존 Deployment          유지
```

당시 Application은 Helm OCI chart, values 전용 Git source, ESO manifest용 Git path source를 조합했다.

```yaml
sources:
  - chart: karpenter
  - repoURL: localy-manifests
    ref: values
  - repoURL: localy-manifests
    path: apps/karpenter/cluster-settings
```

같은 Git source에 `ref`와 `path`를 합쳐 source 수를 줄이는 workaround를 적용했다.

```yaml
- repoURL: localy-manifests
  ref: values
  path: apps/karpenter/cluster-settings
```

이 구성은 논리적으로도 유효하고 source clone/render 경로를 단순화한다. 그러나 당시 세션에서 Argo App은 이후에도 repo-server EOF와 manifest generation 오류로 `Unknown`에 남았다. 따라서 “같은 repository를 두 번 사용한 것이 root cause이고 합치면서 완전히 해결됐다”고 단정할 수 없다.

서비스 기능은 live Deployment를 직접 `secretKeyRef`로 전환해 복구했다.

```text
CLUSTER_ENDPOINT
secret=karpenter-cluster-settings/CLUSTER_ENDPOINT
```

Karpenter 새 ReplicaSet 2개가 `1/1 Running`이 됐다. endpoint SSOT 전환은 기능적으로 완료됐지만 Argo reconciliation health는 미해결 상태로 남은 채 인프라 teardown이 진행됐다.

---

# Step 1. 발단 — Secret은 준비됐는데 Karpenter는 사용하지 않았다

## 1.1 하드코딩 제거의 필요성

기존 values:

```yaml
settings:
  clusterEndpoint: >-
    https://A3DAFF...eks.amazonaws.com
```

이 값은 현재 클러스터에는 맞지만 EKS를 다시 만들면 stale 값이 된다.

```text
EKS recreate
  → endpoint 변경
    → Git 값은 과거 endpoint
      → Karpenter node bootstrap 실패
```

## 1.2 동적 원본은 이미 존재했다

L2 Terraform:

```hcl
resource "aws_ssm_parameter" "eks_cluster_endpoint" {
  name  = local.ssm_paths["eks_cluster_endpoint"]
  type  = "String"
  value = module.eks.cluster_endpoint
}
```

실제 path:

```text
/localy/prod/eks/cluster_endpoint
```

Terraform 재구축 시 SSM 값도 새 endpoint로 갱신된다.

## 1.3 ESO resource를 추가한다

```text
SecretStore/karpenter-ssm-store
ExternalSecret/karpenter-cluster-settings
Secret/karpenter-cluster-settings
```

검증:

```text
ExternalSecret SecretSynced
Secret endpoint == SSM endpoint
Secret endpoint == live EKS endpoint
```

AWS에서 Kubernetes까지의 전달은 성공했다.

## 1.4 Git values를 변경한다

literal endpoint를 제거했다.

```yaml
settings:
  clusterName: prod-eks
  interruptionQueue: prod-eks-karpenter-interruption-queue
```

Karpenter controller env:

```yaml
controller:
  env:
    - name: CLUSTER_ENDPOINT
      valueFrom:
        secretKeyRef:
          name: karpenter-cluster-settings
          key: CLUSTER_ENDPOINT
```

local Helm template에도 Secret reference가 생성됐다.

## 1.5 remote Git에도 변경이 존재했다

```text
671830c
feat(karpenter): load clusterEndpoint from SSM via ESO
```

local branch와 `origin/main`도 일치했다.

따라서 다음 가설은 배제됐다.

```text
commit을 안 했다
push를 안 했다
Argo가 old Git revision을 보는 중이다
```

## 1.6 live Deployment는 바뀌지 않았다

검증 명령:

```powershell
kubectl -n kube-system get deploy karpenter `
  -o jsonpath="{
    range .spec.template.spec.containers[0].env[
      ?(@.name=='CLUSTER_ENDPOINT')
    ]
  }{.name} secret={
    .valueFrom.secretKeyRef.name
  }/{.valueFrom.secretKeyRef.key}{'\n'}{end}"
```

결과:

```text
CLUSTER_ENDPOINT secret=/
```

Pod age:

```text
174m
```

새 ReplicaSet rollout이 일어나지 않았다는 추가 증거였다.

---

# Step 2. 기반 지식 — Application `sources`는 desired manifest의 재료 목록이다

## 2.1 Argo CD의 기본 처리 단계

```text
Application spec
  → source fetch
  → Helm/Kustomize/render
  → source별 manifest 생성
  → manifest 결합
  → live state와 비교
  → sync/apply
```

앞 단계가 실패하면 뒤 단계는 실행되지 않는다.

```text
manifest generation 실패
  → diff 없음
  → sync 없음
  → live state 유지
```

## 2.2 single-source Application

가장 단순한 Application은 source 하나만 가진다.

```yaml
source:
  repoURL: ...
  path: ...
```

Argo는 해당 repository/path를 render해 manifest를 만든다.

## 2.3 Multi-Source Application

Karpenter에는 서로 다른 재료가 필요했다.

```text
Karpenter Helm chart
custom values-prod.yaml
SecretStore/ExternalSecret manifests
```

따라서 `sources` 배열을 사용했다.

```yaml
spec:
  sources:
    - ...
    - ...
```

Argo는 각 source의 결과를 합쳐 하나의 Application desired state로 취급한다.

## 2.4 Helm chart source

```yaml
- repoURL: public.ecr.aws/karpenter
  chart: karpenter
  targetRevision: "0.37.0"
```

이 source는 Karpenter Deployment, ServiceAccount, Service 등의 기본 template을 제공한다.

## 2.5 `ref: values`의 역할

```yaml
- repoURL: https://github.com/.../localy-manifests.git
  targetRevision: main
  ref: values
```

`ref`는 이 repository에 `$values`라는 이름을 붙인다.

Helm source:

```yaml
valueFiles:
  - $values/apps/karpenter/values-prod.yaml
```

의미:

```text
$values
  → ref: values가 붙은 Git repository root
```

path가 없는 ref-only source는 일반적으로 그 repository 파일을 Helm values로 제공하되 자체 Kubernetes manifest를 생성하지 않는 용도로 사용된다.

## 2.6 `path:`의 역할

```yaml
- repoURL: https://github.com/.../localy-manifests.git
  path: apps/karpenter/cluster-settings
```

의미:

```text
이 directory를 Kustomize/plain YAML source로 render하고
그 결과를 실제 Application manifest에 포함
```

해당 path가 생성하는 resource:

```text
SecretStore
ExternalSecret
```

## 2.7 같은 repository를 두 번 쓰는 것이 잘못인가

아니다.

```text
source A:
  values 제공

source B:
  manifests 제공
```

논리적으로 역할이 다르고 Argo Multi-Source가 지원하려는 사용 사례에 부합한다. 다른 Application에서도 비슷한 패턴이 동작할 수 있다.

따라서 이번 사건을 다음처럼 일반화하면 안 된다.

```text
같은 Git repository는 sources에 한 번만 쓸 수 있다.
```

정확한 표현:

```text
현재 Argo 2.9 환경에서
OCI Helm + ref-only Git + 동일 repo path Git 조합을 처리할 때
manifest generation 오류가 관찰됐다.
```

## 2.8 `ref`와 `path`를 한 source에 함께 둘 수 있다

```yaml
- repoURL: https://github.com/.../localy-manifests.git
  targetRevision: main
  ref: values
  path: apps/karpenter/cluster-settings
```

이 source는 두 역할을 함께 한다.

```text
ref:
  Helm에 values file 제공

path:
  cluster-settings manifest 생성
```

source graph를 단순화하는 workaround다.

---

# Step 3. CCTV 추적 — Git 변경이 live Deployment 앞에서 멈춘 지점

## 3.1 Terraform이 현재 endpoint를 SSM에 기록한다

```text
SSM:
https://A3DAFF...eks.amazonaws.com
```

## 3.2 ESO가 SSM 값을 읽는다

SecretStore:

```yaml
provider:
  aws:
    service: ParameterStore
    region: ap-northeast-2
```

ExternalSecret:

```yaml
remoteRef:
  key: /localy/prod/eks/cluster_endpoint
```

## 3.3 ESO가 Kubernetes Secret을 생성한다

```yaml
data:
  CLUSTER_ENDPOINT: https://A3DAFF...
```

검증:

```text
SecretSynced
SSM == Secret
```

## 3.4 Git desired state가 Secret 참조로 바뀐다

```text
values-prod.yaml:
  literal endpoint 제거
  controller.env secretKeyRef 추가

karpenter-controller.yaml:
  cluster-settings path source 추가
```

remote main 반영:

```text
671830c
```

## 3.5 Argo가 source를 fetch/render하려 한다

초기 source shape:

```yaml
sources:
  # 1
  - repoURL: public.ecr.aws/karpenter
    chart: karpenter

  # 2
  - repoURL: localy-manifests.git
    ref: values

  # 3
  - repoURL: localy-manifests.git
    path: apps/karpenter/cluster-settings
```

의도한 처리:

```text
1. OCI Helm chart fetch
2. Git values file 제공
3. Git path에서 ESO manifests 생성
4. Helm + ESO 결과 결합
```

## 3.6 manifest generation이 실패한다

관찰된 오류:

```text
ComparisonError
failed to get git client for repo
nil pointer
EOF
```

Application 상태:

```text
Sync Status: Unknown
Health: Healthy
```

`Healthy`는 기존 live Karpenter Deployment가 정상 동작 중이었기 때문이다. 새 desired state를 정상 계산했다는 뜻이 아니다.

## 3.7 기존 Deployment가 그대로 남는다

Argo가 새 manifest를 만들지 못하므로 기존 Deployment를 변경하지 않는다.

```yaml
- name: CLUSTER_ENDPOINT
  value: https://A3DAFF...eks.amazonaws.com
```

이것은 Git 하드코딩이 아직 남았다는 뜻이 아니라 live object가 이전 render 결과를 유지한다는 뜻이다.

```text
Git:
  새 설정

Live:
  과거 설정
```

## 3.8 `secret=/`이 관찰된다

조회 명령은 다음 field만 출력했다.

```text
valueFrom.secretKeyRef.name
valueFrom.secretKeyRef.key
```

live env는 `value`를 사용 중이므로 두 field가 없다.

```text
name=""
key=""
→ secret=/
```

Secret object 자체가 비어 있다는 의미는 아니다.

## 3.9 repository Secret 부재를 조사한다

```powershell
kubectl -n argocd get secret `
  -l argocd.argoproj.io/secret-type=repository
```

결과:

```text
No resources found
```

public GitHub repository는 별도 credential Secret 없이 anonymous clone할 수 있으므로 이 결과만으로 장애 원인이라 판단할 수 없다. 다른 public Git source Application이 동작하는지도 비교했다.

## 3.10 source를 두 개로 단순화한다

```yaml
sources:
  - repoURL: public.ecr.aws/karpenter
    chart: karpenter
    helm:
      valueFiles:
        - $values/apps/karpenter/values-prod.yaml

  - repoURL: localy-manifests.git
    targetRevision: main
    ref: values
    path: apps/karpenter/cluster-settings
```

의도:

```text
동일 Git fetch/render 경로 하나
  ├─ values 제공
  └─ manifests 생성
```

## 3.11 workaround 후에도 App은 완전히 회복되지 않는다

source 단순화와 repo-server restart, hard refresh를 수행했지만 다음 오류가 남았다.

```text
repo-server EOF
Application Unknown
```

따라서 source shape가 trigger 또는 회피 요소일 가능성은 있지만 정확한 root cause를 확정할 증거는 부족했다.

## 3.12 live Deployment를 직접 컷오버한다

기능 복구를 위해 literal env를 제거했다.

```powershell
kubectl -n kube-system set env `
  deployment/karpenter `
  CLUSTER_ENDPOINT-
```

Secret의 동일 key를 env로 연결했다.

```powershell
kubectl -n kube-system set env `
  deployment/karpenter `
  --from=secret/karpenter-cluster-settings `
  --keys=CLUSTER_ENDPOINT
```

이는 다음 Pod spec을 만든다.

```yaml
- name: CLUSTER_ENDPOINT
  valueFrom:
    secretKeyRef:
      name: karpenter-cluster-settings
      key: CLUSTER_ENDPOINT
```

## 3.13 새 ReplicaSet이 rollout된다

검증:

```text
CLUSTER_ENDPOINT
secret=karpenter-cluster-settings/CLUSTER_ENDPOINT

Karpenter Pods:
1/1 Running
```

기능 경로:

```text
SSM → ESO Secret → Karpenter env
```

Argo 상태:

```text
Unknown
```

기능 복구와 GitOps reconciliation 복구는 별개의 완료 조건이었다.

---

# Step 4. 삽질과 해결 — 올바른 Git이 올바른 live를 보장하지 않았다

## 4.1 잘못된 해석: Secret 값이 비어 있다

```text
CLUSTER_ENDPOINT secret=/
```

처음 보면 Secret name/key가 비어 있거나 ESO가 잘못 만든 것처럼 보인다.

하지만 Kubernetes Secret은 존재했고 `CLUSTER_ENDPOINT` key도 있었다. 조회 대상이 live env의 실제 표현과 달랐던 것이다.

개선된 확인:

```powershell
kubectl -n kube-system get deploy karpenter `
  -o jsonpath="{
    range .spec.template.spec.containers[0].env[
      ?(@.name=='CLUSTER_ENDPOINT')
    ]
  }name={.name}{'\n'}value={.value}{'\n'}valueFrom={
    .valueFrom
  }{'\n'}{end}"
```

literal과 valueFrom을 함께 봐야 한다.

## 4.2 잘못된 해석: Running이므로 새 설정도 정상

Pod age가 174분이었다.

```text
Git 변경 시각 이후 rollout 없음
```

Running은 이전 설정의 workload health만 증명했다.

확인할 것:

```text
ReplicaSet revision
Pod creationTimestamp
Deployment generation
observedGeneration
env source
```

## 4.3 잘못된 해석: Git에 변화가 없어서 Argo가 skip

Git에는 이미 변경이 있었다.

```text
main == origin/main
commit 671830c
```

실제:

```text
변화를 감지하지 않은 것
아니라
desired를 생성하지 못한 것
```

## 4.4 잘못된 해석: repository Secret이 없어서 clone 실패

private repository라면 credential Secret이 필요하다. 하지만 해당 GitHub repository는 public이었다.

```text
repository Secret 없음
≠
public repo clone 불가
```

인증 실패 message와 anonymous 접근 가능 여부를 함께 확인해야 한다.

## 4.5 source 합치기의 성격

source 3개를 2개로 줄인 것은 다음 의미다.

```text
잘못된 Argo 문법을 정정
  보다는
관찰된 불안정 shape를 단순화한 workaround
```

같은 repo를 여러 source로 사용하는 것은 논리적으로 허용된다. “분리하면 안 된다”는 일반 원칙을 만들지 않는다.

## 4.6 정확한 root cause를 확정하지 못한 이유

관찰된 증거:

- `failed to get git client`
- sync nil pointer
- repo-server EOF
- `Unknown`
- source 단순화 후에도 오류 지속

부족한 증거:

- full repo-server stack trace
- 동일 버전 최소 재현 Application
- source 조합별 반복 실험
- repo-server resource/OOM 상태
- network trace
- Argo upstream issue와 정확한 stack match

따라서 문서에서는 다음 수준까지만 주장한다.

```text
Multi-Source manifest generation 단계에서 실패
source 구성 단순화를 workaround로 시도
정확한 Argo 내부 결함은 미확정
```

## 4.7 직접 컷오버의 장점과 위험

장점:

- endpoint SSOT 기능 즉시 복구
- 새 Pod가 Secret reference 사용
- stale endpoint 재발 경로 제거

위험:

- live state가 GitOps controller 외부에서 변경됨
- Argo 회복 시 desired state가 다르면 되돌릴 수 있음
- 변경 이력이 Git commit만으로 설명되지 않음
- 다음 재구축에서 Application generation 실패가 재발 가능

이번에는 Git desired state도 같은 Secret reference였기 때문에 Argo가 정상 회복하면 수렴할 것으로 기대할 수 있었다. 그러나 실제 Argo sync 검증이 완료되기 전에는 이를 완료로 선언할 수 없다.

## 4.8 Reloader annotation의 한계

Karpenter Pod annotation:

```yaml
secret.reloader.stakater.com/reload:
  karpenter-cluster-settings
```

의도:

```text
SSM 변경
  → ESO Secret 갱신
    → Reloader rollout
      → Karpenter가 새 env 사용
```

하지만 당시 health snapshot에서 Reloader는 Degraded/CrashLoop 상태였다. annotation이 있다는 사실만으로 자동 rollout을 보장할 수 없었다.

그래서 실제 컷오버에서는 Deployment rollout을 직접 확인했다.

---

# Step 5. 넥스트 스텝 — desired state 생성도 관측해야 한다

## 5.1 가장 중요한 설계 원칙

> Git에 올바른 선언이 있다는 사실과 클러스터가 그 선언으로 실행 중이라는 사실은 다르다.

검증해야 하는 네 상태:

```text
1. Git source
2. Argo rendered desired state
3. Kubernetes live state
4. Pod runtime state
```

## 5.2 endpoint SSOT 검증

### AWS live

```powershell
aws eks describe-cluster `
  --name prod-eks `
  --query "cluster.endpoint"
```

### SSM

```powershell
aws ssm get-parameter `
  --name /localy/prod/eks/cluster_endpoint `
  --query Parameter.Value
```

### Kubernetes Secret

값을 출력하지 않고 hash/equality 또는 controlled decode로 비교한다.

### Deployment

```text
value 없음
valueFrom.secretKeyRef.name=
  karpenter-cluster-settings
valueFrom.secretKeyRef.key=
  CLUSTER_ENDPOINT
```

### Pod rollout

```text
new ReplicaSet
new Pod age
Karpenter logs 정상
new NodeClaim registration 성공
```

## 5.3 Argo Application acceptance criteria

```text
[ ] status.sync.status != Unknown
[ ] ComparisonError 없음
[ ] source revision 확인 가능
[ ] desired manifests 생성 성공
[ ] Deployment diff 계산 성공
[ ] sync operation 성공
[ ] hard refresh 후 상태 유지
[ ] repo-server restart 없이 반복 동작
```

## 5.4 Multi-Source 최소 재현이 필요하다

다음 조합을 별도 test Application으로 비교해야 한다.

```text
A. OCI Helm + ref-only Git
B. OCI Helm + path Git
C. OCI Helm + ref-only Git + same-repo path Git
D. OCI Helm + ref+path combined Git
```

각 조합에서:

- manifest generation
- hard refresh
- sync
- repo-server logs
- memory/CPU
- cache behavior

를 비교하면 source shape가 root인지 확인할 수 있다.

## 5.5 Argo upgrade 검토

현재 증상이 Argo 2.9의 known issue와 일치하는지 release note와 upstream issue를 확인한다.

upgrade 전:

- CRD 호환성
- application-controller behavior
- repo-server cache
- multi-source changes
- Server-Side Apply diff behavior
- rollback 계획

을 검증해야 한다.

정확한 issue ID가 확인되지 않은 상태에서 “업그레이드하면 해결”로 단정하지 않는다.

## 5.6 endpoint가 비밀이 아닌데 Secret을 쓰는 이유

EKS endpoint는 public identifier 성격의 구성값이지 password가 아니다.

SSM Parameter Store 선택은 적절하다.

Kubernetes에서 Secret을 사용한 이유:

- ESO 기본 target이 Secret
- chart env가 `secretKeyRef`를 쉽게 지원
- Reloader Secret watch 활용

보안 민감도 때문에 반드시 Secret이어야 했던 것은 아니다. ConfigMap 기반 전달이 chart와 operator에서 지원된다면 그것도 가능한 설계다.

## 5.7 bootstrap dependency

새 흐름은 다음 component가 먼저 동작해야 한다.

```text
Managed system nodes
  → ESO controller
    → karpenter-cluster-settings Secret
      → Karpenter controller
```

회고 1에서 ESO와 Karpenter를 Managed Node Group의 `role=system`에 배치한 것이 이 전환의 선행 조건이다.

Secret이 아직 없으면 Karpenter Pod는 required `secretKeyRef` 때문에 시작을 기다릴 수 있다. ESO가 독립적으로 system node에서 실행돼 Secret을 만들 수 있어야 순환 의존이 생기지 않는다.

## 5.8 재구축 acceptance criteria

```text
[ ] Terraform이 새 EKS endpoint를 SSM에 기록
[ ] ESO controller가 system node에서 Running
[ ] SecretStore Ready
[ ] ExternalSecret SecretSynced
[ ] Secret과 SSM endpoint 일치
[ ] Argo manifest generation 성공
[ ] Karpenter Deployment가 secretKeyRef 사용
[ ] Karpenter 새 Pod Ready
[ ] NodeClaim Registered=True
[ ] EKS endpoint 재생성 후 Git 수정 불필요
```

## 5.9 재발 방지 체크리스트

- [ ] 재생성되는 endpoint를 Git에 literal로 저장하지 않는다.
- [ ] Parameter Store와 Secrets Manager 용도를 구분한다.
- [ ] ESO의 bootstrap node 의존성을 확인한다.
- [ ] Git commit과 origin 반영을 모두 확인한다.
- [ ] Argo rendered desired state를 확인한다.
- [ ] `Unknown`을 Healthy와 함께 보고 정상으로 판단하지 않는다.
- [ ] JSONPath는 literal과 valueFrom을 함께 출력한다.
- [ ] Pod age와 ReplicaSet revision을 확인한다.
- [ ] 같은 Git repository의 multi-source 사용을 무조건 금지하지 않는다.
- [ ] workaround와 root-cause fix를 구분한다.
- [ ] direct live cutover 후 Git과의 수렴을 검증한다.
- [ ] Reloader annotation보다 controller health를 먼저 확인한다.

---

## 최종 원인 트리

```text
Karpenter가 ESO Secret을 사용하지 않음
│
├─ SSM/ESO 경로
│  ├─ SSM endpoint 정상
│  ├─ ExternalSecret SecretSynced
│  └─ Kubernetes Secret 정상
│
├─ Git
│  ├─ literal endpoint 제거
│  ├─ secretKeyRef 추가
│  └─ origin/main commit 671830c
│
├─ Argo CD
│  ├─ Multi-Source manifest generation 실패
│  ├─ failed to get git client
│  ├─ nil pointer / EOF
│  └─ Application Unknown
│
├─ Live Deployment
│  ├─ 이전 literal endpoint 유지
│  ├─ 이전 ReplicaSet 계속 Running
│  └─ JSONPath 결과 secret=/
│
├─ workaround
│  └─ same Git의 ref + path를 한 source로 결합
│     └─ source graph 단순화, root cause 미확정
│
└─ 기능 복구
   ├─ live literal env 제거
   ├─ Secret key를 env로 직접 연결
   ├─ Karpenter rollout 성공
   └─ Argo Unknown은 미해결 잔여
```

## 한 문장으로 남기는 교훈

**GitOps에서는 Git이 정답이어도 controller가 그 정답을 render하지 못하면, 클러스터는 틀린 과거 상태로 정상 실행될 수 있다.**

