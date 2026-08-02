# Git은 복구됐지만 실행할 이미지는 없었다

> Terraform과 GitOps만으로는 재배포가 완성되지 않는 이유, 그리고 ECR artifact·tag·CI 권한을 하나의 공급망으로 연결한 기록

## 문서 정보

- 사건 시각: 2026-07-31
- 환경: Amazon ECR, Amazon EKS, Argo CD, Kustomize, GitHub Actions OIDC
- 대상 서비스: order, payment, cart, user, store, edge
- 최초 증상: `ErrImagePull`, `ImagePullBackOff`
- 직접 원인: GitOps가 요구한 `e2e*` tag가 ECR에 없음
- 선행 원인: teardown이 non-empty ECR repository를 강제 삭제
- CI 불일치:
  - 기존 workflow는 주로 `latest`를 push
  - GitOps는 `e2e1`, `e2e2`, `e2e4`, `e2e6`을 요구
- IAM 불일치:
  - OIDC trust는 문서상 조직 repo만 허용
  - 실제 remote는 `hetrkumt/localy-backend`
  - ECR policy는 존재하지 않는 `localy-*` repository ARN을 대상으로 함
- 응급 복구: 로컬 Docker에서 매니페스트 tag로 build·push
- 영구 개선:
  - `workloads/image-pins.yaml`
  - pin tag + `latest`를 push하는 GitHub Actions
  - `workflow_dispatch`
  - 실제 repository ARN 기반 IAM
  - ECR pin 점검·재빌드 스크립트
- 검증: pin file ↔ Kustomization `newTag` ↔ ECR tag 전부 일치
- 관련 후속 회고: 회고 13의 `linux/amd64` image·node architecture 계약
- 남은 부채: pin이 여러 파일과 repo에 중복돼 있어 완전한 단일 SSOT는 아님

---

## Executive Summary

EKS와 GitOps 제어면을 재배포하고 Secret·논리 database 문제를 해결한 뒤에도 workload Pod는 실행되지 않았다.

증상은 이전 단계와 달라졌다.

```text
이전:
  FailedMount
  Secret not found
  database does not exist

이후:
  ErrImagePull
  ImagePullBackOff
```

kubelet event에는 다음과 같은 의미의 메시지가 있었다.

```text
Failed to pull image
533003975005.dkr.ecr.ap-northeast-2.amazonaws.com/payment-service:e2e6
not found
```

이는 ECR 인증 실패가 아니었다.

```text
AccessDenied:
  repository 또는 image에 접근할 IAM 권한 문제

not found:
  요청한 repository/tag/digest에 artifact가 없음
```

GitOps manifest는 유효했다. 예를 들어 payment-service는 `e2e6`을 요구했다.

```yaml
images:
  - name: localy-payment-service
    newName: 533003975005.dkr.ecr.ap-northeast-2.amazonaws.com/payment-service
    newTag: e2e6
```

하지만 ECR repository는 teardown 과정에서 image와 함께 삭제됐다. Terraform이 repository를 다시 만들었어도 repository 안의 OCI image layer와 manifest는 자동으로 돌아오지 않는다.

```text
Terraform:
  ECR repository 생성 가능

GitOps:
  사용할 image reference 선언 가능

둘 다 하지 못하는 것:
  application source를 compile해 OCI image 생성
```

초기 복구에서는 로컬 Docker로 여섯 서비스를 build하고 매니페스트가 요구하는 tag로 push했다. 그 결과 Pod가 image를 pull할 수 있었다.

그러나 수동 build는 다음 재배포를 보장하지 못한다. CI를 확인하자 또 다른 불일치가 드러났다.

```text
CI output tag:
  latest

GitOps required tag:
  e2e*

GitHub OIDC trust:
  repo:localy-project/localy-backend

실제 Git remote:
  hetrkumt/localy-backend

IAM ECR resources:
  localy-*

실제 repositories:
  order-service, payment-service, ...
```

