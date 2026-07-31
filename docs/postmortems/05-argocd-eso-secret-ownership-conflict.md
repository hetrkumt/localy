# Secret의 값이 아니라 소유권이 충돌했다

> Argo CD tracking metadata가 ESO generated Secret으로 전파되어 두 컨트롤러가 같은 객체를 갱신한 사건

## 문서 정보

- 사건 시각: 2026-07-31 00:20~01:56 KST
- 환경: Argo CD, External Secrets Operator, Kubernetes Secret, AWS Secrets Manager
- 영향 리소스: `ExternalSecret/keycloak-secrets`, `Secret/localy-keycloak-secret`
- 최초 증상: `SecretSyncedError: could not update Secret`
- 직접 원인: Argo tracking label이 ESO generated Secret에 전파됨
- 구조적 원인: ExternalSecret과 generated Secret의 제어권 경계가 manifest에 명시되지 않음
- 복구 방해 요인: 강제 sync annotation, `kubectl apply` metadata, Secret 삭제·재생성
- 영구 수정: `target.template.metadata`로 metadata 전파 제어
- 방어 설정: `IgnoreExtraneous`, `Prune=false`, Argo `ignoreDifferences`
- 최종 상태: ExternalSecret `SecretSynced / Ready=True`, Keycloak Application Healthy

---

## Executive Summary

Keycloak의 RDS 비밀번호를 Terraform으로 복구한 뒤에도 새 password가 Kubernetes Secret에 안정적으로 반영되지 않았다. ExternalSecret 상태는 다음과 같았다.

```text
Reason:   SecretSyncedError
Message:  could not update Secret
```

처음에는 ESO cache, 손상된 Secrets Manager JSON, immutable Secret 또는 잘못된 ownerReference를 의심했다. generated Secret을 삭제하고 ESO가 다시 만들게 했지만 같은 오류가 반복됐다.

```text
secret "localy-keycloak-secret" deleted
externalsecret.external-secrets.io/keycloak-secrets annotated
reason=SecretSyncedError
msg=could not update Secret
```

문제는 Secret의 password 값이 아니었다. `Secret/localy-keycloak-secret` metadata에 다음 label이 붙어 있었다.

```yaml
argocd.argoproj.io/instance: keycloak
```

이 label은 단순 분류용 label이 아니라 Argo CD가 Application resource를 추적하는 데 사용하는 소유권 표식이었다.

원래 의도한 제어 관계는 다음과 같았다.

```text
Argo CD
  └─ ExternalSecret 선언 관리

ESO
  └─ Kubernetes Secret 생성·갱신

Keycloak Pod
  └─ Secret 읽기
```

하지만 ExternalSecret의 metadata가 generated Secret으로 전파되면서 실제 관계는 이렇게 됐다.

```text
Argo CD
  ├─ ExternalSecret 추적
  └─ generated Secret도 같은 Application resource로 추적

ESO
  └─ generated Secret 생성·갱신
```

두 controller가 같은 Kubernetes object의 metadata와 lifecycle에 관여하면서 `resourceVersion` 충돌이 발생했고 ESO update가 `could not update Secret`으로 실패했다. 중요한 점은 Git에 과거 password가 저장돼 있어 Argo가 password를 롤백한 사건이 아니라는 것이다. Git에는 generated Secret의 data가 없었다. 최신 password 반영이 경쟁 update 때문에 실패하거나 불안정해져 Secret이 “마지막으로 성공한 값”에 머물 수 있는 상황이었다.

ExternalSecret에 `spec.target.template.metadata`를 명시해 generated Secret에 허용할 metadata만 지정했다.

```yaml
metadata:
  labels:
    app.kubernetes.io/managed-by: external-secrets
  annotations:
    argocd.argoproj.io/compare-options: IgnoreExtraneous
    argocd.argoproj.io/sync-options: Prune=false
```

