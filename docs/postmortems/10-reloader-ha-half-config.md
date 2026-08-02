# HA를 반만 켜면 가용성은 0이 된다

> Stakater Reloader의 `replicas`, `enableHA`, `POD_NAME`, Lease RBAC가 서로 다른 조건으로 렌더링된 사건

## 문서 정보

- 사건 시각: 2026-07-31 17:37~17:45 KST
- 환경: Amazon EKS 1.30, Argo CD Multi-Source, Stakater Reloader chart `1.0.69`
- 배포 방식: Helm chart + Git values
- Application: `reloader`
- namespace: `reloader`
- 최초 상태: Pod `CrashLoopBackOff`, Argo Application `Degraded`
- 직접 원인: 프로세스에 `--enable-ha=true`가 전달됐지만 `POD_NAME`이 없음
- 설정 원인: `deployment.replicas: 2`와 기본값 `enableHA: false`의 불완전한 조합
- 첫 번째 시도: `enableHA: true`를 live Application parameter로 주입
- 첫 번째 시도의 한계: Lease RBAC가 완성되지 않았고 Git desired state가 live patch를 되돌림
- 최종 복구: `enableHA: false`, `replicas: 1`, HA argument 제거
- 검증 결과: Pod `1/1 Running`, Argo `Healthy`, args는 `--reload-strategy=annotations`만 유지
- 영구 반영 commit: `35899fb`
- 남은 부채: Reloader 자체 HA가 필요하면 chart upgrade 또는 완전한 leader-election 계약 검증 필요

---

## Executive Summary

인프라 재배포 후 전체 플랫폼 health를 점검하던 중 Reloader Pod가 `CrashLoopBackOff`에 머물렀다.

로그는 원인을 직접 말하고 있었다.

```text
POD_NAME not set, cannot run in HA mode
```

처음 보면 단순한 환경변수 누락으로 보인다. 그러나 `POD_NAME` 하나를 추가하는 것만으로 해결하면 안 됐다. 프로세스가 왜 HA 모드로 진입했는지, HA를 의도했다면 leader election에 필요한 다른 조건은 준비됐는지 먼저 확인해야 했다.

Git values에는 다음 의도가 있었다.

```yaml
reloader:
  deployment:
    replicas: 2
```

`enableHA`는 명시하지 않았으므로 기본값은 `false`였다.

그러나 chart `1.0.69`의 렌더링 결과는 설정을 하나의 일관된 상태로 만들지 않았다.

```text
replicas > 1
  → 프로세스 args에 --enable-ha=true

enableHA = false
  → POD_NAME과 leader-election 관련 구성이 완전하게 준비되지 않음
```

그 결과 실제 Pod는 다음과 같은 모순된 계약을 받았다.

```text
프로세스:
  HA로 실행하라

환경:
  자신의 Pod 이름을 알 수 없음

권한:
  leader election Lease 사용 조건도 완성되지 않음
```

Reloader는 시작 직후 종료했고, replica를 늘린 목적과 반대로 가용성은 0이 됐다.

첫 대응으로 `enableHA: true`를 live Argo Application에 주입했다. 이 변경은 `POD_NAME` 오류를 넘기는 데는 도움이 됐지만, 관찰된 ClusterRole에는 Lease 권한이 없었고 live patch는 Git desired state에 포함되지 않아 Argo 계층에 의해 되돌아갔다.

최종 판단은 “지금 HA를 완성한다”가 아니라 “검증되지 않은 HA를 명시적으로 끈다”였다.

```yaml
reloader:
  enableHA: false
  deployment:
    replicas: 1
```

Git에 이 상태를 반영하고 Argo로 다시 동기화했다.

```text
Deployment replicas: 1
args: --reload-strategy=annotations
Pod: 1/1 Running
Application: Healthy
```

이 사건의 핵심은 replica 수가 아니다.

> 고가용성은 replica를 두 개로 만드는 속성이 아니라, identity·coordination·권한·장애 전환이 모두 충족돼야 하는 하나의 계약이다.

---

# Step 1. 발단 — Reloader만 반복해서 죽고 있었다

## 1.1 전체 플랫폼 점검에서 발견된 증상

재배포 직후 플랫폼 핵심 상태는 대체로 정상화돼 있었다.

