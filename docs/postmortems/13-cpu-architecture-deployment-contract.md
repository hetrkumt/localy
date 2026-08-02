# 노드는 준비됐는데 컨테이너가 실행되지 않았다

> Karpenter가 허용한 Graviton 노드와 `linux/amd64` 단일 플랫폼 이미지 사이의 숨은 배포 계약

## 문서 정보

- 사건 시각: 2026-07-31 22:00~22:12 KST
- 환경: Amazon EKS 1.30, Karpenter 0.37.0, Amazon ECR, Docker Buildx
- 대상: workload NodePool, 6개 workload Deployment, Keycloak, database bootstrap Job
- 선행 사건: 회고 12의 빈 ECR 및 image tag 공급망 복구
- 최초 분류: image pull·실행 실패 가능성이 있는 workload scheduling 정책
- 직접 원인:
  - workload NodePool은 `amd64`, `arm64`를 모두 허용
  - instance allowlist에 Graviton `c7g`, `m7g` 포함
  - workload image는 `linux/amd64`로만 build
- 구조적 원인: node provisioning 정책과 image build platform이 서로 다른 저장소에서 독립적으로 변경됨
- 즉시 조치:
  - workload NodePool을 `amd64`로 제한
  - Graviton instance type 제거
  - workload·Keycloak·bootstrap Job에 `kubernetes.io/arch: amd64` 추가
- build 조치: `docker buildx --platform linux/amd64`
- 변경 commit: `a1d4286` (`fix(arch): pin workload NodePool and pods to amd64`)
- 검증:
  - workload NodePool `arch=["amd64"]`
  - Graviton type 없음
  - 대상 Pod/Job nodeSelector에 `amd64`
  - live node 모두 `amd64`
- 동기화 예외: Argo CD force sync 중 controller panic이 발생해 NodePool은 일시적으로 `kubectl` Server-Side Apply
- 장기 대안: 검증된 multi-architecture image index와 digest 기반 배포
- 남은 부채: ECR tag 존재 검사는 하지만 manifest platform까지 자동 검증하지 않음

---

## Executive Summary

회고 12에서 비어 있던 ECR에 application image를 다시 build·push했다. 이제 필요한 repository와 tag가 존재했지만, 그것만으로 모든 Karpenter node에서 image를 실행할 수 있다는 뜻은 아니었다.

당시 workload NodePool은 두 CPU architecture를 모두 허용했다.

```yaml
- key: kubernetes.io/arch
  operator: In
  values: ["amd64", "arm64"]
```

instance type 목록에도 두 계열이 섞여 있었다.

```text
x86-64:
  c6i, c6a, m6i, m6a

ARM64:
  c7g, m7g
```

반면 workload image 공급망은 `linux/amd64`만 보장했다.

```bash
docker buildx build \
  --platform linux/amd64 \
  ...
```

Kubernetes scheduler와 Karpenter는 Pod가 요구한 CPU·memory·taint·affinity만으로 placement를 결정한다. Pod가 architecture를 요구하지 않으면 Karpenter 입장에서는 `arm64` Graviton도 유효한 node다.

```text
Pod:
  workload pool만 요구
  architecture 조건 없음

NodePool:
  amd64 또는 arm64 허용

Karpenter:
  비용·가용성 조건에 맞는 c7g/m7g 선택 가능

Image:
  linux/amd64만 존재

결과:
  scheduling은 성공할 수 있지만 image 실행 계약은 실패
```

이 문제는 scheduler 오류가 아니다. scheduler가 알 수 있도록 architecture 조건을 선언하지 않은 배포 계약 오류다.

즉시 복구에서는 multi-arch image를 급히 만들지 않았다. 현재 검증된 artifact가 `amd64`뿐이라는 사실을 기준으로 세 계층을 정렬했다.

```text
CI:
  linux/amd64 image만 build

Karpenter:
  workload NodePool은 amd64 node만 생성

Pod/Job:
  kubernetes.io/arch=amd64 node만 선택
```