이후 generated Secret에서 Argo tracking label을 제거하고 ESO를 다시 reconcile하자 `SecretSynced / Ready=True`가 됐다. Application에는 Secret과 ExternalSecret runtime field를 무시하는 설정도 추가했다.

---

# Step 1. 발단 — AWS의 비밀번호는 고쳤는데 K8s Secret이 갱신되지 않았다

## 1.1 회고 3 복구 과정에서 나타난 별도 장애

Terraform은 RDS와 Secrets Manager에 동일한 새 password를 적용했다.

의도한 다음 단계:

```text
Secrets Manager 갱신
  → ESO refresh
    → Kubernetes Secret 갱신
      → Keycloak restart
```

그러나 ExternalSecret 상태는 Ready가 아니었다.

```text
reason=SecretSyncedError
message=could not update Secret
```

AWS provider에서 값을 읽지 못한 경우와 메시지가 달랐다.

```text
could not get secret data from provider
  → AWS Secret 읽기 또는 property 추출 실패

could not update Secret
  → 값을 읽은 뒤 Kubernetes Secret 쓰기 단계에서 실패
```

조사 대상은 Secrets Manager에서 Kubernetes API로 이동해야 했다.

## 1.2 Secret을 삭제해도 해결되지 않았다

stale object 또는 잘못된 Secret 구조를 의심해 generated Secret을 삭제하고 ESO 강제 sync를 수행했다.

```powershell
kubectl delete secret `
  -n auth-namespace `
  localy-keycloak-secret

kubectl annotate externalsecret `
  -n auth-namespace `
  keycloak-secrets `
  force-sync="<timestamp>" `
  --overwrite
```

결과:

```text
secret "localy-keycloak-secret" deleted
reason=SecretSyncedError
msg=could not update Secret
```

객체를 새로 만들어도 동일한 metadata와 controller 관계가 다시 만들어졌기 때문에 증상이 재발했다.

## 1.3 ESO를 재시작해도 해결되지 않았다

controller cache 문제를 의심해 ESO Deployment를 rollout restart했다.

```text
deployment "external-secrets" successfully rolled out
```

하지만 결과는 같았다.

```text
reason=SecretSyncedError
msg=could not update Secret
```

재시작으로 사라지지 않는다는 사실은 in-memory cache보다 선언된 metadata와 reconciliation 구조를 의심하게 했다.

## 1.4 Keycloak이 Running인 사실이 문제를 숨겼다

일부 시점에는 Keycloak Pod가 Running이었다. 그러나 이는 Secret 동기화가 건강하다는 증거가 아니었다.

Pod는 마지막으로 성공한 Secret 값을 사용해 기동할 수 있다.

```text
Secret update 실패
  ≠
기존 Secret 즉시 삭제
```

따라서 다음 상태가 동시에 가능했다.

```text
Keycloak Pod:       Running
ExternalSecret:     SecretSyncedError
Secret 최신성:      보장 불가
향후 rotation:      실패 가능
```

현재 장애가 가려졌을 뿐 credential rotation 경로는 깨져 있었다.

---

# Step 2. 기반 지식 — 생산자, 소비자, 선언 관리자는 서로 다르다

## 2.1 세 주체의 역할

### Argo CD

Git의 desired manifest와 Kubernetes live object를 비교하고 reconcile한다.

```text
Git → Kubernetes
```

### External Secrets Operator

외부 provider에서 값을 읽어 Kubernetes Secret을 생성하고 갱신한다.

```text
AWS Secrets Manager → Kubernetes Secret
```

### Keycloak Pod

Kubernetes Secret을 env 또는 volume으로 읽는 소비자다.

```text
Kubernetes Secret → application process
```

Argo CD는 Secret을 “가져다가 Keycloak에 전달하는 중간 소비자”가 아니다.

잘못 이해하기 쉬운 흐름:

```text
ESO → Argo → Pod
```

실제 흐름:

```text
Argo → ExternalSecret 선언
ESO  → Secret 생성
Pod  → Secret 읽기
```