```text
EKS nodes: Ready
Karpenter: Running
ESO: Running
Keycloak: Running
OTel: Running
node-local-dns: Running
```

남은 장애 중 하나가 Reloader였다.

```text
reloader Pod: CrashLoopBackOff
Argo Application: Degraded
```

Reloader 장애는 API 트래픽을 즉시 차단하지 않는다. 그래서 ingress나 database 장애보다 덜 심각하게 보일 수 있다.

하지만 Reloader가 맡은 역할을 고려하면 방치할 문제는 아니었다.

## 1.2 Reloader가 하는 일

애플리케이션 Pod는 일반적으로 시작할 때 Secret과 ConfigMap을 읽는다.

환경변수로 주입된 값은 원본 Secret이 바뀌어도 실행 중인 프로세스에 자동으로 다시 들어가지 않는다.

```text
Secrets Manager 값 변경
  → ESO가 Kubernetes Secret 갱신
    → 기존 Pod의 환경변수는 그대로
      → rollout 또는 재시작 필요
```

Reloader는 Secret 또는 ConfigMap 변경을 감지하고, 관련 Deployment나 StatefulSet의 Pod template annotation을 변경해 rollout을 유도한다.

```text
Secret/ConfigMap 변경
  → Reloader가 감지
    → workload annotation 갱신
      → 새 Pod 생성
        → 새 설정 로드
```

따라서 Reloader가 죽어 있으면 다음과 같은 지연 장애가 생길 수 있다.

```text
Secret 회전은 성공
ESO도 SecretSynced
하지만 애플리케이션은 과거 credential을 계속 사용
```

즉 Reloader 장애는 현재 요청 실패보다 **다음 설정 변경의 전파 실패**로 나타날 가능성이 높다.

## 1.3 로그는 환경변수 하나를 지목했다

컨테이너 로그의 핵심 메시지는 명확했다.

```text
POD_NAME not set, cannot run in HA mode
```

이 메시지에서 확인할 수 있는 사실은 두 가지다.

1. Reloader process는 자신이 HA 모드라고 판단했다.
2. HA mode가 요구하는 `POD_NAME` 환경변수는 없었다.

확인되지 않은 것은 다음과 같았다.

1. 누가 HA mode를 켰는가?
2. Git values의 의도와 실제 Deployment가 일치하는가?
3. `POD_NAME`만 추가하면 leader election이 완성되는가?

따라서 바로 Deployment에 env를 추가하지 않고, Git → Helm → Argo → Deployment 전달 경로를 역추적했다.

---

# Step 2. 기반 지식 — replica와 HA는 같은 말이 아니다

## 2.1 여러 Pod를 실행한다고 자동으로 HA가 되지 않는다

stateless HTTP server는 replica를 늘리는 것만으로도 요청 분산 효과를 얻을 수 있다. 하지만 cluster 전체를 watch하고 다른 resource를 수정하는 controller는 다르다.

Reloader replica 두 개가 동시에 같은 Secret 변경을 처리하면 다음과 같은 문제가 생길 수 있다.

```text
Pod A가 Secret 변경 감지
Pod B도 같은 변경 감지
둘 다 같은 Deployment annotation 수정
중복 rollout 또는 update conflict
```

따라서 여러 controller replica를 안전하게 운영하려면 일반적으로 leader election이 필요하다.

```text
replica A ─┐
           ├─ Lease 획득 경쟁 → leader 하나만 active reconcile
replica B ─┘
```

HA controller의 최소 구성은 다음과 같다.

```text
1. replica가 2개 이상
2. 각 Pod를 구별할 identity
3. leader election 활성화
4. coordination.k8s.io Lease 접근 권한
5. 같은 namespace의 Lease object
6. leader 장애 시 다른 replica가 takeover
```

하나라도 빠지면 “Pod가 여러 개”일 수는 있어도 “정상적인 HA controller”는 아니다.

## 2.2 `POD_NAME`은 왜 필요한가

leader election에 참여하는 각 process는 자신을 다른 후보와 구분할 identity가 필요하다.

Kubernetes에서는 Downward API로 현재 Pod 이름을 주입하는 패턴이 흔하다.