따라서 문제는 “ECR에 image 하나가 없다”가 아니었다. source commit에서 deployable artifact를 만들고, 올바른 repository와 tag로 push하며, GitOps가 같은 reference를 사용하도록 보장하는 공급망이 끊겨 있었다.

복구 후 다음 구조를 만들었다.

```text
image-pins.yaml
  ├─ Kustomization newTag와 일치
  ├─ GitHub Actions matrix와 일치
  ├─ local rebuild script가 읽음
  └─ ECR check script가 실제 tag 존재를 검증
```

CI는 각 GitOps pin tag와 `latest`를 함께 push하도록 변경했다.

```text
e2e*:
  GitOps 배포용 고정 tag

latest:
  사람의 탐색·개발 편의용 alias
  GitOps에서는 사용하지 않음
```

마지막으로 OIDC trust와 IAM resource ARN을 실제 GitHub repository 및 ECR repository에 맞췄다.

이 사건이 남긴 핵심은 다음과 같다.

> 재배포 가능성은 Terraform state와 YAML을 복원하는 데서 끝나지 않는다. 같은 source로 같은 실행 artifact를 다시 만들고, 선언된 reference로 registry에 공급할 수 있어야 한다.

---

# Step 1. 발단 — Secret 문제를 고치자 image 문제가 보였다

## 1.1 연쇄 장애에서 오류가 바뀌는 의미

workload 배포는 여러 전제조건을 순서대로 통과한다.

```text
Namespace
  → ServiceAccount / IAM
    → SecretStore / ExternalSecret
      → Kubernetes Secret
        → volume/env mount
          → image pull
            → process start
              → database/OAuth connection
```

초기에는 Secret이 없어 Pod가 container 생성 전 단계에서 멈췄다.

```text
FailedMount
```

Secret 경로와 JSON schema를 고치자 kubelet은 다음 단계로 이동했다.

```text
ErrImagePull
ImagePullBackOff
```

오류가 바뀐 것은 새로운 장애를 만든 것이 아니다. 앞선 dependency를 통과해 다음 실패 계층이 드러난 것이다.

## 1.2 `ImagePullBackOff`는 원인이 아니다

`ImagePullBackOff`는 kubelet이 image pull 재시도 간격을 늘리고 있다는 상태다.

실제 원인은 event의 세부 메시지에서 구분해야 한다.

```text
no basic auth credentials
  → registry login/config 문제

AccessDeniedException / 403
  → IAM 또는 repository policy 문제

manifest unknown / not found
  → 요청한 tag 또는 digest 없음

no matching manifest for linux/arm64
  → image platform 불일치

TLS / DNS timeout
  → network 또는 registry endpoint 문제
```

당시 핵심은 `not found`였다.

따라서 imagePullSecret을 추가하거나 node IAM을 넓히는 접근은 맞지 않았다.

## 1.3 ECR inventory

서비스별 repository를 조회했지만 필요한 tag가 없었다.

대상은 다음 여섯 개였다.

```text
order-service
payment-service
cart-service
user-service
store-service
edge-service
```

GitOps가 요구한 tag:

```text
order-service   e2e4
payment-service e2e6
cart-service    e2e1
user-service    e2e1
store-service   e2e2
edge-service    e2e1
```

repository가 다시 생성됐다는 사실과 이 tag가 존재한다는 사실은 별개였다.

---

# Step 2. 기반 지식 — 코드, repository, image는 서로 다른 생명주기를 갖는다

## 2.1 Git repository는 source를 보존한다

Git이 보존하는 것은 application source와 build definition이다.

```text
Java source
Gradle/Maven files
Dockerfile
GitHub Actions workflow
GitOps manifests
```

Git에는 일반적으로 최종 container layer가 저장되지 않는다.

## 2.2 ECR repository는 artifact를 담는 container다

Terraform resource는 ECR repository shell을 만든다.