## 2.2 ExternalSecret과 Secret은 서로 다른 객체다

ExternalSecret:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: keycloak-secrets
```

이 객체에는 비밀값 대신 “어디서 무엇을 가져올지”가 있다.

```yaml
remoteRef:
  key: localy-prod-database-credentials
  property: password
```

generated Secret:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: localy-keycloak-secret
data:
  KEYCLOAK_DATABASE_PASSWORD: ...
```

이 객체에 Pod가 실제로 읽는 값이 있다.

원하는 owner:

```text
ExternalSecret spec/status  → Argo + ESO 각자 담당 field
generated Secret data       → ESO
```

## 2.3 Argo tracking label의 의미

Argo CD는 Application에 속한 resource를 추적하기 위해 다음과 같은 label을 사용할 수 있다.

```yaml
argocd.argoproj.io/instance: keycloak
```

이것은 단순히 “Keycloak과 관련 있음”을 표시하는 업무 label과 다르다.

```text
app.kubernetes.io/name=keycloak
  → 업무 분류

argocd.argoproj.io/instance=keycloak
  → Argo Application resource tracking
```

tracking label이 generated Secret에 생기면 Argo는 해당 Secret을 Keycloak Application과 연관된 live resource로 인식할 수 있다.

## 2.4 Kubernetes ownerReference는 exclusive lock이 아니다

ExternalSecret의 설정:

```yaml
target:
  creationPolicy: Owner
```

ESO는 generated Secret에 ExternalSecret ownerReference를 설정한다. 하지만 이것이 다른 controller의 write를 기술적으로 금지하는 lock은 아니다.

```text
ownerReference:
  garbage collection 관계

managedFields:
  field manager 기록

RBAC:
  API write 권한

resourceVersion:
  optimistic concurrency
```

Kubernetes에는 “이 객체는 ESO만 수정 가능”이라는 자동 exclusive ownership이 없다. 제어권은 controller 설계, tracking metadata, RBAC, field ownership을 함께 정리해야 한다.

## 2.5 optimistic concurrency란 무엇인가

Kubernetes object에는 `resourceVersion`이 있다.

```text
1. ESO GET Secret, resourceVersion=100
2. Argo UPDATE/PATCH Secret → resourceVersion=101
3. ESO가 version=100 기준 UPDATE
4. API server가 거부
```

대표 오류:

```text
the object has been modified;
please apply your changes to the latest version and try again
```

controller는 보통 다시 읽고 retry한다. 하지만 다른 writer가 계속 같은 객체를 수정하면 반복 충돌과 flap이 생길 수 있다.

## 2.6 `ignoreDifferences`와 “소유권 포기”는 같지 않다

Argo Application의 `ignoreDifferences`는 특정 field의 diff를 비교·sync에서 무시하도록 돕는다.

```yaml
ignoreDifferences:
  - kind: Secret
    name: localy-keycloak-secret
    jqPathExpressions:
      - .data
      - .metadata
      - .type
```

하지만 이것만으로 generated Secret의 tracking metadata가 사라지는 것은 아니다. 가장 중요한 수정은 처음부터 tracking label이 generated Secret에 전파되지 않도록 하는 것이다.

```text
1차 해결: 잘못된 resource tracking 방지
2차 방어: runtime diff와 prune 방지
```

---

# Step 3. CCTV 추적 — 라벨 하나가 두 번째 writer를 만든 순간

## 3.1 Argo CD가 ExternalSecret을 적용한다

Git에는 ExternalSecret manifest가 있었다.

```text
Application/keycloak
  → ExternalSecret/keycloak-secrets
```

Argo CD는 이 resource를 추적하기 위해 metadata를 부여했다.

```yaml
argocd.argoproj.io/instance: keycloak
```

ExternalSecret에 이 label이 있는 것은 정상이다. ExternalSecret 선언 자체는 Git이 관리하기 때문이다.

## 3.2 ESO가 AWS Secret 값을 읽는다

ESO는 다음 property를 읽었다.