```yaml
env:
  - name: POD_NAME
    valueFrom:
      fieldRef:
        fieldPath: metadata.name
```

각 replica는 서로 다른 값을 받는다.

```text
reloader-reloader-6f9...-abcde
reloader-reloader-6f9...-fghij
```

Reloader가 HA mode에서 `POD_NAME`을 요구하는 이유는 이 값을 leader-election identity로 사용하기 위해서다.

따라서 오류 메시지는 단순히 문자열 하나가 없다는 뜻이 아니었다.

```text
POD_NAME 없음
  → 후보 identity 없음
    → 안전한 leader election 불가능
      → process가 시작을 거부
```

## 2.3 Lease RBAC도 별도의 계약이다

identity가 있어도 Kubernetes Lease를 읽고 생성하고 갱신할 권한이 없으면 leader election은 동작하지 않는다.

필요 권한은 대략 다음 형태다.

```yaml
apiGroups:
  - coordination.k8s.io
resources:
  - leases
verbs:
  - get
  - list
  - watch
  - create
  - update
  - patch
```

정확한 scope와 verb는 구현에 따라 다를 수 있지만, 핵심은 `POD_NAME`과 Lease RBAC가 서로 독립된 필수조건이라는 점이다.

```text
POD_NAME만 있음 + Lease 권한 없음
  → identity는 있지만 election 불가

Lease 권한 있음 + POD_NAME 없음
  → election resource는 만질 수 있지만 identity 없음
```

---

# Step 3. 조사 — Git values와 실제 Deployment를 함께 읽다

## 3.1 Git에 선언된 값

당시 values의 핵심은 replica 수였다.

```yaml
reloader:
  deployment:
    replicas: 2
```

`enableHA`는 명시되지 않았다.

```text
deployment.replicas = 2
enableHA = chart default false
```

작성자의 의도는 자연스럽게 추정할 수 있다.

```text
“controller도 두 개 띄우면 더 안전하겠지”
```

그러나 의도만으로 실제 chart rendering을 예측하면 안 된다.

## 3.2 Application은 Multi-Source였다

Reloader Application은 chart와 values를 서로 다른 source 역할로 조합했다.

```yaml
sources:
  - repoURL: https://stakater.github.io/stakater-charts
    chart: reloader
    targetRevision: 1.0.69
    helm:
      releaseName: reloader
      valueFiles:
        - $values/platform/reloader/values-prod.yaml

  - repoURL: https://github.com/hetrkumt/localy-manifests.git
    targetRevision: main
    ref: values
```

따라서 조사해야 할 계층은 네 개였다.

```text
Git values
  ↓
chart 1.0.69 template
  ↓
Argo rendered desired manifest
  ↓
live Deployment
```

Git 파일만 읽으면 chart가 어떤 조건문으로 args와 env를 생성했는지 알 수 없다. 반대로 live Deployment만 보면 그 값이 Git에서 왔는지 임시 patch에서 왔는지 알 수 없다.

## 3.3 live Deployment에서 본 모순

실제 Deployment를 확인한 목적은 다음 세 값을 한 번에 비교하는 것이었다.

```text
spec.replicas
containers[0].args
containers[0].env
```

관찰된 의미는 다음과 같았다.

```text
프로세스 args:
  --enable-ha=true 존재

환경변수:
  POD_NAME 없음
```

이 조합이 로그와 정확히 일치했다.

```text
--enable-ha=true
  → HA 초기화 경로 진입

POD_NAME 없음
  → "POD_NAME not set, cannot run in HA mode"
```

여기서 root cause는 Kubernetes가 env를 누락한 것이 아니었다. chart가 받은 두 값이 서로 다른 template 분기를 작동시킨 결과였다.

## 3.4 `helm template`로 재현하다

live state는 다른 controller나 수동 patch의 영향을 받을 수 있다. 따라서 같은 chart version과 values로 로컬 렌더링을 시도했다.

```powershell
helm pull stakater/reloader `
  --version 1.0.69 `
  --repo https://stakater.github.io/stakater-charts `
  --untar

helm template reloader .\reloader `
  -f platform/reloader/values-prod.yaml
```

그리고 다음 항목을 찾았다.

```text
replicas:
enable-ha
POD_NAME
```