그리고 Graviton `c7g`, `m7g`를 workload instance allowlist에서 제거했다.

이 결정은 Graviton의 비용 효율을 포기한 영구 최적화가 아니라, 검증되지 않은 architecture 혼합을 중단한 안전 경계다. ARM64를 다시 허용하려면 먼저 모든 application image와 native dependency가 `linux/arm64`를 지원하는지 확인하고 multi-arch image index를 공급해야 한다.

핵심 교훈:

> Pod가 어느 node에서 실행될 수 있는지는 Kubernetes manifest만의 문제가 아니다. OCI image platform, Karpenter NodePool, Pod scheduling constraint가 함께 하나의 배포 계약을 이룬다.

---

# Step 1. 회고 12와 회고 13은 같은 증상처럼 보였다

## 1.1 둘 다 image 단계에서 멈춘다

회고 12의 직접 원인은 ECR에 tag가 없는 것이었다.

```text
repository/tag not found
```

회고 13은 tag가 생긴 뒤의 platform compatibility 문제였다.

```text
image는 존재
하지만 선택된 node architecture와 image platform이 다름
```

두 문제 모두 최종적으로 다음 상태군에 나타날 수 있다.

```text
ErrImagePull
ImagePullBackOff
ContainerCreating
CrashLoopBackOff
```

따라서 Pod의 상위 상태만 보고 원인을 단정하면 안 된다.

## 1.2 진단 순서

```text
1. image reference 확인
2. ECR repository/tag 또는 digest 존재 확인
3. image manifest가 제공하는 platform 확인
4. Pod가 배치된 node의 architecture 확인
5. container event와 termination reason 확인
```

개념적인 확인:

```powershell
kubectl get pod <pod> `
  -o jsonpath='{.spec.containers[*].image}'

kubectl get pod <pod> `
  -o wide

kubectl get node <node> `
  -L kubernetes.io/arch
```

image platform은 다음 도구로 확인할 수 있다.

```bash
docker buildx imagetools inspect <registry>/<service>:<tag>
```

## 1.3 관측 가능한 오류는 registry 형식에 따라 달라진다

architecture 불일치가 항상 하나의 문자열로 나타나는 것은 아니다.

multi-platform image index에 node와 맞는 entry가 없으면 다음 계열이 나타날 수 있다.

```text
no matching manifest for linux/arm64
no match for platform in manifest
```

단일 platform artifact가 pull된 뒤 process 실행까지 진행되면 다음 계열이 가능하다.

```text
exec format error
```

이 사건의 핵심 근거는 특정 오류 문구 하나가 아니라 다음 선언의 모순이었다.

```text
NodePool:
  arm64 허용

image build:
  amd64만 보장
```

---

# Step 2. `amd64`와 `arm64`는 무엇이 다른가

## 2.1 Kubernetes label

Kubernetes node는 표준 label로 CPU architecture를 나타낸다.

```text
kubernetes.io/arch=amd64
kubernetes.io/arch=arm64
```

일반적인 대응:

```text
amd64:
  x86-64
  Intel 64
  AMD64

arm64:
  AArch64
  AWS Graviton
```

이름에 `AMD`가 들어가지만 `amd64`는 AMD CPU만 의미하지 않는다. Intel과 AMD의 x86-64 호환 ISA를 Kubernetes·OCI에서 부르는 platform 이름이다.

## 2.2 EC2 instance suffix

당시 allowlist의 주요 계열:

```text
c6i / m6i:
  Intel x86-64
  kubernetes.io/arch=amd64

c6a / m6a:
  AMD EPYC x86-64
  kubernetes.io/arch=amd64

c7g / m7g:
  AWS Graviton ARM64
  kubernetes.io/arch=arm64
```

instance family가 compute optimized인지 general purpose인지와 CPU architecture는 별도 축이다.

```text
c / m:
  workload 특성

i / a / g suffix:
  processor vendor·architecture 계열