```text
repository name
repository ARN
encryption
image scanning
lifecycle policy
tags
```

OCI image는 CI 또는 개발자가 별도로 push해야 한다.

```text
docker build
  → layers + config + manifest
    → docker push
      → ECR image artifact
```

Terraform이 repository를 만들었다고 image가 생성되지 않는다.

## 2.3 GitOps는 artifact reference를 선언한다

Kustomize는 base image name을 실제 ECR reference로 변환한다.

```yaml
images:
  - name: localy-order-service
    newName: 533003975005.dkr.ecr.ap-northeast-2.amazonaws.com/order-service
    newTag: e2e4
```

렌더링 결과:

```text
533003975005.dkr.ecr.ap-northeast-2.amazonaws.com/order-service:e2e4
```

Argo CD는 이 reference를 Deployment에 넣는다.

하지만 Argo CD는 Dockerfile을 build하지 않는다.

```text
Argo 책임:
  desired Kubernetes resource 배포

Argo 책임 아님:
  source compile
  container build
  ECR push
```

## 2.4 세 생명주기의 비대칭

teardown 이후 상태는 다음처럼 달라질 수 있다.

```text
Git source:
  원격 GitHub에 남아 있음

Terraform code/state backend:
  남아 있거나 다시 init 가능

ECR repository:
  Terraform으로 재생성 가능

ECR image:
  teardown에서 삭제됨
  자동 재생성되지 않음
```

따라서 “infra as code가 있으니 언제든 재구축 가능하다”는 말은 build pipeline이 재실행 가능할 때만 참이다.

---

# Step 3. 왜 teardown이 ECR image를 지웠는가

## 3.1 non-empty repository는 삭제를 막는다

Terraform destroy가 ECR repository를 제거할 때 image가 남아 있으면 실패할 수 있다.

철거 스크립트는 이를 피하기 위해 repository를 강제 삭제했다.

```powershell
aws ecr delete-repository `
  --repository-name <service> `
  --force
```

이 동작은 의도적이었다.

```text
목표:
  Terraform destroy를 막는 image 제거

부작용:
  다음 재배포에서 image rebuild 필요
```

## 3.2 무엇을 보존할지 선택하는 문제

ECR image를 유지하는 대안도 있다.

```text
repository를 Terraform state에서 분리
image lifecycle policy로 일정 기간 보존
별도 artifact account/registry 사용
release tag만 보존
```

하지만 각 선택에는 비용과 관리 부채가 있다.

```text
보존:
  재배포 빠름
  storage cost와 orphan 관리 필요

삭제:
  비용·정리 단순
  CI가 반드시 재현 가능해야 함
```

이 프로젝트는 삭제 후 재빌드 전략을 택했다. 따라서 build workflow는 선택사항이 아니라 teardown의 대응 절차가 된다.

---

# Step 4. 응급 복구 — 매니페스트 tag로 로컬 build·push

## 4.1 Docker build 가능 여부 확인

ECR에 artifact가 없다는 사실을 확인한 뒤 로컬 Docker daemon과 source tree를 점검했다.

각 서비스에 다음이 있어야 했다.

```text
Localy/<service>/Dockerfile
build에 필요한 source
ECR repository
AWS ECR login 권한
```

## 4.2 임의 tag가 아니라 GitOps 요구값을 사용했다

응급 build에서 중요한 점은 단순히 `latest`를 push하지 않은 것이다.

서비스별로 현재 Kustomization이 요구하는 tag를 사용했다.

```text
edge-service    e2e1
store-service   e2e2
cart-service    e2e1
order-service   e2e4
payment-service e2e6
user-service    e2e1
```

개념적인 절차:

```powershell
docker build -t <registry>/<service>:<gitops-tag> .
docker push <registry>/<service>:<gitops-tag>
```

이후 kubelet은 manifest를 바꾸지 않고 같은 reference로 image를 pull할 수 있었다.

## 4.3 응급 복구의 한계