```text
localy-prod-keycloak-admin.username
localy-prod-keycloak-admin.password
localy-prod-database-credentials.password
localy-prod-database-credentials.host
```

그 결과 `localy-keycloak-secret`을 생성하거나 갱신하려 했다.

## 3.3 ExternalSecret metadata가 generated Secret으로 전파된다

당시 ExternalSecret에는 target template metadata가 명시되지 않았다.

관찰된 generated Secret:

```yaml
metadata:
  labels:
    argocd.argoproj.io/instance: keycloak
```

즉 Argo tracking label이 generated Secret까지 도달했다.

```text
ExternalSecret
  [argocd instance=keycloak]
       │
       │ ESO target metadata 생성
       ▼
Secret
  [argocd instance=keycloak]
```

## 3.4 Argo가 generated Secret을 Application resource로 추적한다

Git에는 `Secret/localy-keycloak-secret`의 data manifest가 없었다. Git에는 ExternalSecret만 있었다.

그럼에도 tracking label로 인해 generated Secret이 Keycloak Application의 resource graph에 들어왔다.

```text
Argo:
  "keycloak Application 소속 resource"

ESO:
  "내가 creationPolicy=Owner로 만든 target Secret"
```

두 controller의 관심 범위가 같은 객체에서 겹쳤다.

## 3.5 ESO update가 충돌한다

ESO는 Secrets Manager에서 읽은 최신 값을 Secret에 반영하려 했다.

동시에 Argo는 tracking, compare, apply, prune 판단을 위해 metadata와 live resource를 reconcile했다.

결과:

```text
SecretSyncedError
could not update Secret
```

Secret을 삭제해도 ExternalSecret으로부터 같은 tracking metadata를 가진 Secret이 다시 만들어졌기 때문에 재발했다.

## 3.6 Pod는 마지막으로 성공한 Secret 값을 계속 사용한다

이 사건에서 Git에 과거 Secret data는 없었다. 따라서 다음 설명은 정확하지 않다.

```text
Argo가 Git의 옛 password로 Secret을 되돌렸다.
```

더 정확한 설명:

```text
ESO의 최신값 update가 안정적으로 완료되지 않음
  → Secret은 마지막 성공값에 머물 수 있음
    → Pod는 그 값을 계속 사용
```

또한 Secret을 env로 주입받는 Pod는 Secret object가 갱신돼도 프로세스 env가 자동으로 바뀌지 않는다. 별도 rollout이 필요하다.

```text
AWS Secret 갱신
  → K8s Secret 갱신
    → Pod rollout
      → 새 process env 사용
```

이번 회고의 직접 원인은 첫 번째와 두 번째 구간의 owner 충돌이며, rollout 자동화는 별도 운영 항목이다.

---

# Step 4. 삽질과 해결 — 객체를 지우는 대신 writer를 한 명으로 줄였다

## 4.1 실패한 접근: Secret 삭제

generated Secret을 삭제하고 ESO가 다시 만들도록 했다.

```powershell
kubectl delete secret `
  -n auth-namespace `
  localy-keycloak-secret
```

이 접근이 실패한 이유:

```text
문제 객체를 삭제
  → ExternalSecret은 그대로
    → 같은 metadata 규칙으로 Secret 재생성
      → 같은 tracking label 재발
        → 같은 충돌
```

원인을 만든 template을 고치지 않고 결과 객체만 지운 셈이다.

## 4.2 실패한 접근: ESO controller 재시작

ESO cache가 과거 Secret 상태를 들고 있다고 가정하고 restart했다.

```powershell
kubectl -n external-secrets rollout restart `
  deployment/external-secrets
```

controller process는 새로 시작됐지만 live object metadata와 Argo tracking 관계는 그대로였다.

```text
process state 초기화
≠
declarative state 변경
```

따라서 오류가 지속됐다.

## 4.3 진단용 `force-sync`가 새로운 OutOfSync를 만든다

ESO reconciliation을 즉시 유도하기 위해 다음 annotation을 추가했다.

```yaml
force-sync: "2026-07-31T..."
```

이 annotation은 Git에 없었기 때문에 ExternalSecret이 Argo에서 OutOfSync로 보였다.

```text
live ExternalSecret:
  force-sync=<timestamp>