```

## 2.3 Java application도 architecture에서 자유롭지 않다

Java bytecode는 JVM 위에서 실행되므로 source level에서는 이식성이 높다.

하지만 container image는 다음 native component를 포함한다.

```text
Linux userspace
JRE/JDK binary
shell/coreutils
native library
compression/crypto library
agent
entrypoint executable
```

따라서 Java service라도 base image와 JVM이 target CPU architecture를 지원해야 한다.

```text
Java source가 portable
≠ container image가 모든 architecture에서 실행 가능
```

---

# Step 3. OCI image의 platform 계약

## 3.1 단일 platform image

일반적인 단일 platform build:

```bash
docker buildx build \
  --platform linux/amd64 \
  -t repository:tag \
  --push .
```

registry에는 `linux/amd64`용 manifest와 layer가 저장된다.

```text
OS: linux
architecture: amd64
```

ARM64 node는 같은 tag가 존재하더라도 compatible artifact를 찾지 못할 수 있다.

## 3.2 multi-platform image index

하나의 tag가 architecture별 manifest를 가리킬 수도 있다.

```text
repository:release
  └─ OCI image index
      ├─ linux/amd64 → manifest A
      └─ linux/arm64 → manifest B
```

build 예:

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t repository:release \
  --push .
```

container runtime은 node platform에 맞는 child manifest를 선택한다.

## 3.3 같은 tag가 있다는 사실만으로 부족하다

회고 12에서 만든 검증 invariant:

```text
pin file
  == Kustomization newTag
  == ECR tag
```

회고 13을 반영하면 한 축이 더 필요하다.

```text
pin file architecture
  ⊇ Pod가 실행될 node architecture
```

완전한 조건:

```text
reference 존재
AND
artifact platform이 node platform을 지원
```

현재 `check-ecr-image-pins.ps1`은 tag 존재까지 확인하지만 OCI manifest platform은 검사하지 않는다. `image-pins.yaml`에 `architecture: amd64`가 있어도 이 값과 실제 registry manifest의 일치를 자동 검증하는 것은 남은 작업이다.

---

# Step 4. Karpenter가 왜 Graviton node를 선택할 수 있었는가

## 4.1 기존 workload NodePool

수정 전 핵심 조건:

```yaml
requirements:
  - key: kubernetes.io/arch
    operator: In
    values: ["amd64", "arm64"]
```

instance allowlist:

```text
c6i, c6a
m6i, m6a
c7g
m7g
```

즉 NodePool은 다음 두 집합 모두 유효하다고 선언했다.

```text
amd64:
  c6i, c6a, m6i, m6a

arm64:
  c7g, m7g
```

## 4.2 Pod는 architecture를 요구하지 않았다

Pod에는 workload pool 선택만 있었다.

```yaml
nodeSelector:
  karpenter.sh/nodepool: workload
```

이 선언은 “workload NodePool에 속한 node”만 요구한다.

```text
amd64 workload node:
  허용

arm64 workload node:
  허용
```

## 4.3 Karpenter의 관점에서는 정상

Karpenter는 Pod requirement와 NodePool requirement의 교집합에서 instance를 선택한다.

```text
Pod requirement:
  nodepool=workload

NodePool options:
  amd64 또는 arm64
  spot 또는 on-demand
  여러 instance type

Karpenter:
  공급 가능하고 조건을 만족하는 option 선택
```

Karpenter는 ECR image가 실제로 어떤 CPU instruction set을 지원하는지 build metadata까지 해석해 provisioning 결정을 내리지 않는다.

그 책임은 workload scheduling constraint와 artifact 공급망에 있다.

## 4.4 비용 최적화가 correctness보다 앞섰다

Graviton은 많은 workload에서 가격 대비 성능 이점이 있다.

하지만 NodePool에 `arm64`를 추가하는 것은 단순한 FinOps 설정이 아니다.

```text
필요 조건:
  모든 image의 arm64 artifact
  native dependency 호환성
  integration test
  observability/security agent 지원
  rollback artifact
```