로컬 build는 빠르지만 다음을 보장하지 않는다.

```text
누가 어떤 source commit에서 build했는가
로컬 toolchain이 CI와 같은가
모든 서비스 tag가 일관적인가
다음 teardown 후 누가 반복할 것인가
amd64/arm64 platform이 명시됐는가
SBOM/provenance/signature가 있는가
```

따라서 운영 복구에는 사용할 수 있어도 장기 SSOT가 될 수 없다.

---

# Step 5. 기존 CI를 조사하다

## 5.1 `latest`와 `e2e*`의 불일치

기존 build workflow는 `latest` 중심이었다.

GitOps는 다음과 같은 고정 tag를 사용했다.

```text
e2e1
e2e2
e2e4
e2e6
```

따라서 CI가 성공해도 다음 상태가 가능했다.

```text
ECR:
  service:latest 존재

GitOps:
  service:e2e4 요청

결과:
  ImagePullBackOff
```

같은 image content를 가리킬 의도였더라도 registry에서 tag는 서로 다른 key다.

## 5.2 왜 GitOps에서 `latest`를 쓰지 않았는가

`latest`는 mutable tag다.

```text
오늘 latest → digest A
내일 latest → digest B
```

manifest가 바뀌지 않아도 실행 image가 달라질 수 있다.

또한 `imagePullPolicy: IfNotPresent`와 node cache가 결합되면 Pod마다 서로 다른 digest를 실행할 위험이 있다.

```text
node A cache: old latest
node B pull:  new latest
```

고정 tag도 registry에서 덮어쓸 수 있으므로 완전한 immutability는 아니지만, `latest`보다 배포 의도를 명확히 한다.

더 강한 방식은 digest pin이다.

```text
repository@sha256:<digest>
```

## 5.3 수동 실행 경로가 없었다

일반 push trigger만 있으면 teardown 직후 source 변경 없이 image만 다시 만들기 어렵다.

그래서 `workflow_dispatch`를 추가했다.

```text
service=all
service=edge-service
service=order-service
...
```

이제 infrastructure 재배포 후 application source에 불필요한 commit을 만들지 않고 build pipeline을 실행할 수 있다.

---

# Step 6. CI가 실행되기 전에 IAM이 두 군데서 막혀 있었다

## 6.1 OIDC trust의 repository identity

GitHub Actions는 static AWS access key 대신 OIDC token으로 IAM role을 assume한다.

trust policy는 token의 `sub` claim을 검사한다.

```text
repo:<owner>/<repository>:ref:refs/heads/main
```

문서상 기대값:

```text
repo:localy-project/localy-backend:ref:refs/heads/main
```

실제 Git remote:

```text
hetrkumt/localy-backend
```

따라서 실제 workflow token의 subject와 trust policy가 일치하지 않았다.

```text
GitHub token:
  repo:hetrkumt/localy-backend:ref:refs/heads/main

IAM trust:
  repo:localy-project/localy-backend:ref:refs/heads/main

결과:
  AssumeRoleWithWebIdentity 거부
```

현재 policy는 migration 가능성을 고려해 두 main branch identity를 허용한다.

```hcl
"token.actions.githubusercontent.com:sub" = [
  "repo:hetrkumt/localy-backend:ref:refs/heads/main",
  "repo:localy-project/localy-backend:ref:refs/heads/main"
]
```

wildcard `repo:*/*:*`로 넓히지 않고 repository와 branch를 제한했다.

## 6.2 ECR repository ARN 이름 불일치

role assumption을 통과해도 push policy의 Resource가 실제 repository와 달랐다.

기대했던 이름:

```text
localy-order-service
localy-payment-service
...
```

실제 ECR repository:

```text
order-service
payment-service
cart-service
user-service
store-service
edge-service
```

IAM의 resource matching은 문자열 의도가 아니라 실제 ARN으로 평가된다.

```text
policy가 localy-order-service만 허용
push 대상은 order-service
  → AccessDenied
```