Git ExternalSecret:
  force-sync 없음
```

진단이 끝난 뒤 제거했다.

```powershell
kubectl annotate externalsecret `
  -n auth-namespace `
  keycloak-secrets `
  force-sync-
```

운영 객체에 임시 annotation을 붙이면 반드시 cleanup까지 runbook에 포함해야 한다.

## 4.4 핵심 수정: generated Secret metadata를 명시한다

ExternalSecret target template에 generated Secret이 가질 metadata를 명시했다.

```yaml
spec:
  target:
    name: localy-keycloak-secret
    creationPolicy: Owner
    deletionPolicy: Retain
    template:
      engineVersion: v2
      metadata:
        labels:
          app.kubernetes.io/name: keycloak
          app.kubernetes.io/component: credentials
          app.kubernetes.io/managed-by: external-secrets
        annotations:
          argocd.argoproj.io/compare-options: IgnoreExtraneous
          argocd.argoproj.io/sync-options: Prune=false
```

핵심은 allowlist 방식이다.

```text
이전:
ExternalSecret metadata가 generated Secret으로 암묵적으로 전파

이후:
generated Secret metadata를 명시적으로 정의
```

Argo tracking label은 allowlist에 없으므로 generated Secret에 남지 않는다.

## 4.5 `managed-by` label은 선언적 경계를 설명한다

```yaml
app.kubernetes.io/managed-by: external-secrets
```

이 label은 Kubernetes API에서 다른 writer를 막는 보안 장치는 아니다. 그러나 운영자와 도구에 expected owner를 명확히 전달한다.

```text
기술적 차단:
  tracking 제거, Argo 설정, RBAC/field behavior

운영 가시성:
  managed-by label
```

label의 의미를 과대평가하지 않되 ownership 문서로 활용한다.

## 4.6 `IgnoreExtraneous`와 `Prune=false`

generated Secret annotation:

```yaml
argocd.argoproj.io/compare-options: IgnoreExtraneous
argocd.argoproj.io/sync-options: Prune=false
```

의도:

```text
IgnoreExtraneous:
  Git에 직접 정의되지 않은 generated resource 때문에
  Application 전체를 OutOfSync로 만들지 않음

Prune=false:
  Argo prune 판단으로 generated Secret을 삭제하지 않도록 방어
```

primary owner는 계속 ESO다.

## 4.7 Application의 방어 설정

Keycloak Application에는 다음을 추가했다.

```yaml
ignoreDifferences:
  - group: ""
    kind: Secret
    name: localy-keycloak-secret
    jqPathExpressions:
      - .data
      - .metadata
      - .type

  - group: external-secrets.io
    kind: ExternalSecret
    jqPathExpressions:
      - .status
```

sync option:

```yaml
- RespectIgnoreDifferences=true
```

의미:

- Secret data는 외부 provider와 ESO가 결정한다.
- Secret metadata도 ESO lifecycle에서 변할 수 있다.
- ExternalSecret status는 ESO controller가 기록한다.
- Argo가 runtime field를 desired manifest로 되돌리지 않는다.

다만 generated Secret이 Git desired resource가 아닌 구조에서는 `target.template.metadata`와 `IgnoreExtraneous`가 ownership 경계를 세우는 핵심이고, Application ignore는 방어 계층으로 보는 것이 정확하다.

## 4.8 live object의 기존 tracking label을 제거한다

Git manifest를 고쳐도 이미 생성된 Secret에는 과거 label이 남아 있을 수 있다.

```powershell
kubectl label secret `
  -n auth-namespace `
  localy-keycloak-secret `
  argocd.argoproj.io/instance- `
  --overwrite
```