이 조건 없이 `arm64`를 허용하면 비용 선택지가 늘어나는 대신 deployment correctness가 확률적이 된다.

---

# Step 5. 즉시 해결 — 현재 검증된 architecture로 수렴

## 5.1 NodePool을 `amd64`로 제한

수정:

```yaml
- key: kubernetes.io/arch
  operator: In
  values: ["amd64"]
```

이제 Karpenter는 workload Pod를 위해 ARM64 node를 만들 수 없다.

## 5.2 Graviton instance type 제거

다음 type을 allowlist에서 제거했다.

```text
c7g.large
c7g.xlarge
c7g.2xlarge
m7g.large
m7g.xlarge
m7g.2xlarge
```

남은 type:

```text
c6i.large / xlarge / 2xlarge
c6a.large / xlarge / 2xlarge
m6i.large / xlarge / 2xlarge
m6a.large / xlarge / 2xlarge
```

architecture requirement 하나만으로도 ARM64는 제외된다. instance allowlist에서도 `g` 계열을 제거한 것은 사람이 설정을 읽을 때 모순이 없도록 한 이중 방어다.

```text
arch=amd64인데 c7g가 목록에 남음
  → Karpenter가 교집합에서 제외하더라도 운영자가 혼란
```

## 5.3 범용 provisioner도 `amd64`

별도로 남아 있던 `apps/karpenter/provisioners/node-pool.yaml`의 default NodePool도 다음처럼 변경했다.

```yaml
values: ["arm64", "amd64"]
```

에서:

```yaml
values: ["amd64"]
```

같은 cluster 안에 서로 다른 Karpenter 경로가 있어 한쪽만 고치면 우회 배치 가능성이 남기 때문이다.

---

# Step 6. Pod에도 architecture를 선언한 이유

## 6.1 NodePool 제한만으로 충분해 보인다

workload NodePool이 `amd64` node만 만든다면 Pod nodeSelector는 중복처럼 보인다.

하지만 Pod 선언은 application이 요구하는 runtime contract다.

```yaml
nodeSelector:
  karpenter.sh/nodepool: workload
  kubernetes.io/arch: amd64
```

## 6.2 방어하는 변경 시나리오

Pod selector가 없으면 미래에 누군가 NodePool만 수정할 수 있다.

```text
FinOps 변경:
  workload NodePool에 arm64 재추가

Pod:
  architecture 요구 없음

결과:
  amd64-only workload가 다시 ARM node에 배치 가능
```

Pod selector가 있으면:

```text
NodePool이 arm64를 허용해도
이 Pod의 requirement는 amd64
  → Karpenter는 amd64 option만 선택
```

## 6.3 기존 node와 다른 pool에 대한 보호

nodeSelector는 새 Karpenter provisioning뿐 아니라 scheduler가 이미 존재하는 node를 선택할 때도 적용된다.

```text
NodePool requirement:
  생성 정책

Pod nodeSelector:
  배치 정책
```

둘은 역할이 다르다.

## 6.4 적용 범위

다음 workload Deployment에 `amd64` selector를 추가했다.

```text
order-service
payment-service
cart-service
user-service
store/product-service
edge/gateway-service
```

repository에는 active 경로와 migration 중인 GitOps 경로가 함께 있어 두 경로 모두 수정했다.

```text
workloads/*/overlays/prod
gitops/workload-apps/*/overlays/prod
```

---

# Step 7. 장시간 실행 서비스만 고치면 충분하지 않았다

## 7.1 bootstrap Job도 Pod다

database 생성 Job은 짧게 실행되지만 scheduling과 image runtime 규칙은 Deployment와 같다.

```text
Keycloak create-db Job
workload create-dbs Job
```

Job이 ARM64 node에 배치돼 image를 실행하지 못하면 application Pod가 정상이어도 초기화가 진행되지 않는다.

```text
DB Job 실패
  → database 미생성
    → application connection 실패
```

그래서 다음 selector를 추가했다.

```yaml
nodeSelector:
  karpenter.sh/nodepool: workload
  kubernetes.io/arch: amd64
```

