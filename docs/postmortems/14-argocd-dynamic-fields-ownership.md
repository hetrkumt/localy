# 실제 리소스는 정상인데 Argo CD는 왜 OutOfSync였나

> ESO·KEDA·Argo CD가 각자의 역할을 정상 수행하면서도 GitOps 드리프트를 만든 필드 소유권 사건

## 문서 정보

- 사건 시각: 2026-07-31 22:15~22:27 KST
- 환경: Argo CD, External Secrets Operator, KEDA, Kubernetes API, Server-Side Apply
- 대상 Application:
  - order, payment, cart, user, product, gateway
  - keycloak, workload-dbs, reloader
  - karpenter-controller
  - root-platform, root-workloads, root-app-of-apps
- 최초 증상: workload와 ExternalSecret은 정상인데 다수 Application이 `OutOfSync`
- 주요 원인:
  - ExternalSecret API default field
  - 임시 `force-sync` annotation
  - ESO가 소유하는 generated Secret
  - KEDA가 변경하는 Deployment `spec.replicas`
  - child Application controller가 기록하는 `status`, `operation`, refresh annotation
  - `prune=false` 상태에서 남은 Reloader PDB
- 직접 정리:
  - 임시 annotation 제거
  - orphan PDB 삭제
  - controller-owned field에 `ignoreDifferences`
  - `RespectIgnoreDifferences=true`
- 검증 결과: workload·Keycloak·workload-dbs·Reloader·root Application `Synced`
- 이관:
  - Karpenter NodePool/EC2NodeClass 잔여 drift는 백로그 9 및 회고 17
  - kube-prometheus-stack·Kyverno `Unknown`은 별도 관찰
- 관련 commit: `abcc098`, `1940f5d`, `47afb1b`, `e5f19a4`
- 관련 선행 회고: 회고 5의 Argo CD↔ESO generated Secret 이중 소유
- 남은 부채:
  - Secret `.metadata` 전체 ignore는 범위가 넓음
  - `force-sync`를 제거하면서 동시에 ignore하는 정책은 모순 가능
  - ignore rule의 자동 회귀 검증 없음

---

## Executive Summary

워크로드 복구가 끝난 뒤 Kubernetes resource의 runtime 상태는 정상에 가까웠다.

```text
ExternalSecret:
  SecretSynced
  Ready=True

Deployment:
  Pod Running/Ready

KEDA:
  replica 조절 가능

Root Application:
  child Application 생성 완료
```

그런데 Argo CD에는 `OutOfSync`가 계속 남았다.

처음에는 “Git과 cluster가 다르니 아직 장애가 남았다”고 볼 수 있다. 하지만 diff를 resource별·field별로 나누자 대부분은 실제 장애가 아니었다.

```text
ExternalSecret:
  Kubernetes API/ESO가 default field와 status를 기록

Deployment:
  KEDA가 replicas를 변경

Secret:
  ESO가 data와 metadata를 생성·회전

Application:
  Argo application controller가 status/operation을 기록

force-sync:
  사람이 일시적으로 reconcile을 요청하며 추가
```

GitOps에는 두 종류의 차이가 있었다.

```text
잘못된 drift:
  Git의 선언을 위반한 변경
  → 수정하거나 되돌려야 함

의도된 runtime mutation:
  별도 controller가 맡은 field의 정상 변경
  → 소유권 경계를 선언해야 함
```

또한 실제로 삭제해야 하는 orphan도 있었다.

```text
Reloader PDB:
  Git/Helm에서는 disabled
  prune=false 때문에 live에 잔존
  → ignore가 아니라 삭제
```

복구의 핵심은 모든 차이를 무시한 것이 아니다.

```text
1. resource가 실제로 정상인지 확인
2. diff를 field 단위로 분해
3. 누가 그 field를 쓰는지 확인
4. 정상 controller-owned field만 ignore
5. 임시 metadata와 실제 orphan은 제거
6. sync 시에도 ownership을 존중하도록 설정
```

이후 workload Application과 root Application은 `Synced`로 돌아왔다.

핵심 교훈:

> GitOps 정합성은 live object의 모든 byte를 Git과 같게 만드는 것이 아니다. 각 field의 authoritative writer를 하나로 정하고, Argo CD가 소유하지 않는 runtime field를 명시적으로 경계 밖에 두는 것이다.

---

# Step 1. `Healthy`와 `Synced`는 다른 질문이다

## 1.1 Health

Argo CD의 Health는 resource가 기능적으로 동작하는지를 평가한다.

예:

```text
Deployment:
  desired replica가 Ready인가

ExternalSecret:
  Ready condition이 True인가

Job:
  Complete인가
```

질문:

> 이 resource는 지금 정상적으로 작동하는가?

## 1.2 Sync

Sync는 Git에서 렌더링한 desired object와 live object가 같은지를 비교한다.

질문:

> cluster의 현재 선언이 Git의 desired state와 같은가?

## 1.3 가능한 조합

```text
Synced + Healthy:
  선언과 실행 모두 정상

Synced + Degraded:
  선언은 반영됐지만 workload가 실패

OutOfSync + Healthy:
  workload는 정상이나 desired/live 차이 존재

OutOfSync + Degraded:
  선언 차이와 runtime 장애가 함께 존재
```

이번 사건의 핵심은 `OutOfSync + Healthy`였다.

이 상태를 무조건 sync하면 정상 controller가 쓴 값을 Argo가 되돌릴 수 있다. 반대로 무조건 ignore하면 진짜 drift를 숨길 수 있다.

---

# Step 2. Kubernetes object는 한 명만 쓰지 않는다

## 2.1 desired object와 live object

Git:

```yaml
apiVersion: apps/v1
kind: Deployment
spec:
  replicas: 2
```

live object에는 훨씬 많은 정보가 생긴다.

```text
metadata.resourceVersion
metadata.uid
metadata.generation
metadata.managedFields
status
API default
controller annotation
autoscaler mutation
```

이 정보가 모두 Git에 있어야 하는 것은 아니다.

## 2.2 여러 writer

한 Deployment에도 여러 writer가 있다.

```text
Argo CD:
  image, env, resource, template 등 desired spec

KEDA/HPA:
  spec.replicas

Deployment controller:
  status

admission/defaulting:
  생략된 default field

kubectl:
  수동 apply/annotation metadata
```

ExternalSecret:

```text
Argo CD:
  ExternalSecret spec

Kubernetes API:
  defaulted spec field, metadata

ESO:
  ExternalSecret status
  generated Secret data/metadata

운영자:
  force-sync annotation
```

## 2.3 GitOps의 실제 질문

잘못된 질문:

> 왜 live JSON 전체가 Git YAML과 같지 않은가?

올바른 질문:

> 이 field의 주인은 누구이며, 그 writer의 변경은 의도된 것인가?

---

# Step 3. 증상을 resource별로 분해하다

## 3.1 workload Application

대상:

```text
order-service
payment-service
cart-service
user-service
product-service
gateway-service
```

주요 diff:

```text
Deployment /spec/replicas
ExternalSecret status/default field
ExternalSecret force-sync annotation
ESO generated Secret
```

## 3.2 platform Application

```text
keycloak:
  ExternalSecret와 generated Secret

workload-dbs:
  ExternalSecret와 generated Secret

reloader:
  disabled됐지만 남은 PDB

karpenter-controller:
  cluster-settings ExternalSecret
```

## 3.3 root Application

```text
root-platform
root-workloads
```

이 root들은 child `Application` CR을 desired resource로 관리한다.

그러나 child Application의 controller는 다음을 계속 갱신한다.

```text
status
operation
argocd.argoproj.io/refresh
```

parent가 이 runtime field까지 Git과 비교하면 App-of-Apps가 자기 자식의 정상 reconcile 때문에 OutOfSync가 될 수 있다.

---

# Step 4. ExternalSecret API default가 만든 차이

## 4.1 Git에서 생략한 field

ExternalSecret의 `remoteRef`는 핵심적으로 다음만 선언했다.

```yaml
remoteRef:
  key: /localy/prod/workload/order-db
  property: host
```

API 또는 controller가 live object에 default를 채울 수 있다.

```text
conversionStrategy
decodingStrategy
metadataPolicy
target.template.mergePolicy
```

개념적인 live 형태:

```yaml
remoteRef:
  key: /localy/prod/workload/order-db
  property: host
  conversionStrategy: Default
  decodingStrategy: None
  metadataPolicy: None
```

의미는 Git의 생략값과 같아도 구조적 diff는 생길 수 있다.

## 4.2 해결 선택지

선택 A — default를 Git에 명시:

```yaml
conversionStrategy: Default
decodingStrategy: None
metadataPolicy: None
```

장점:

```text
desired가 명확
diff 도구가 단순
API version 변경 시 의도 추적 가능
```

단점:

```text
반복 field 증가
CRD version별 default 차이
manifest가 구현 detail에 결합
```

선택 B — defaulted field를 ignore:

```yaml
jqPathExpressions:
  - .spec.data[].remoteRef.conversionStrategy
  - .spec.data[].remoteRef.decodingStrategy
  - .spec.data[].remoteRef.metadataPolicy
  - .spec.target.template.mergePolicy
```

이번에는 선택 B를 적용했다.

## 4.3 `.status`

ExternalSecret status는 ESO가 쓴다.

```yaml
status:
  conditions:
    - type: Ready
      status: "True"
      reason: SecretSynced
```

Git이 status를 선언하거나 Argo가 되돌려서는 안 된다.

```yaml
- group: external-secrets.io
  kind: ExternalSecret
  jqPathExpressions:
    - .status
```

---

# Step 5. `force-sync`가 만든 자기 드리프트

## 5.1 왜 추가했는가

ESO의 정기 refresh를 기다리지 않고 즉시 reconcile하기 위해 annotation을 사용했다.

```powershell
kubectl annotate externalsecret <name> `
  force-sync="<timestamp>" `
  --overwrite
```

annotation 값이 바뀌면 ESO가 reconcile하도록 자극하는 운영 패턴이다.

## 5.2 왜 OutOfSync가 되는가

Git에는 이 annotation이 없다.

```text
Git metadata.annotations:
  sync-wave 등 선언형 annotation만 있음

live metadata.annotations:
  force-sync=2026-07-31T...
```

따라서:

```text
운영 명령 성공
ESO SecretSynced
그러나 Argo는 OutOfSync
```

## 5.3 실제 정리

7개 ExternalSecret에서 annotation을 제거했다.

```text
order-db-secrets
payment-db-secrets
cart-redis-secrets
user-jwt-secrets
product-store-db-secrets
gateway-oauth-secrets
keycloak-secrets
```

또한 수동 `kubectl apply`가 남긴 다음 metadata도 일부 제거했다.

```text
kubectl.kubernetes.io/last-applied-configuration
```

## 5.4 current ignore rule의 모순

현재 Application에는 방어적으로 다음 rule도 들어 있다.

```yaml
- .metadata.annotations["force-sync"]
```

그러나 ledger에는 다음 원칙이 기록돼 있다.

```text
Never leave force-sync annotations on ExternalSecrets
```

두 정책은 긴장 관계에 있다.

```text
ignore:
  남아 있어도 Argo가 알리지 않음

운영 원칙:
  사용 후 반드시 제거
```

더 나은 방식:

```text
1. reconcile command가 annotation 추가
2. Ready/refreshTime 변경 대기
3. finally block에서 annotation 삭제
4. annotation 잔존 검사를 별도 gate로 실행
```

그렇게 만들면 `force-sync` ignore는 제거할 수 있다.

---

# Step 6. KEDA와 Deployment `replicas`

## 6.1 Git의 값

Deployment에는 안정적인 초기 replica가 선언돼 있다.

```yaml
spec:
  replicas: 2
```

## 6.2 KEDA의 역할

KEDA는 metric을 기반으로 HPA를 만들고 replica 수를 변경한다.

```text
Git desired:
  replicas=2

runtime:
  replicas=3, 5, 8 ...
```

이는 drift가 아니라 autoscaling의 목적이다.

## 6.3 ignore rule

```yaml
- group: apps
  kind: Deployment
  jsonPointers:
    - /spec/replicas
```

이 경계를 통해 역할을 나눈다.

```text
Argo CD:
  Deployment template과 배포 설정

KEDA/HPA:
  현재 replicas
```

## 6.4 ignore가 없을 때의 위험