과거 sync-wave annotation도 제거했다.

```powershell
kubectl annotate secret `
  -n auth-namespace `
  localy-keycloak-secret `
  argocd.argoproj.io/sync-wave- `
  --overwrite
```

그 뒤 ExternalSecret을 reconcile했다.

## 4.9 `kubectl apply`가 남긴 metadata도 정리한다

응급 적용은 다음 annotation을 남길 수 있다.

```yaml
kubectl.kubernetes.io/last-applied-configuration: ...
```

Git/Argo desired manifest에는 이 annotation이 없어 또 다른 OutOfSync 원인이 됐다.

```powershell
kubectl annotate externalsecret `
  -n auth-namespace `
  keycloak-secrets `
  kubectl.kubernetes.io/last-applied-configuration-
```

live patch는 복구를 빠르게 하지만 desired state와의 차이를 추가로 만들 수 있다.

## 4.10 검증

수정 후:

```text
ExternalSecret:
  Reason=SecretSynced
  Ready=True

generated Secret:
  argocd.argoproj.io/instance 없음
  app.kubernetes.io/managed-by=external-secrets

Application:
  Health=Healthy
```

Git push 전에는 live object와 Git desired state가 달라 OutOfSync가 남을 수 있었다. 따라서 마지막 단계는 수정된 manifest를 Git에 반영하는 것이었다.

---

# Step 5. 넥스트 스텝 — 선언형 시스템에서는 writer 수를 세어라

## 5.1 가장 중요한 설계 원칙

> 하나의 동적 field에는 하나의 authoritative writer만 있어야 한다.

Keycloak Secret의 역할 분리:

```text
ExternalSecret spec:
  Git/Argo가 선언

ExternalSecret status:
  ESO가 기록

generated Secret data:
  ESO가 기록

generated Secret 소비:
  Keycloak Pod가 read-only로 사용
```

## 5.2 owner와 consumer를 구분한다

```text
ESO:
  producer + writer

Keycloak:
  consumer + reader

Argo:
  ExternalSecret declaration manager
```

Pod가 Secret을 읽는다는 이유로 Pod나 Helm release가 Secret owner가 되는 것은 아니다. Application과 관련 있다는 이유로 Argo tracking label을 붙이는 것도 안전하지 않다.

## 5.3 controller 충돌 진단 체크리스트

### 1. 오류 동사를 본다

```text
could not get secret data
  → provider read 문제

could not create Secret
  → RBAC/admission/name 문제

could not update Secret
  → write conflict/immutable/RBAC 문제

object has been modified
  → resourceVersion 경쟁
```

### 2. metadata를 확인한다

```powershell
kubectl get secret localy-keycloak-secret `
  -n auth-namespace `
  -o jsonpath="{.metadata.labels}{'\n'}{.metadata.annotations}{'\n'}"
```

### 3. ownerReference와 managedFields를 확인한다

```powershell
kubectl get secret localy-keycloak-secret `
  -n auth-namespace `
  -o json
```

확인 대상:

```text
metadata.ownerReferences
metadata.managedFields[].manager
metadata.resourceVersion
```

### 4. Argo resource graph를 확인한다

```powershell
kubectl get application keycloak `
  -n argocd `
  -o jsonpath="{range .status.resources[*]}{.kind}/{.name}{'\n'}{end}"
```

generated resource가 예상치 않게 Application에 속해 있는지 본다.

### 5. 객체 삭제보다 생성 규칙을 먼저 본다

```text
삭제 후 같은 오류 재발
  → controller가 같은 규칙으로 다시 생성