이 과정의 목적은 “클러스터가 이상하다”와 “chart가 해당 입력에서 모순된 manifest를 만든다”를 분리하는 것이었다.

동일한 입력에서 같은 모순이 렌더링된다면 문제는 scheduler, kubelet, Argo sync가 아니라 chart values의 조합이다.

---

# Step 4. 첫 번째 해결 시도 — HA를 완성하려 했다

## 4.1 첫 판단은 합리적이었다

오류가 HA mode와 `POD_NAME` 불일치이므로 첫 번째 해결 방향은 다음과 같았다.

```yaml
reloader:
  enableHA: true
  deployment:
    replicas: 2
```

의도는 “HA를 끄는 것”이 아니라 “이미 두 replica를 원했으므로 HA 계약의 나머지도 켠다”였다.

Git values에 `enableHA: true`를 추가하고, Git push 전에 빠르게 검증하기 위해 live Argo Application의 Helm parameter에도 같은 값을 주입했다.

```text
reloader.enableHA=true
```

## 4.2 왜 live parameter를 먼저 넣었는가

Git commit 전에 runtime 결과를 보는 것은 다음 질문에 빠르게 답할 수 있다.

```text
POD_NAME이 실제로 추가되는가?
CrashLoop을 벗어나는가?
Lease RBAC도 생성되는가?
두 replica가 안정적으로 Running인가?
```

이런 live 실험은 진단 도구로 유용하다.

하지만 조건이 있다.

```text
실험값임을 명시
Git desired state와 차이를 기록
성공하면 즉시 Git에 반영
실패하면 원복
Argo selfHeal과 충돌 가능성 인지
```

## 4.3 첫 오류는 넘겼지만 HA는 완성되지 않았다

`enableHA: true`를 주입한 뒤 최초 `POD_NAME not set` CrashLoop은 넘어갔다.

그러나 다음 문제가 드러났다.

```text
관찰된 ClusterRole:
  coordination.k8s.io/leases 권한 없음
```

즉 process identity 문제를 해결해도 leader-election 권한 계약이 완성됐다고 볼 수 없었다.

이 지점에서 선택지는 세 가지였다.

```text
A. 필요한 Lease RBAC를 직접 추가
B. chart version 또는 values schema를 다시 조사해 정식 HA 구성
C. 현재 운영 요구에 맞춰 HA를 끄고 single replica로 복구
```

A는 가장 빠르지만 chart가 관리하는 RBAC 위에 별도 manifest를 덧대는 임시방편이다. chart upgrade 시 중복 또는 권한 drift가 생길 수 있다.

B는 장기적으로 더 낫지만, 당시 목표는 전체 재배포 검증 중 발견된 platform 장애를 안전하게 해소하는 것이었다. Reloader 한 컴포넌트 때문에 검증 범위를 chart upgrade까지 넓히는 것은 위험했다.

따라서 C가 선택됐다.

## 4.4 live Application patch가 되돌아갔다

첫 시도의 또 다른 문제는 변경 위치였다.

```text
Git desired state:
  enableHA 없음/false

live Application:
  Helm parameter enableHA=true
```

상위 Root Application과 Argo self-heal은 live Application도 Git 선언으로 되돌릴 수 있다.

실제로 live parameter는 지속되지 않았다.

```text
수동 patch
  → 잠시 live state 변경
    → Argo가 Git desired state 재적용
      → patch 소실
```

이것은 Argo가 방해한 것이 아니다. 선언형 제어면이 설계대로 동작한 것이다.

> GitOps 환경에서 live patch의 수명은 다음 reconciliation까지일 수 있다.

---

# Step 5. 최종 복구 — 불완전한 HA 대신 명시적인 single replica

## 5.1 운영 요구를 다시 판단하다

Reloader는 Secret·ConfigMap 변경에 반응하는 보조 controller다.

이상적인 상태는 HA일 수 있다. 그러나 당시 선택지는 다음 두 가지였다.

```text
검증되지 않은 HA:
  replica 2
  identity/RBAC 불확실
  현재 CrashLoop 또는 leader-election 실패

검증된 non-HA:
  replica 1
  leader election 불필요
  controller 기능 정상
```

가용성 관점에서도 두 번째가 더 나았다.