```text
KEDA:
  replicas 2 → 6

Argo selfHeal:
  replicas 6 → 2

KEDA:
  replicas 2 → 6
```

두 controller가 같은 field를 반복해서 덮어쓰는 reconciliation loop가 생길 수 있다.

## 6.5 주의할 점

replicas를 ignore하면 Git의 `replicas: 2` 변경도 runtime에서 즉시 강제되지 않을 수 있다.

따라서 minimum replica의 authoritative source는 KEDA `ScaledObject`가 돼야 한다.

```yaml
minReplicaCount: 2
maxReplicaCount: 10
```

Git의 Deployment replica는 bootstrap/default 역할만 갖는다.

---

# Step 7. generated Secret의 주인은 ESO다

## 7.1 정상 ownership

```text
Git
  └─ ExternalSecret spec       ← Argo CD
       └─ Secret data/metadata ← ESO
```

Argo는 Secret의 실제 password 값을 Git에서 알지 못한다.

```text
AWS Secrets Manager
  → ESO
    → Kubernetes Secret.data
```

## 7.2 회고 5의 선행 문제

ExternalSecret tracking metadata가 generated Secret으로 복사되면서 Argo가 Secret을 자기 resource로 오인했다.

해결:

```yaml
target:
  template:
    metadata:
      labels:
        app.kubernetes.io/managed-by: external-secrets
      annotations:
        argocd.argoproj.io/compare-options: IgnoreExtraneous
        argocd.argoproj.io/sync-options: Prune=false
```

핵심은 generated Secret에 Argo instance tracking label이 전파되지 않게 한 것이다.

## 7.3 Application ignore

추가 방어:

```yaml
- group: ""
  kind: Secret
  jqPathExpressions:
    - .data
    - .metadata
    - .type
```

ESO가 쓰는 값과 metadata를 Argo diff에서 제외했다.

## 7.4 현재 rule은 너무 넓다

workload Application의 rule에는 Secret `name`이 없다.

즉 해당 Application이 추적하는 모든 Secret에 적용될 수 있다.

특히 `.metadata` 전체를 ignore하면 다음 drift도 가릴 수 있다.

```text
잘못된 label
보안 annotation 제거
ownerReference 변경
tracking metadata 이상
```

Keycloak Application은 적어도 name을 제한한다.

```yaml
name: localy-keycloak-secret
```

더 안전한 개선:

```text
generated Secret 이름으로 scope 제한
.data만 ignore
ESO가 실제로 변경하는 metadata key만 ignore
resource tracking에서 generated Secret 자체를 분리
```

`ignoreDifferences`는 ownership 설계의 보조 수단이지, broad wildcard로 모든 Secret drift를 덮는 도구가 아니다.

---

# Step 8. Root App-of-Apps의 자기 참조형 drift

## 8.1 parent가 child Application을 관리한다

```text
root-workloads
  ├─ order-service Application
  ├─ payment-service Application
  └─ ...
```

Git에는 child Application의 spec이 있다.

## 8.2 child controller가 runtime field를 쓴다

Argo application controller는 child에 다음을 기록한다.

```text
status.sync
status.health
status.resources
operation
refresh annotation
```

parent root가 이것까지 desired와 비교하면 child의 정상 작동이 parent drift가 된다.

## 8.3 root ignore rule

```yaml
- group: argoproj.io
  kind: Application
  jqPathExpressions:
    - .status
    - .operation
    - .metadata.annotations["argocd.argoproj.io/refresh"]
  jsonPointers:
    - /status
```

역할:

```text
root:
  child Application spec 관리

application controller:
  child status/operation 관리
```

`status`가 jq와 JSON pointer 양쪽에 중복돼 있는 것은 기능상 방어적이지만 정리 가능한 중복이다.

---

# Step 9. `ignoreDifferences`만으로 충분하지 않은 이유

## 9.1 diff 표시와 sync 동작

`ignoreDifferences`는 Argo가 비교할 때 특정 field를 제외하도록 한다.

하지만 sync 과정에서 apply가 그 field를 다시 원하는 값으로 밀어 넣으면 controller 충돌은 계속될 수 있다.

## 9.2 `RespectIgnoreDifferences=true`