## 6.3 repository resource에서 직접 ARN을 가져오다

하드코딩한 이름을 다시 맞추는 대신 Terraform ECR resource map에서 ARN을 얻도록 수정했다.

```hcl
Resource = [
  for name, repo in aws_ecr_repository.services : repo.arn
]
```

이 방식의 장점:

```text
repository 이름 변경이 policy에 반영
존재하지 않는 ARN 하드코딩 방지
생성과 권한이 같은 graph에 있음
```

ECR auth token만 AWS API 특성상 `Resource = "*"`이고, image push 작업은 workload repository ARN으로 제한했다.

---

# Step 7. image pin ledger를 만들다

## 7.1 서비스별 배포 tag를 한 화면에 모으다

`workloads/image-pins.yaml`을 추가했다.

```yaml
registry: 533003975005.dkr.ecr.ap-northeast-2.amazonaws.com
region: ap-northeast-2
architecture: amd64
services:
  order-service: e2e4
  payment-service: e2e6
  cart-service: e2e1
  user-service: e2e1
  store-service: e2e2
  edge-service: e2e1
```

이 파일은 다음 질문에 빠르게 답한다.

```text
어떤 repository가 필요한가?
어떤 tag를 build해야 하는가?
어떤 architecture인가?
teardown 후 어떤 workflow를 실행하는가?
```

## 7.2 Kustomization과 일치시킨다

실제 Deployment image를 결정하는 값은 각 overlay의 `newTag`다.

```text
image-pins.yaml
  ↔ workloads/<service>/overlays/prod/kustomization.yaml
```

둘이 다르면 ledger는 문서일 뿐이다.

그래서 check script가 두 값을 비교한다.

```text
image-pins tag == kustomization newTag
```

## 7.3 ECR 존재까지 확인한다

파일끼리 일치해도 registry에 artifact가 없을 수 있다.

check script는 ECR API를 호출한다.

```text
repository 존재?
필요 tag 존재?
```

최종 invariant:

```text
pin file
  == Kustomization newTag
  == ECR image tag
```

실패 예:

```text
FAIL payment-service:
  image-pins=e2e6
  kustomization=e2e6
  ECR missing e2e6
```

이 결과는 manifest 수정이 아니라 build/push가 필요하다는 것을 바로 알려준다.

---

# Step 8. CI를 재배포 도구로 바꾸다

## 8.1 pin tag와 `latest`를 함께 push

workflow matrix에 서비스별 GitOps tag를 명시했다.

```yaml
matrix:
  include:
    - service: order-service
      gitops_tag: e2e4
    - service: payment-service
      gitops_tag: e2e6
```

build 결과는 두 tag로 push한다.

```bash
docker buildx build \
  -t "${ECR_REGISTRY}/${ECR_REPOSITORY}:${GITOPS_TAG}" \
  -t "${ECR_REGISTRY}/${ECR_REPOSITORY}:latest" \
  --push .
```

역할을 구분했다.

```text
GITOPS_TAG:
  Deployment가 사용

latest:
  편의용 alias
  Deployment에서 사용하지 않음
```

## 8.2 `workflow_dispatch`

재배포 시 다음 경로를 사용할 수 있다.

```text
GitHub Actions
  → Build and Push to Amazon ECR
    → Run workflow
      → service=all
```

특정 서비스만 복구할 수도 있다.

```text
service=order-service
```

## 8.3 로컬 fallback

GitHub OIDC나 Actions가 unavailable할 때를 위해 로컬 script를 남겼다.

기본은 dry-run이다.

```powershell
.\rebuild-ecr-image-pins.ps1
```

실제 실행:

```powershell
.\rebuild-ecr-image-pins.ps1 -Execute
```

특정 서비스:

```powershell
.\rebuild-ecr-image-pins.ps1 `
  -Execute `
  -Service order-service
```

script는 pin file을 읽고 다음 두 tag를 push한다.