```text
불완전한 2 replicas = Running 0
정상 1 replica       = Running 1
```

replica 수가 많다는 이유만으로 첫 번째가 더 고가용성인 것은 아니다.

## 5.2 Git values를 하나의 일관된 상태로 만들다

최종 values는 다음과 같다.

```yaml
reloader:
  enableHA: false
  deployment:
    replicas: 1
  podDisruptionBudget:
    enabled: false
  watchGlobally: true
  reloadStrategy: annotations
```

각 설정의 의미는 일관된다.

```text
enableHA=false
  → leader election 사용 안 함

replicas=1
  → 동시에 실행되는 controller 하나

PDB disabled
  → 단일 replica에서 잘못된 availability 보장 흉내를 내지 않음

reloadStrategy=annotations
  → workload annotation 변경으로 rollout 유도
```

특히 단일 replica인데 PDB를 켜는 것은 주의해야 한다.

예를 들어 `minAvailable: 1`인 PDB는 voluntary disruption 중 Pod를 하나도 내릴 수 없게 해 node drain과 upgrade를 방해할 수 있다. HA가 아닌 상태에서 PDB만 추가해도 가용성이 생기지는 않는다.

## 5.3 live cutover와 Git 영구 수정의 순서

CrashLoop을 즉시 멈추기 위해 live Deployment에서 다음을 바꿨다.

```text
replicas: 1
args:
  - --reload-strategy=annotations
```

Argo가 과거 desired state를 다시 적용하지 않도록 self-heal을 잠시 멈추는 시도도 했다.

PowerShell에서 inline JSON patch가 깨지는 마찰이 있었기 때문에 patch file로 전달했고, 필요할 때는 Deployment를 명시적으로 교체했다.

하지만 live 변경은 최종 해결이 아니었다.

```text
live patch만 존재:
  다음 sync에서 원복
  다음 cluster rebuild에서 재발

Git values 수정:
  Argo desired state 변경
  다음 rebuild에도 동일 결과
```

따라서 `platform/reloader/values-prod.yaml`을 수정해 commit `35899fb`로 push하고 Argo를 hard refresh·sync했다.

## 5.4 최종 검증

복구 완료 조건을 Pod status 하나로 제한하지 않았다.

확인 항목은 다음과 같았다.

```text
Deployment replicas = 1
args에 --enable-ha 없음
args에 --reload-strategy=annotations 존재
Pod = 1/1 Running
rollout = successfully rolled out
Argo Application = Healthy
최근 log에 HA/POD_NAME 오류 없음
```

최종 상태:

```text
Pod: 1/1 Running
Application: Healthy
args: --reload-strategy=annotations
```

이로써 최초 오류의 원인 경로가 실제로 제거됐음을 확인했다.

---

# Step 6. 실패한 접근과 판단

## 6.1 `POD_NAME` env만 수동으로 추가

실행하지 않은 단순 처방이지만 가장 먼저 떠올리기 쉬운 방법이다.

```yaml
env:
  - name: POD_NAME
    valueFrom:
      fieldRef:
        fieldPath: metadata.name
```

이 방법은 최초 오류 메시지만 없앨 수 있다.

하지만 다음을 보장하지 않는다.

```text
Lease RBAC
leader-election resource scope
chart가 기대하는 다른 HA argument
두 replica의 실제 takeover
Git desired state 지속성
```

따라서 root cause 해결이 아니라 오류 한 줄을 다음 오류로 이동시키는 처방이 될 수 있다.

## 6.2 replica를 2로 두고 HA flag만 제거

프로세스가 leader election을 하지 않는 상태에서 controller 두 개를 실행하면 둘 다 active reconciler가 될 수 있다.

```text
replica 2
enableHA false
--enable-ha 없음
```

이 조합은 CrashLoop은 피할 수 있어도 중복 event 처리와 workload patch 경쟁 가능성을 만든다.

“HA flag를 제거하면 된다”가 아니라 “HA가 아니면 replica도 하나여야 한다”가 최종 판단이었다.

## 6.3 chart RBAC 위에 수동 ClusterRole patch 추가

Lease 권한만 별도로 추가하면 HA가 동작할 가능성은 있다.

그러나 다음 부채가 생긴다.