```yaml
syncOptions:
  - RespectIgnoreDifferences=true
```

이 옵션은 sync에서도 ignore 경계를 존중하도록 한다.

개념적으로:

```text
ignoreDifferences만 있음:
  diff에서는 제외
  sync apply에서는 원하는 값이 개입할 가능성

RespectIgnoreDifferences:
  sync payload에서도 ignored live field를 보존
```

적용 대상:

```text
workload apps
keycloak
workload-dbs
karpenter apps
root-platform
root-workloads
```

## 9.3 초기 생성에는 desired 값이 필요하다

Argo CD의 ignore 처리에는 resource가 이미 존재할 때와 최초 생성할 때 차이가 있다.

resource가 없으면 보존할 live field가 없다.

따라서:

```text
Deployment 최초 생성:
  Git의 replicas가 사용될 수 있음

생성 이후:
  KEDA가 replicas 소유
```

이 점도 Deployment의 초기 `replicas`와 KEDA `minReplicaCount` 역할을 구분해야 하는 이유다.

---

# Step 10. Reloader PDB는 false positive가 아니었다

## 10.1 상태

Reloader는 HA 문제를 복구하며 다음 운영 모드로 바뀌었다.

```text
enableHA=false
replicas=1
PDB disabled
```

하지만 live cluster에는 이전 PDB가 남아 있었다.

```text
PodDisruptionBudget/reloader-reloader
```

## 10.2 왜 남았는가

Application 정책:

```text
prune=false
```

Git/Helm desired에서 resource가 사라져도 Argo가 자동 삭제하지 않는다.

```text
desired:
  PDB 없음

live:
  PDB 있음

prune=false:
  잔존
```

## 10.3 올바른 조치

PDB를 ignore하지 않고 삭제했다.

```powershell
kubectl delete pdb reloader-reloader `
  -n reloader
```

이 resource는 다른 controller가 소유한 동적 field가 아니다. 현재 desired state에서 제거된 실제 orphan이다.

## 10.4 중요한 구분

```text
KEDA replicas:
  정상 runtime mutation
  → ignore

ESO status:
  정상 controller field
  → ignore

force-sync:
  임시 운영 metadata
  → 제거

Reloader PDB:
  desired에서 제거된 잔존 resource
  → 삭제
```

모든 OutOfSync를 같은 방식으로 처리하면 안 된다.

---

# Step 11. Server-Side Apply와 managed fields

## 11.1 SSA의 목적

Server-Side Apply는 field별 manager를 기록한다.

```text
argocd-controller
external-secrets
keda/hpa-controller
karpenter
kubectl
```

`metadata.managedFields`는 누가 어느 field set을 관리하는지 보여준다.

## 11.2 ownership conflict 진단

다음 질문에 답하는 데 유용하다.

```text
이 field를 마지막으로 쓴 manager는 누구인가?
Argo와 controller가 같은 field를 claim하는가?
수동 kubectl이 ownership을 가져갔는가?
```

## 11.3 managedFields 자체는 desired가 아니다

`managedFields`는 API server가 관리한다.

Git에 저장하거나 내용 전체를 정합성 대상으로 볼 필요는 없다.

다만 무조건 metadata 전체를 ignore하기 전에 managedFields를 읽어 실제 충돌 field를 찾아야 한다.

```text
managedFields는 진단 증거
≠ Git desired field
```

---

# Step 12. 적용한 ignore policy

## 12.1 workload Application

```yaml
ignoreDifferences:
  - group: apps
    kind: Deployment
    jsonPointers:
      - /spec/replicas

  - group: external-secrets.io
    kind: ExternalSecret
    jqPathExpressions:
      - .status
      - .metadata.annotations["force-sync"]
      - .spec.data[].remoteRef.conversionStrategy
      - .spec.data[].remoteRef.decodingStrategy
      - .spec.data[].remoteRef.metadataPolicy
      - .spec.target.template.mergePolicy

  - group: ""
    kind: Secret
    jqPathExpressions:
      - .data
      - .metadata
      - .type
```

## 12.2 root Application

```yaml
ignoreDifferences:
  - group: argoproj.io
    kind: Application
    jqPathExpressions:
      - .status
      - .operation
      - .metadata.annotations["argocd.argoproj.io/refresh"]