## 7.2 Keycloak

Keycloak Helm values에도 architecture를 명시했다.

```yaml
nodeSelector:
  karpenter.sh/nodepool: workload
  kubernetes.io/arch: amd64
```

Keycloak upstream image 자체가 multi-arch일 가능성과 별개로, 당시 운영 검증 범위를 cluster workload 전체 `amd64`로 고정한 결정이다.

이는 가장 세밀한 정책은 아니다.

```text
더 세밀한 장기 정책:
  image별 supportedPlatforms 기록
  multi-arch가 검증된 workload만 arm64 허용

당시 안전 정책:
  workload tier 전체 amd64
```

---

# Step 8. CI도 같은 계약을 선언해야 한다

## 8.1 build platform 명시

회고 12에서 정리한 GitHub Actions와 local rebuild script는 다음 옵션을 사용한다.

```bash
docker buildx build \
  --platform linux/amd64 \
  ...
```

이 옵션이 없으면 builder host의 architecture를 암묵적으로 따를 수 있다.

```text
amd64 GitHub runner:
  우연히 amd64 build

ARM64 developer machine:
  arm64 build 가능

결과:
  동일 workflow 의도라도 artifact platform이 달라질 위험
```

명시는 build 결과를 deterministic하게 만든다.

## 8.2 image pin ledger

`workloads/image-pins.yaml`에 architecture를 기록했다.

```yaml
architecture: amd64
```

주석으로 세 계층의 계약을 함께 남겼다.

```text
CI:
  docker buildx --platform linux/amd64

Karpenter:
  workload NodePool arch=amd64

Pod/Job:
  nodeSelector arch=amd64
```

## 8.3 선언과 검증은 다르다

현재 architecture 값은 문서화된 계약이다.

하지만 `check-ecr-image-pins.ps1`은 다음만 자동 확인한다.

```text
pin과 Kustomization tag 일치
ECR tag 존재
```

아직 확인하지 않는 것:

```text
실제 OCI manifest architecture
multi-arch index의 platform 목록
base image architecture
runtime smoke test
```

따라서 architecture gate를 완성하려면 CI에서 다음 검증이 추가돼야 한다.

```bash
docker buildx imagetools inspect <image>
```

기대 platform과 실제 manifest platform이 다르면 build pipeline을 실패시켜야 한다.

---

# Step 9. Argo CD 동기화 중 생긴 별도 문제

## 9.1 Git 변경은 정상 반영됐다

architecture 수정은 `a1d4286`으로 Git에 기록됐다.

```text
18 files changed
26 insertions
9 deletions
```

## 9.2 Karpenter Application force sync가 panic

배포 selector는 반영됐지만 NodePool desired state를 강제 sync하는 과정에서 Argo CD application controller가 panic했다.

이 문제는 architecture manifest 자체가 틀렸다는 뜻이 아니었다. 당시 Karpenter Application reconcile이 이미 불안정했고, 이후 회고 17에서 별도로 다룰 controller·OutOfSync 문제와 연결된다.

## 9.3 일시적 Server-Side Apply

NodePool은 `kubectl` Server-Side Apply로 live cluster에 반영했다.

```text
Git desired:
  amd64-only

live:
  amd64-only

차이:
  정상 Argo sync 대신 일시적 SSA로 전달
```

이는 수동 patch만 남긴 것이 아니다. Git을 먼저 수정한 뒤 동일한 desired state를 live에 전달한 응급 경로였다.

그럼에도 장기적으로는 Argo reconcile을 복구해야 한다. 그렇지 않으면 다음 변경도 수동 적용에 의존한다.

---

# Step 10. 검증

## 10.1 NodePool

확인 대상:

```text
workload NodePool requirements:
  kubernetes.io/arch=["amd64"]

instance allowlist:
  c7g 없음
  m7g 없음
```

## 10.2 Pod spec

대상 Deployment·StatefulSet·Job:

```text
nodeSelector:
  karpenter.sh/nodepool: workload
  kubernetes.io/arch: amd64
```

Helm/Kustomize input만 보지 않고 최종 live Pod spec을 확인해야 한다.

```powershell
kubectl get pod <pod> `
  -o jsonpath='{.spec.nodeSelector}'
```

## 10.3 Node

```powershell
kubectl get nodes `
  -L kubernetes.io/arch,karpenter.sh/nodepool
```

당시 live node는 모두 `amd64`였다.

## 10.4 Image

필요한 검증:

```text
ECR tag 존재
manifest platform=linux/amd64
Pod의 실제 imageID digest 확인
```

tag는 mutable할 수 있으므로 최종 실행 identity는 다음에서 확인한다.

```text
.status.containerStatuses[].imageID
```

---

# Step 11. 왜 바로 multi-arch로 전환하지 않았는가

## 11.1 명령 한 줄로 끝나지 않는다

표면적으로는 다음처럼 보인다.

```bash
--platform linux/amd64,linux/arm64
```

하지만 실제 검증 대상은 더 많다.

```text
base JDK image
Gradle/Maven build plugin
native compression/crypto library
APM/OTel agent
shell script와 utility
Dockerfile에서 내려받는 architecture별 binary
integration test
startup/readiness behavior
performance profile
```

## 11.2 emulation build의 함정

x86 runner에서 QEMU로 ARM64 image를 build할 수 있다.

그러나:

```text
build가 느려질 수 있음
일부 native build가 emulation에서 다르게 동작
build 성공이 실제 Graviton runtime 성공을 보장하지 않음
```

가능하면 architecture별 native runner 또는 최소한 실제 ARM64 node smoke test가 필요하다.

## 11.3 원자적 전환이 필요하다

안전한 순서:

```text
1. 모든 대상 서비스 arm64 build 가능 확인
2. amd64+arm64 image index push
3. 각 platform integration/smoke test
4. registry manifest platform gate
5. GitOps digest 또는 release tag 갱신
6. Pod selector 정책 결정
7. NodePool에 arm64/Graviton 재추가
8. canary workload를 Graviton에 배치
9. 성능·비용·오류율 비교
10. rollback 경로 검증
```

NodePool부터 먼저 넓히면 안 된다.

---

# Step 12. 비용과 안정성의 trade-off

## 12.1 amd64-only의 장점

```text
현재 image와 확실히 호환
운영 변수가 줄어듦
문제 재현이 단순
CI와 node가 같은 architecture
```

## 12.2 amd64-only의 비용

```text
Graviton 가격 대비 성능 기회 상실
Spot capacity 선택지 감소
특정 instance shortage 시 대체 폭 감소
```

## 12.3 multi-arch의 장점과 비용

장점:

```text
더 넓은 Spot pool
Graviton 비용 효율
capacity resilience
```

비용:

```text
build 시간·storage 증가
architecture별 test matrix 증가
native dependency 관리
성능 특성 차이
incident surface 증가
```

따라서 “ARM이 더 싸다”는 이유만으로 NodePool에 `arm64`를 추가할 수 없다. 비용 절감액은 build·test·운영 복잡도까지 포함해 평가해야 한다.

---

# Step 13. 임시방편과 영구 해결

## 13.1 당시 선택한 안전한 수렴

```text
CI = amd64
NodePool = amd64
Pod/Job = amd64
```

이는 실행 가능한 artifact 하나를 기준으로 전체 배포 경계를 일치시킨 조치다.

## 13.2 영구적인 부분

```text
architecture가 manifest에 명시됨
Karpenter와 Pod에 이중 guard
CI build platform 명시
image pin ledger에 architecture 기록
Graviton 재도입 전제조건 주석
```

## 13.3 아직 임시적인 부분

```text
amd64-only 자체는 장기 최적 architecture 결정이 아님
Pod마다 동일 selector 반복
image별 지원 platform 모델 없음
registry platform 자동 검사 없음
multi-arch canary pipeline 없음
digest promotion 미구현
```