```text
chart 관리 resource와 별도 patch의 이중 SSOT
chart upgrade 때 권한 중복
정확한 최소 verb를 검증하지 않은 권한 확대
왜 patch가 필요한지 모르면 다음 운영자가 제거
```

긴급한 핵심 controller라면 고려할 수 있지만, 당시 Reloader에는 더 단순하고 안전한 single-replica 복구가 있었다.

## 6.4 live Argo Application parameter를 영구 설정으로 간주

Application 자체도 상위 GitOps root가 관리하고 있었다.

따라서 다음 명령이 성공했다고 영구 반영된 것은 아니다.

```text
kubectl patch application reloader ...
```

이 변경은 API server에는 저장되지만 Root Application의 desired state와 다르면 self-heal이 제거한다.

live patch는 실험 결과를 얻기 위한 수단이었고, 최종 SSOT는 Git values였다.

## 6.5 Argo self-heal을 장기적으로 끄기

live Deployment를 보호하기 위해 self-heal을 잠시 끄는 것은 복구 중 사용할 수 있다.

하지만 그대로 두면 다음 문제가 생긴다.

```text
Git 변경이 자동 반영되지 않음
수동 drift가 장기 잔존
다음 장애에서 desired/live 차이 해석 어려움
```

따라서 self-heal 중지는 영구 해결이 아니라 Git 수정과 sync 사이의 짧은 유지보수 창으로만 사용해야 한다.

---

# Step 7. 임시방편과 영구 해결을 구분하다

## 7.1 당시 사용한 임시방편

다음 작업은 진단 또는 즉시 복구를 위한 live operation이었다.

```text
Argo Application에 enableHA Helm parameter 주입
hard refresh / forced sync
selfHeal 일시 중지 시도
live Deployment replicas/args patch
CrashLoop Pod 삭제와 rollout 재시작
```

이 작업들은 당시 원인을 분리하고 서비스를 빠르게 복구하는 데 유용했다.

하지만 cluster가 재생성되면 모두 사라진다.

## 7.2 영구 해결

재발을 막은 변경은 하나다.

```text
platform/reloader/values-prod.yaml

enableHA: false
replicas: 1
PDB: false
```

이 값이 Git에 commit되고 Argo의 desired state가 됐기 때문에 다음 재배포에서도 같은 안전한 상태가 렌더링된다.

## 7.3 이것이 최종 아키텍처인가

아니다.

이 변경은 **현재 chart version에서 검증되지 않은 HA를 제거한 안정화 조치**다.

장기적으로 Reloader HA가 필요하다면 다음 대안을 평가해야 한다.

### 대안 A — chart upgrade

최신 chart에서 다음이 같은 조건으로 생성되는지 확인한다.

```text
replicas >= 2
--enable-ha
POD_NAME Downward API
coordination.k8s.io/leases RBAC
PDB
anti-affinity/topology spread
```

장점:

```text
upstream가 의도한 구성 사용
별도 RBAC patch 감소
향후 유지보수 용이
```

주의:

```text
values schema 변경 가능
CRD는 없지만 Deployment/RBAC diff 검증 필요
실제 leader failover test 필요
```

### 대안 B — 현재 version에서 완전한 HA overlay

chart를 고정해야 한다면 별도 manifest로 누락된 계약을 보충할 수 있다.

```text
enableHA=true
replicas=2
POD_NAME 주입 확인
Lease Role/RoleBinding 추가
Pod anti-affinity
PDB
```

그러나 chart와 overlay가 하나의 기능을 나눠 소유하므로 문서화와 테스트 부담이 커진다.

### 대안 C — single replica 유지

Reloader downtime이 허용되고 Secret 변경 시 수동 rollout 절차가 있다면 현재 구성이 가장 단순하다.

장점:

```text
중복 reconcile 없음
leader election 불필요
리소스 사용량 감소
동작 이해가 쉬움
```

단점:

```text
node drain 또는 Pod 장애 동안 변경 감지 중단
중단 중 발생한 event 처리 보장 확인 필요
Secret 회전 운영 절차가 Reloader에 의존하면 공백 발생
```

---

# Step 8. 더 나은 검증 방법

## 8.1 Helm values lint만으로 충분하지 않다