```

## 12.3 sync option

```yaml
syncOptions:
  - RespectIgnoreDifferences=true
```

## 12.4 ledger

원인과 예외를 `outofsync-ledger.yaml`에 기록했다.

```text
ExternalSecret defaults/status/force-sync
ESO Secret data/metadata
KEDA replicas
root child Application runtime fields
Reloader orphan PDB cleanup
```

ignore rule은 코드만 보면 “왜 이 drift를 무시하는가”가 사라지기 쉽다. ledger는 예외의 근거와 이관된 문제를 보존한다.

---

# Step 13. 검증

## 13.1 단순 Application 상태만 보지 않았다

각 Application의 `status.resources`에서 OutOfSync resource를 집계했다.

```text
Application sync.status
  → 어떤 resource가 OutOfSync인가
    → 어떤 field가 다른가
```

## 13.2 force-sync 제거 후 hard refresh

임시 annotation과 orphan을 정리한 뒤 Application에 hard refresh를 요청했다.

```text
root-platform
root-workloads
root-app-of-apps
workload applications
platform applications
```

root를 먼저 반영해 child Application의 새 ignore policy가 live에 들어가도록 했다.

## 13.3 완료된 Synced 집합

```text
order
payment
cart
user
product
gateway
keycloak
workload-dbs
reloader
karpenter-controller
root-platform
root-workloads
root-app-of-apps
```

## 13.4 완료로 위장하지 않은 잔여

```text
ingress-core:
  Missing
  → 백로그 7

karpenter-provisioner:
  NodePool/EC2NodeClass hash·SSA drift
  → 백로그 9

kube-prometheus-stack / kyverno:
  Unknown health
  → 별도 관찰
```

한 범위가 끝났다고 전체 cluster를 `Synced`로 과장하지 않고 ledger에 이관 대상을 남겼다.

---

# Step 14. 어떤 ignore rule이 위험한가

## 14.1 넓은 object ignore

위험:

```yaml
jqPathExpressions:
  - .
```

resource 전체 drift를 숨긴다.

## 14.2 metadata 전체 ignore

현재 일부 Secret rule:

```yaml
- .metadata
```

숨길 수 있는 것:

```text
ownerReference
finalizer
security label
tracking annotation
managed-by label
```

가능하면 key 단위로 줄여야 한다.

## 14.3 spec 전체 ignore

controller가 default 몇 개를 추가한다고 `.spec` 전체를 ignore하면 실제 remote secret key, store reference, target name 변경도 탐지하지 못한다.

현재는 default field path만 지정한 점이 중요하다.

## 14.4 status를 spec처럼 다루기

status는 관측값이다. Git으로 강제할 대상이 아니다.

반대로 status가 이상하다는 이유로 ignore하면 운영 장애를 놓칠 수 있다는 주장도 가능하다. 여기서 구분해야 한다.

```text
Argo diff:
  status를 desired 비교에서 제외

모니터링:
  Ready=False, error condition은 별도로 alert
```

ignore는 관측을 포기한다는 뜻이 아니다.

---

# Step 15. 더 나은 장기 설계

## 15.1 ownership matrix

resource kind마다 field owner를 문서화한다.

```text
Deployment:
  template/spec 대부분 → Argo
  replicas → KEDA
  status → Deployment controller

ExternalSecret:
  spec → Argo
  status → ESO
  force-sync → ephemeral operation

Generated Secret:
  data → ESO
  selected metadata → ESO/security policy

Application:
  spec → parent root
  status/operation → Argo controller