```text
<pin>
latest
```

그리고 `linux/amd64`를 명시한다. architecture 문제는 회고 13에서 별도로 다룬다.

---

# Step 9. 최종 검증

## 9.1 검증 script

```powershell
.\check-ecr-image-pins.ps1
```

서비스마다 다음을 검사한다.

```text
Kustomization 존재
newTag 추출 성공
pin file과 newTag 일치
ECR repository 접근 가능
ECR에 pin tag 존재
```

최종 결과:

```text
PASS: all image pins present and consistent
```

## 9.2 Pod 관점

artifact 공급망 검증 후 kubelet event에서 다음 오류가 사라져야 한다.

```text
manifest unknown
not found
ErrImagePull
ImagePullBackOff
```

그다음 Pod가 CrashLoop한다면 image pull 문제는 통과한 것이다. process configuration, Secret binding, database, OAuth 등 다음 계층을 조사해야 한다.

## 9.3 CI 권한 관점

IAM은 다음 두 단계로 검증해야 한다.

```text
1. GitHub OIDC로 role assume 성공
2. 대상 repository에 image layer와 manifest push 성공
```

role assume 성공만으로 ECR policy가 맞는 것은 아니다.

ECR login 성공만으로 특정 repository push 권한이 있는 것도 아니다.

---

# Step 10. 이것이 진짜 SSOT인가

## 10.1 개선 전보다 훨씬 낫지만 완전한 단일 원본은 아니다

현재 tag 정보는 여러 곳에 존재한다.

```text
localy-manifests/workloads/image-pins.yaml
각 Kustomization images[].newTag
localy-backend GitHub Actions matrix
```

주석에는 `KEEP IN SYNC`가 있다.

이는 엄밀히 말해 하나의 원본에서 자동 생성되는 SSOT가 아니라 **검증 가능한 중복 선언**이다.

```text
장점:
  drift를 script로 탐지
  사람이 전체 pin을 한눈에 확인
  local rebuild가 같은 파일을 사용

한계:
  CI matrix는 별도 repo에서 수동 갱신
  Kustomization도 별도 파일
  check를 실행하지 않으면 drift 가능
```

따라서 “SSOT 완료”라는 표현은 운영상 편의 표현이고, 구조적으로는 아직 개선 여지가 있다.

## 10.2 더 나은 대안 A — CI가 pin file을 직접 읽기

GitHub Actions가 `localy-manifests`의 pin file을 checkout하거나 release metadata API에서 읽도록 만들 수 있다.

```text
image-pins.yaml
  → CI matrix 동적 생성
  → build/push
  → Kustomization 검증
```

주의:

```text
두 repository checkout 권한
어느 commit 조합을 사용할지 결정
backend source와 manifest revision의 결합
```

## 10.3 더 나은 대안 B — CI가 immutable digest를 GitOps에 기록

일반적인 GitOps image promotion 흐름:

```text
backend commit
  → image build
    → ECR digest 생성
      → manifests PR에서 digest 갱신
        → review/merge
          → Argo deploy
```

예:

```text
533003975005.dkr.ecr.../order-service@sha256:abc...
```

장점:

```text
tag 덮어쓰기 영향 없음
실행 artifact가 정확히 식별됨
rollback이 명확함
source commit과 digest provenance 연결 가능
```

## 10.4 더 나은 대안 C — registry 보존 정책

매번 ECR을 삭제·재빌드하지 않고 release digest를 일정 기간 보존할 수 있다.

```text
prod release digest: 장기 보존
untagged/dev image: 짧은 lifecycle
repository: teardown에서 분리
```

이 방식은 재배포 속도를 높이지만 orphan registry와 storage cost 관리가 필요하다.

## 10.5 tag 이름 자체의 의미

`e2e1`, `e2e4`, `e2e6`은 artifact가 어떤 source commit에서 왔는지 직접 설명하지 않는다.

더 추적 가능한 tag:

```text
git-<short-sha>
release-<version>
build-<run-id>
```

가장 확실한 identity는 digest다.

---

# Step 11. 임시방편과 영구 해결

## 11.1 임시방편

```text
로컬 Docker build
현재 Kustomization tag로 직접 push
Pod가 pull 가능한지 확인
```

이 방식은 장애 복구에는 효과적이었다.

하지만 다음 정보가 자동 기록되지 않았다.

```text
source commit
builder identity
build environment
SBOM
signature
provenance
```

## 11.2 영구화된 부분

```text
image pin ledger
pin↔Kustomization↔ECR 검사
GitHub workflow_dispatch
pin + latest 동시 push
OIDC trust 실제 repo 정렬
실제 ECR resource ARN 기반 policy
local rebuild fallback
linux/amd64 명시
```

## 11.3 남은 부채

```text
tag 선언 중복
mutable e2e tag 가능성
digest pin 미사용
backend commit과 manifest revision 자동 연결 없음
image signing/verification 없음
SBOM 및 provenance 정책 미정
ECR 보존 vs 삭제 비용 정책 미정
```

---

# Step 12. 권장 재배포 runbook

## 12.1 인프라 준비

```text
[ ] ECR repositories Terraform apply 완료
[ ] github-actions-ecr-push-role 존재
[ ] OIDC provider와 trust subject 일치
[ ] repository push policy가 실제 ARN을 포함
```

## 12.2 artifact rebuild

기본 경로:

```text
GitHub Actions
  Build and Push to Amazon ECR
  service=all
```

fallback:

```powershell
.\rebuild-ecr-image-pins.ps1 -Execute
```

## 12.3 배포 전 gate

```powershell
.\check-ecr-image-pins.ps1
```

완료 조건:

```text
[ ] 모든 pin과 Kustomization tag 일치
[ ] 모든 ECR repository 존재
[ ] 모든 pin tag 존재
[ ] image platform이 node architecture와 일치
[ ] GitOps sync 전에 gate 통과
```

## 12.4 배포 후 검증

```text
[ ] Pod event에 ErrImagePull 없음
[ ] 모든 imageID/digest 기록
[ ] 예상 tag/digest와 실제 containerStatus.imageID 비교
[ ] 새 Pod Ready
[ ] rollback image digest 확인
```

---

## 최종 원인 트리

```text
workload ImagePullBackOff
│
├─ kubelet이 요청한 tag가 ECR에 없음
│  ├─ GitOps는 e2e* 고정 tag 사용
│  └─ teardown이 ECR repository와 image 강제 삭제
│
├─ 자동 재생성 경로도 불일치
│  ├─ 기존 CI는 latest 중심
│  ├─ workflow_dispatch 부재
│  ├─ OIDC trust는 실제 Git owner와 다름
│  └─ IAM policy는 존재하지 않는 localy-* repo ARN 사용
│
├─ 응급 복구
│  ├─ 로컬 Docker build
│  ├─ Kustomization 요구 tag로 push
│  └─ Pod image pull 복구
│
├─ 영구 개선
│  ├─ image-pins.yaml
│  ├─ pin tag + latest CI push
│  ├─ workflow_dispatch
│  ├─ 실제 repo identity 기반 OIDC trust
│  ├─ Terraform ECR ARN 기반 IAM
│  ├─ check script
│  └─ rebuild fallback script
│
└─ 남은 부채
   ├─ pin이 여러 파일/repo에 중복
   ├─ mutable tag
   ├─ digest promotion 미구현
   ├─ source↔artifact provenance 부족
   └─ registry 보존 정책 미정
```

## 한 문장으로 남기는 교훈

**재배포 가능한 시스템은 infrastructure와 manifest만 다시 만드는 시스템이 아니라, 동일한 source에서 검증 가능한 image artifact를 다시 만들고 GitOps가 선언한 정확한 reference로 공급할 수 있는 시스템이다.**