`values.yaml`은 YAML 문법상 올바를 수 있다.

문제는 서로 다른 값의 의미적 조합이었다.

따라서 CI에서 최종 manifest를 렌더링해 invariant를 검사해야 한다.

예:

```text
if replicas > 1:
  --enable-ha 존재
  POD_NAME 존재
  Lease RBAC 존재

if enableHA = false:
  replicas = 1
  --enable-ha 없음
```

## 8.2 정적 검증 예시

개념적으로 다음과 같은 검사를 둘 수 있다.

```powershell
$rendered = helm template reloader ... -f values-prod.yaml

# HA flag가 있으면 POD_NAME도 있어야 한다.
if ($rendered -match "--enable-ha" -and $rendered -notmatch "name: POD_NAME") {
    throw "Reloader HA invariant broken: POD_NAME missing"
}

# 여러 replica면 Lease RBAC가 있어야 한다.
if ($rendered -match "replicas: 2" -and $rendered -notmatch "coordination.k8s.io") {
    throw "Reloader HA invariant broken: Lease RBAC missing"
}
```

문자열 검사는 시작점일 뿐이다. 가능하면 YAML을 구조적으로 파싱해 Deployment와 RBAC를 검사하는 편이 안전하다.

## 8.3 runtime HA 검증

manifest가 올바르게 보인다고 HA가 입증된 것은 아니다.

진짜 HA를 채택한다면 다음 테스트가 필요하다.

```text
1. 두 Pod가 Running인지 확인
2. Lease holderIdentity 확인
3. leader Pod 삭제
4. 다른 Pod가 Lease를 획득하는지 확인
5. leader 전환 중 Secret 변경
6. workload rollout이 정확히 한 번 발생하는지 확인
7. 중복 patch/event가 없는지 log 확인
```

이 테스트를 통과해야 “replica가 두 개다”가 아니라 “failover가 동작한다”고 말할 수 있다.

## 8.4 기능 검증

Reloader Pod가 Running인 것만으로 본래 기능을 확인할 수는 없다.

기능 테스트는 다음과 같아야 한다.

```text
테스트 ConfigMap 생성
  → Reloader annotation을 가진 테스트 Deployment 연결
    → ConfigMap data 변경
      → Deployment Pod template annotation 변경 확인
        → 새 ReplicaSet/Pod 생성 확인
```

운영 Secret을 실제로 회전하지 않고도 rollout 기능을 검증할 수 있다.

---

# Step 9. 운영 관점에서의 영향

## 9.1 장애 중에도 서비스가 즉시 죽지 않은 이유

Reloader는 request path의 inline dependency가 아니다.

```text
사용자 요청
  → edge/service
    → database/message broker

Reloader:
  위 경로 밖에서 configuration change를 감시
```

따라서 기존 Pod와 기존 설정이 유효한 동안 사용자 요청은 계속 처리될 수 있다.

## 9.2 왜 그래도 중요했는가

이 프로젝트에서는 credential과 endpoint 변경이 잦았다.

```text
RDS password 정렬
Keycloak client secret 회전
Karpenter endpoint 전환
Grafana admin secret 생성
```

Reloader가 죽은 상태에서는 ESO가 새 Secret을 만들더라도 consumer Pod가 자동으로 새 값을 읽지 않을 수 있다.

이는 다음과 같은 오판을 만든다.

```text
Secrets Manager: 최신
ExternalSecret: SecretSynced
Kubernetes Secret: 최신
애플리케이션 process: 과거 값
```

control plane의 모든 status가 정상처럼 보여도 data plane process는 stale credential을 쓸 수 있다.

## 9.3 single replica의 운영 보완

HA를 끈 동안에는 다음 보완이 필요하다.

```text
Reloader PodNotReady alert
Secret 회전 후 workload rollout 검증
Reloader downtime 중 변경된 Secret 목록 기록
node drain 전 Reloader 상태 확인
재기동 후 test ConfigMap으로 기능 확인
```

Reloader 자체가 unavailable이면 운영자가 직접 다음을 수행할 수 있어야 한다.

```powershell
kubectl rollout restart deployment/<name> -n <namespace>
kubectl rollout status deployment/<name> -n <namespace>
```