```

## 15.2 ignore policy test

CI에서 Application manifest를 검사할 수 있다.

```text
[ ] RespectIgnoreDifferences 존재
[ ] Deployment ignore는 /spec/replicas만
[ ] ExternalSecret ignore는 알려진 default path만
[ ] Secret rule은 name으로 제한
[ ] .spec 또는 object 전체 ignore 금지
[ ] 모든 ignore에 근거 주석/ledger entry 존재
```

## 15.3 force reconcile 도구

수동 annotation 대신 반복 가능한 script:

```text
annotate
→ refreshTime 증가 대기
→ Ready=True 확인
→ annotation 삭제
→ 삭제 확인
```

PowerShell `try/finally`로 cleanup을 보장할 수 있다.

## 15.4 generated resource tracking

ESO generated Secret은 Argo tracking 대상이 되지 않도록 source metadata 전파를 제어한다.

```text
target.template.metadata 명시
Argo instance label 미전파
IgnoreExtraneous
Prune=false
```

Application-level broad Secret ignore보다 resource ownership 자체를 바로잡는 것이 우선이다.

## 15.5 prune 정책

전체 `prune=false`는 안전한 cutover에 유리하지만 orphan을 남긴다.

장기 상태:

```text
고위험 stateful/security resource:
  Delete=false / Prune=false 명시

재생성 가능한 stateless resource:
  검증 후 prune 허용

orphan:
  정기 inventory와 승인된 삭제
```

Reloader PDB 사건은 prune freeze에도 cleanup runbook이 필요하다는 증거다.

---

# Step 16. 운영 Runbook

## 16.1 OutOfSync 발견

```text
1. Health와 Sync를 분리해서 기록
2. status.resources에서 실제 resource 확인
3. desired/live diff를 field 단위로 확인
4. managedFields에서 writer 확인
5. controller documentation의 default/mutation 확인
```

## 16.2 분류

```text
Git에서 관리해야 하는 field:
  Git 수정 또는 live drift 복구

controller-owned runtime field:
  좁은 ignoreDifferences

임시 운영 metadata:
  작업 후 제거

desired에서 사라진 orphan:
  영향 확인 후 삭제/prune

실제 runtime 장애:
  ignore 금지, 원인 복구
```

## 16.3 ignore 추가 전 점검

```text
[ ] 정확한 field path인가
[ ] kind/name/namespace scope가 충분히 좁은가
[ ] 보안 metadata를 숨기지 않는가
[ ] writer가 하나로 정해졌는가
[ ] RespectIgnoreDifferences가 필요한가
[ ] alerting으로 runtime 상태를 계속 관측하는가
[ ] 제거 조건과 근거가 문서화됐는가
```

## 16.4 검증

```text
[ ] Application Synced
[ ] resource Health 정상
[ ] controller reconcile 정상
[ ] ignored field 외 실제 drift 없음
[ ] 임시 annotation 없음
[ ] orphan resource 없음
[ ] ledger 업데이트
```

---

## 최종 원인 트리

```text
리소스는 정상인데 Argo Application OutOfSync
│
├─ 정상 runtime mutation
│  ├─ KEDA → Deployment spec.replicas
│  ├─ ESO → ExternalSecret status
│  ├─ ESO/API → remoteRef default field
│  ├─ ESO → generated Secret data/metadata
│  └─ Argo controller → child Application status/operation
│
├─ 임시 운영 흔적
│  ├─ force-sync timestamp annotation
│  └─ kubectl last-applied annotation
│
├─ 실제 orphan
│  └─ enableHA=false 이후 남은 Reloader PDB
│
├─ 구조적 원인
│  ├─ field owner가 Application에 충분히 선언되지 않음
│  ├─ selfHeal과 autoscaler가 같은 field에 접근
│  ├─ generated Secret tracking 경계 불명확
│  └─ prune=false로 삭제가 자동화되지 않음
│
├─ 복구
│  ├─ force-sync/last-applied 제거
│  ├─ orphan PDB 삭제
│  ├─ 좁은 field ignore 추가
│  ├─ RespectIgnoreDifferences=true
│  ├─ root child runtime field ignore
│  └─ hard refresh 후 resource별 검증
│
└─ 남은 부채
   ├─ Secret metadata ignore 범위가 넓음
   ├─ force-sync ignore와 제거 원칙이 중복·모순
   ├─ ignore policy CI test 없음
   ├─ prune freeze orphan inventory 필요
   └─ Karpenter SSA drift는 회고 17로 이관
```

## 한 문장으로 남기는 교훈

**모든 차이를 없애는 것이 GitOps 정합성은 아니다. 정상적으로 변해야 하는 field의 주인을 명시하고, 임시 흔적과 실제 orphan은 무시하지 않고 제거하는 것이 정합성이다.**