---

# Step 14. 개선된 목표 상태

## 14.1 artifact metadata

서비스별로 다음 정보가 추적돼야 한다.

```yaml
services:
  order-service:
    tag: git-abc123
    digest: sha256:...
    platforms:
      - linux/amd64
      - linux/arm64
```

## 14.2 CI gate

```text
build
  → architecture별 test
    → multi-arch index push
      → manifest inspect
        → SBOM/signature
          → GitOps digest PR
```

## 14.3 admission policy

더 엄격한 환경에서는 admission policy로 다음을 강제할 수 있다.

```text
latest 금지
digest pin 필수
서명된 image만 허용
허용 architecture metadata 검증
```

단, admission controller가 registry platform과 node placement의 모든 조합을 자동으로 증명해 주는 것은 아니다. CI와 scheduling 정책이 먼저 명확해야 한다.

## 14.4 NodePool

multi-arch 검증 후:

```yaml
- key: kubernetes.io/arch
  operator: In
  values: ["amd64", "arm64"]
```

를 다시 허용할 수 있다.

그러나 amd64-only workload는 selector를 유지하고, multi-arch가 검증된 workload만 별도 policy로 ARM64 placement를 허용하는 편이 안전하다.

---

# Step 15. 운영 Runbook

## 15.1 새 image build 전

```text
[ ] target platform 명시
[ ] base image가 target platform 지원
[ ] native binary download URL이 architecture를 구분
[ ] architecture별 test 준비
```

## 15.2 push 후

```text
[ ] ECR tag/digest 존재
[ ] image index platform 목록 확인
[ ] expectedPlatforms와 실제 manifest 일치
[ ] architecture별 smoke test
```

## 15.3 NodePool 변경 전

```text
[ ] 해당 architecture를 모든 대상 image가 지원
[ ] daemonset/agent도 지원
[ ] bootstrap Job도 지원
[ ] canary와 rollback 준비
[ ] Spot/On-Demand capacity 확인
```

## 15.4 장애 발생 시

```text
1. Pod image reference 확인
2. ECR tag/digest 존재 확인
3. OCI manifest platform 확인
4. node kubernetes.io/arch 확인
5. Pod nodeSelector/affinity 확인
6. NodePool requirement 확인
7. event의 pull/runtime 오류 구분
8. 필요하면 검증된 architecture로 scheduling 제한
```

---

## 최종 원인 트리

```text
workload image 실행 계약 불일치
│
├─ artifact
│  ├─ ECR tag는 복구됨
│  └─ image platform은 linux/amd64만 보장
│
├─ provisioning
│  ├─ workload NodePool이 amd64+arm64 허용
│  ├─ c7g/m7g Graviton 허용
│  └─ Karpenter는 image architecture를 provisioning 조건으로 추론하지 않음
│
├─ scheduling
│  ├─ Pod는 workload pool만 선택
│  └─ kubernetes.io/arch 조건 없음
│
├─ 구조적 원인
│  ├─ CI와 Karpenter가 서로 다른 repo에서 관리
│  ├─ platform compatibility gate 없음
│  └─ 비용 최적화 option과 artifact capability가 독립 변경
│
├─ 복구
│  ├─ NodePool amd64-only
│  ├─ c7g/m7g 제거
│  ├─ Pod/Job amd64 nodeSelector
│  ├─ CI linux/amd64 명시
│  └─ image-pins architecture 기록
│
└─ 남은 부채
   ├─ ECR manifest platform 자동 검사 없음
   ├─ multi-arch test pipeline 없음
   ├─ digest promotion 없음
   ├─ 서비스별 supportedPlatforms 없음
   └─ Graviton 비용 효율 미활용
```

## 한 문장으로 남기는 교훈

**Karpenter가 만들 수 있는 node architecture와 CI가 만들 수 있는 image architecture는 서로 다른 설정이 아니라, 반드시 함께 변경하고 함께 검증해야 하는 하나의 배포 계약이다.**