```

결과 객체보다 source CR과 template을 수정해야 한다.

## 5.4 Secret rotation의 전체 경로를 검증한다

SecretSynced만으로 애플리케이션이 새 password를 쓰는 것은 아니다.

```text
1. Terraform이 SM 갱신
2. ESO가 K8s Secret 갱신
3. SecretSynced=True
4. workload rollout
5. 새 Pod가 새 Secret 값 로드
6. DB 인증 성공
```

env 기반 Secret consumer는 일반적으로 restart가 필요하다. Reloader가 이 역할을 맡는다면 Reloader 자체의 health도 acceptance criteria에 포함해야 한다.

## 5.5 global resource exclusion을 사용하지 않은 이유

Argo CD 전체에서 모든 Secret을 exclude하는 방법도 있다.

하지만 그렇게 하면 Git으로 의도적으로 관리하는 TLS Secret, bootstrap Secret, non-sensitive generated config까지 관측 범위에서 사라질 수 있다.

```text
global exclusion:
  영향 범위가 너무 큼

resource-specific metadata/ignore:
  Keycloak generated Secret만 제어
```

최소 범위 수정이 적절했다.

## 5.6 보안상 주의점

Argo가 Secret data diff를 무시한다고 해서 Secret 보안이 자동으로 강화되는 것은 아니다.

별도로 필요한 것:

- ESO controller 최소 AWS IAM 권한
- namespace RBAC
- etcd encryption
- Secret 값 로그 출력 금지
- Pod read 권한 제한
- rotation과 restart 검증

`ignoreDifferences`는 reconciliation 정책이지 access control이 아니다.

## 5.7 재구축 acceptance criteria

```text
[ ] ExternalSecret에 Argo tracking label 존재
    (ExternalSecret은 Argo 관리 대상이므로 정상)

[ ] generated Secret에는 Argo tracking label 없음

[ ] generated Secret managed-by=external-secrets

[ ] ExternalSecret Ready=True / SecretSynced

[ ] Application이 generated Secret 때문에 OutOfSync가 되지 않음

[ ] Argo prune이 generated Secret을 삭제하지 않음

[ ] SM rotation 후 K8s Secret resourceVersion 변경

[ ] workload rollout 후 새 credential로 인증 성공
```

## 5.8 재발 방지 체크리스트

- [ ] operator가 생성하는 child resource의 metadata 전파 규칙을 확인한다.
- [ ] Argo tracking label을 일반 업무 label처럼 복사하지 않는다.
- [ ] generated resource에는 authoritative controller를 표시한다.
- [ ] ExternalSecret status는 Git diff 대상에서 제외한다.
- [ ] Secret data를 Argo desired state로 선언하지 않는다.
- [ ] generated Secret을 prune하지 않는다.
- [ ] 강제 sync annotation은 진단 후 제거한다.
- [ ] `kubectl apply`의 last-applied annotation을 고려한다.
- [ ] Secret 삭제를 근본 해결로 간주하지 않는다.
- [ ] Running Pod와 Secret rotation health를 별도로 평가한다.
- [ ] 하나의 field에 여러 writer가 있는지 managedFields로 확인한다.

---

## 최종 원인 트리

```text
ExternalSecret SecretSyncedError
│
├─ 직접 증상
│  └─ could not update Secret
│
├─ writer 충돌
│  ├─ ESO
│  │  └─ localy-keycloak-secret 생성·갱신
│  │
│  └─ Argo CD
│     └─ 같은 Secret을 Keycloak Application resource로 추적
│
├─ tracking이 생긴 이유
│  └─ ExternalSecret의 argocd instance label이
│     generated Secret metadata로 전파
│
├─ 실패한 복구
│  ├─ Secret 삭제
│  ├─ ESO restart
│  └─ force-sync 반복
│
├─ 복구 중 추가 drift
│  ├─ force-sync annotation
│  └─ kubectl last-applied annotation
│
└─ 최종 해결
   ├─ target.template.metadata 명시
   ├─ generated Secret에서 Argo tracking 제거
   ├─ managed-by=external-secrets
   ├─ IgnoreExtraneous + Prune=false
   └─ Application ignoreDifferences
```

## 한 문장으로 남기는 교훈

**선언형 시스템에서 같은 객체를 두 controller가 “내 것”이라고 판단하면, 값이 정확해도 reconciliation은 실패한다.**