단, 이것은 긴급 절차이며 GitOps와 Secret rotation runbook에 기록돼야 한다.

---

# Step 10. 재발 방지 설계

## 10.1 values에 계약을 주석으로 남기다

최종 values에는 단순 설정만 아니라 이유를 남겼다.

```yaml
# Chart quirk (v1.0.69): if deployment.replicas > 1 while enableHA=false,
# the template still adds --enable-ha=true but does NOT inject POD_NAME
# (or leases RBAC). Pods then CrashLoop.
#
# Enable HA only as a pair:
# enableHA=true AND replicas>=2.
```

주석의 목적은 과거 사건을 장황하게 기록하는 것이 아니다.

다음 운영자가 “가용성을 높이기 위해 replicas를 2로 올리자”고 생각할 때, 이 값이 독립적으로 변경 가능한 숫자가 아님을 경고하는 것이다.

## 10.2 chart version을 계약 일부로 취급한다

문제는 Reloader라는 제품 전체의 영구 속성으로 단정할 수 없다.

확인된 범위는 다음과 같다.

```text
chart: Stakater Reloader
version: 1.0.69
입력 조합: replicas 2 + enableHA false
관찰 결과: HA flag와 identity/RBAC 불일치
```

따라서 문서와 테스트는 version을 포함해야 한다.

chart upgrade 후에도 과거 workaround를 무조건 유지하면 오히려 최신 template의 정상 HA 구성을 막을 수 있다.

## 10.3 GitOps live patch 규칙

앞으로 controller 복구 중 live patch를 사용할 때 다음을 기록한다.

```text
patch 목적
적용 시각
Git과 다른 필드
selfHeal 중지 여부
원복 조건
영구 commit
최종 sync 결과
```

그리고 종료 조건을 명확히 한다.

```text
live state만 정상: 미완료
Git desired state 반영: 진행
Argo Synced/Healthy + 기능 검증: 완료
```

## 10.4 권장 acceptance criteria

### non-HA 운영

```text
[ ] enableHA=false
[ ] replicas=1
[ ] --enable-ha argument 없음
[ ] PDB가 single replica drain을 막지 않음
[ ] Pod 1/1 Running
[ ] Secret/ConfigMap 변경에 rollout 발생
[ ] PodNotReady alert 존재
```

### HA 운영

```text
[ ] enableHA=true
[ ] replicas>=2
[ ] 모든 Pod에 고유 POD_NAME
[ ] Lease RBAC 존재
[ ] Lease holder 확인
[ ] leader 삭제 후 failover 성공
[ ] 변경 event가 중복 처리되지 않음
[ ] anti-affinity/topology spread 적용
[ ] PDB가 replica 수와 일치
```

---

## 최종 원인 트리

```text
Reloader CrashLoopBackOff
│
├─ process가 HA mode로 시작
│  └─ --enable-ha=true argument 존재
│
├─ HA identity 누락
│  └─ POD_NAME 환경변수 없음
│
├─ 왜 반쪽 HA가 렌더링됐는가
│  ├─ deployment.replicas=2
│  ├─ enableHA는 기본 false
│  └─ chart 1.0.69이 두 값을 다른 template 조건에 사용
│
├─ 첫 번째 복구 시도
│  ├─ live Application에 enableHA=true 주입
│  ├─ 최초 POD_NAME 오류는 통과
│  ├─ 관찰된 Lease RBAC는 불완전
│  └─ Git desired state가 live patch를 되돌림
│
├─ 최종 복구
│  ├─ enableHA=false 명시
│  ├─ replicas=1
│  ├─ PDB 비활성
│  ├─ --enable-ha 제거
│  ├─ Git commit 후 Argo sync
│  └─ Pod 1/1 Running, Application Healthy
│
└─ 남은 과제
   ├─ chart upgrade 검토
   ├─ HA manifest invariant test
   ├─ leader failover runtime test
   └─ single-replica downtime 운영 절차
```

## 한 문장으로 남기는 교훈

**고가용성은 replica 숫자가 아니라 identity·leader election·권한·failover가 함께 만족해야 하는 계약이며, 그 계약을 검증하지 못했다면 정상적인 단일 replica가 실패하는 두 replica보다 안전하다.**
