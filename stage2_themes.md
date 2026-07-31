# 🗺️ Stage 2: 5대 물리 영역별 자율 안건 테마 정의서 (Theming & Issue Registry)

이 문서는 아키텍처 도출 과정에서 색안경(선입견)을 배제하기 위해, 5대 물리적 코드 영역에 4명의 전문 에이전트(Platform, DevSecOps, SRE, FinOps)를 직접 투입하여 도출한 **'자율 안건(Raw Issues)'**과, 이를 중복 제거하여 묶어낸 **'핵심 테마(Themes)'**를 기록하는 통합 저장소입니다.

모든 영역(Area 1 ~ 5)에 대한 테마화(Theming) 작업이 완료된 후, 이 테마들을 순차적으로 테이블에 올려 난상 토론을 전개하고 최종 마스터 설계도를 주조합니다.

---

## [Area 1] `localy-backend` 소스코드 빌드 및 파이프라인 영역

* **정찰 수행일**: 2026-07-26
* **타겟 파일 좌표**:
  * `.github/workflows/build-push-ecr.yml`
  * `Localy/*-service/Dockerfile` (6개 마이크로서비스 개별 Dockerfile)
* **투입 담당자**: Platform, DevSecOps, SRE, FinOps 전문 에이전트

---

### 📦 테마 1. [CI 파이프라인 트리거 및 빌드 격리 아키텍처]
* **개요**: 변경된 코드 범위와 상관없이 모든 서비스를 통째로 빌드하여 자원을 낭비하는 구조적 문제와 환경 확장성 제약.
* **에이전트별 날것의 안건 상세**:
  1. **디렉터리 경로 기반 변경 감지(Path-based Filtering) 부재**: 
     - *지적*: Platform, SRE, FinOps
     - *내용*: `Localy/**` 내의 단 1줄 코드 변경(예: `user-service`만 수정)에도 Matrix 전략에 의해 6개 서비스(`edge`, `user`, `store`, `cart`, `order`, `payment`) 전체가 병렬로 빌드 및 ECR 푸시됨. CI 컴퓨팅 시간(GHA 러너 분)이 5배 이상 낭비되고 ECR 용량이 불필요하게 팽창함.
  2. **AWS Account ID 하드코딩 및 노출**: 
     - *지적*: DevSecOps
     - *내용*: 워크플로우 YAML 파일 내에 IAM Role ARN과 AWS Account ID(`533003975005`)가 명시적으로 작성되어 있어, 저장소 공유 시 인프라 계정 식별자가 노출되는 컴플라이언스 위험 존재.
  3. **다중 환경 확장성 부족**: 
     - *지적*: Platform
     - *내용*: 단일 대상의 IAM Role만 하드코딩되어 있어 추후 Dev, Staging, Prod 등으로 클라우드 계정이 분리될 때 동적으로 타겟을 전환하기 어려운 경직된 구조.

---

### 🛠️ 테마 2. [Docker & Gradle 빌드 속도 및 캐싱 최적화]
* **개요**: 로컬 및 CI 파이프라인 환경에서 의존성 라이브러리 캐시를 전혀 활용하지 못해 빌드 속도가 극도로 느려지는 아키텍처 결함.
* **에이전트별 날것의 안건 상세**:
  1. **Dockerfile 레이어 순서 역전 (Gradle 의존성 캐시 붕괴)**:
     - *지적*: Platform, SRE, FinOps
     - *내용*: 모든 Dockerfile에서 `./gradlew clean build`를 실행하기 전에 소스코드(`COPY src ./src`)를 먼저 복사함. Java 소스코드가 단 한 글자라도 수정되면 Docker 레이어 캐시가 무효화되어, 매 빌드마다 Gradle Wrapper 및 수백 MB의 의존성 라이브러리를 인터넷에서 새로 다운로드함.
  2. **GitHub Actions Buildx 및 Gradle Home 캐시 미연동**:
     - *지적*: Platform, FinOps
     - *내용*: CI 파이프라인에서 기본 `docker build`를 사용하고 있어 Docker Layer Cache(`type=gha` 등)를 활용하지 못하며, GHA 러너 내부에 `~/.gradle/caches` 디렉터리 캐싱이 빠져 있어 매번 콜드 스타트 빌드가 일어남.
  3. **빌드 컨텍스트 오염 (`.dockerignore` 부재)**:
     - *지적*: Platform
     - *내용*: 서비스 폴더 내에 `.dockerignore` 파일이 없어 IDE 설정 파일, 로컬 빌드 결과물, 불필요한 임시 파일들이 Docker 데몬의 빌드 컨텍스트로 통째로 전송되어 빌드 준비 속도를 떨어뜨림.
  4. **`settings.gradle` 복사 누락으로 인한 빌드 불일치**:
     - *지적*: Platform, SRE
     - *내용*: `user-service`를 제외한 5개 서비스의 Dockerfile에서 `settings.gradle`을 복사하지 않고 빌드함. Gradle 프로젝트 메타데이터가 유실되어 root project 이름이 빌드 디렉터리명인 `app`으로 강제 설정되는 묵시적 에러 유발.
  5. **불확정적인 와일드카드(`*.jar`) 파일 복사**:
     - *지적*: Platform, SRE, DevSecOps, FinOps
     - *내용*: Spring Boot Gradle 빌드는 기본적으로 실행 가능한 Fat JAR와 가벼운 `-plain.jar` 두 개를 생성함. `COPY --from=builder /app/build/libs/*.jar app.jar` 구문은 두 JAR 중 어떤 것을 복사할지 불확정적이며, 빌드 실패나 의도치 않은 바이너리 실행을 유발할 수 있음.
  6. **불필요한 `./gradlew clean` 명령어 수행**:
     - *지적*: FinOps
     - *내용*: Docker 빌더 컨테이너는 매번 격리된 깨끗한 임시 환경에서 시작되므로 `clean` 태스크를 수행할 이유가 없으며, 오히려 빌드 오버헤드만 가중시킴.
  7. **불변성 없는 Base Image 태그 사용**:
     - *지적*: DevSecOps
     - *내용*: `eclipse-temurin:17-jdk-alpine`, `17-jre-alpine` 등 unpinned 태그를 사용 중. 원격 레지스트리에서 태그 내용이 갱신될 경우 예상치 못한 OS 패키지 업데이트로 빌드 일관성이 깨질 위험.

---

### 🛡️ 테마 3. [컨테이너 런타임 보안 및 DevSecOps 가드레일]
* **개요**: 컨테이너가 최고 관리자(Root) 권한으로 실행되는 취약점을 방치하고 있으며, 파이프라인 상에 보안 검증 관문이 없음.
* **에이전트별 날것의 안건 상세**:
  1. **Root 권한 실행 방치 (High Risk)**:
     - *지적*: Platform, SRE, DevSecOps, FinOps
     - *내용*: `user-service` 단 1개를 제외하고, 나머지 5개 서비스(`edge`, `store`, `cart`, `order`, `payment`)의 Dockerfile 하단에서 Non-Root 사용자 설정(`USER appuser`)이 주석 처리되어 있음. 애플리케이션 RCE 취약점 발생 시 호스트 시스템 전체로 권한이 탈취되는 보안 취약점.
  2. **운영 런타임 내 불필요한 네트워크 유틸리티(`curl`) 방치**:
     - *지적*: DevSecOps, FinOps
     - *내용*: `user-service`의 최종 JRE 이미지에 디버깅 명목으로 `curl` 패키지가 설치(`apk add curl`)되어 있음. 운영 환경에서 공격자가 SSRF 공격이나 악성 스크립트를 다운로드하는 통로로 악용할 수 있음.
  3. **CI 사전 품질 검증(Quality Gate) 및 테스트 건너뛰기**:
     - *지적*: SRE, DevSecOps
     - *내용*: Dockerfile 내부와 파이프라인 모두에서 `./gradlew build -x test`로 테스트를 명시적으로 스킵함. CI 파이프라인 앞단에 단위/통합 테스트 및 정적 코드 분석(SAST) 단계가 전혀 없음.
  4. **컨테이너 이미지 취약점 스캔(CVE Scanner) 부재**:
     - *지적*: SRE, DevSecOps
     - *내용*: ECR로 이미지를 푸시하기 전에 Trivy, Grype 등을 통한 OS 패키지 및 라이브러리 취약점 스캐닝 절차가 없음.
  5. **이미지 무결성 검증을 위한 암호학적 서명(Cosign) 부재**:
     - *지적*: SRE, DevSecOps
     - *내용*: 빌드된 컨테이너 이미지에 서명하고 검증하는 절차가 없어, K8s 클러스터에 배포되는 이미지가 CI에서 정상 빌드된 원본인지 검증할 수 없음.

---

### ⚙️ 테마 4. [배포 추적성, 안정성 및 JVM 런타임 튜닝]
* **개요**: 이미지 버전 불변성 부재로 클러스터 롤백이 불가하며, 런타임 설정 미비로 오토스케일링 및 장애 복구 시 서비스 불안정 유발.
* **에이전트별 날것의 안건 상세**:
  1. **`latest` 단일 태그 배포 전략 (롤백 및 추적 불가)**:
     - *지적*: Platform, SRE, DevSecOps, FinOps
     - *내용*: CI와 로컬 스크립트 모두 오직 `latest` 태그만 ECR에 덮어씀. Git Commit SHA나 시맨틱 버전 태그가 없어 현재 팟에 뜬 코드가 어떤 커밋인지 감사(Audit)할 수 없으며, 장애 발생 시 이전 버전으로의 즉각적인 K8s 롤백이 불가능함.
  2. **동시성 배포 레이스 컨디션 위험**:
     - *지적*: SRE
     - *내용*: 짧은 간격으로 코드가 연속 푸시될 경우 CI 파이프라인들이 서로 경쟁하며 `latest` 태그를 덮어써 클러스터 내의 팟들이 서로 다른 커밋의 코드를 실행하는 불일치 발생.
  3. **모니터링 포트 불일치 (`9090` vs App Port)**:
     - *지적*: SRE
     - *내용*: `application.yml`에서는 Actuator/Prometheus 메트릭 관리 포트로 `9090`을 지정했으나, Dockerfile에는 메인 앱 포트(예: 8090, 9000 등)만 `EXPOSE` 되어 있어 사이드카나 서비스 모니터 연동 시 포트 메타데이터 혼선 유발.
  4. **`store-service` Graceful Shutdown 유예기간 설정 누락**:
     - *지적*: SRE
     - *내용*: 타 서비스들과 달리 `store-service`의 `application.yml`에는 `spring.lifecycle.timeout-per-shutdown-phase: 45s` 설정이 누락되어 기본값(30초)이 적용됨. K8s Pod 종료 유예기간과 충돌 시 DB 커넥션 반납 전 SIGKILL로 강제 종료될 위험.
  5. **Keycloak 서킷 브레이커 장애 전이(Cascading Failure) 위험**:
     - *지적*: SRE
     - *내용*: `user-service`에서 Keycloak 서킷 브레이커가 전역 헬스 인디케이터에 등록되어 있어, Keycloak 일시 장애 시 `user-service` 헬스체크가 DOWN되어 K8s Liveness Probe에 의해 정상적인 User 팟들까지 연속 무한 재시작(Restart Loop)되는 장애 전이 위험.
  6. **컨테이너 환경 JVM 메모리 비율 옵션 미설정 (OOM Risk)**:
     - *지적*: Platform, SRE, FinOps
     - *내용*: `ENTRYPOINT`에 `-XX:MaxRAMPercentage=75.0` 등의 컨테이너 인식 메모리 튜닝 옵션이 없음. JVM이 호스트 노드의 전체 메모리를 기준으로 Heap을 계산할 경우 K8s Memory Limit에 걸려 OOMKilled 강제 종료가 발생할 수 있음.

---

## [Area 2] `localy` 인프라 결합 및 부트스트랩 정의 영역

* **정찰 수행일**: 2026-07-26
* **타겟 파일 좌표**:
  * `infrastructure/environments/prod/l4-bootstrap/` (ArgoCD Root App 및 Helm 연동 구조)
  * `infrastructure/environments/prod/l3-app-integration/github_actions_oidc.tf` (GitHub Actions OIDC IAM 권한 연동)
* **투입 담당자**: Platform, DevSecOps, SRE, FinOps 전문 에이전트

---

### 🔗 테마 1. [GitOps 부트스트랩 핸드오프 및 레이스 컨디션 아키텍처]
* **개요**: Terraform(IaC)에서 ArgoCD(GitOps)로 제어권이 넘어가는 과정에서 발생하는 CRD 등록 지연, 상태 Drift 충돌, 의존성 불일치 문제.
* **에이전트별 날것의 안건 상세**:
  1. **ArgoCD Application CRD 등록 레이스 컨디션 (Race Condition)**:
     - *지적*: Platform, SRE
     - *내용*: `helm_release.argocd_apps`가 `depends_on = [helm_release.argocd]`에 의존하고 있으나, Terraform의 `depends_on`은 Helm 차트 배포 API 호출의 완료만 기다릴 뿐 K8s API Server의 `Application` CRD 캐시 등록 및 Webhook 활성화 완료를 보장하지 못함. 초기 클러스터 구축 시 CRD 미인식(`no matches for kind "Application"`)으로 인해 부트스트랩이 즉시 실패함.
  2. **Terraform vs GitOps 이중 소유권 상태 충돌 (Dual-Ownership Drift)**:
     - *지적*: Platform, SRE
     - *내용*: Root App of Apps(`root-app-of-apps`)를 Terraform Helm Release로 배포하고 나면, 이후 ArgoCD의 자동 Self-Healing이나 Git 저장소 변경에 의해 애플리케이션 상태가 바뀔 때마다 Terraform State와의 심각한 Drift가 발생함. 후속 `terraform apply` 실행 시 GitOps가 관리 중인 상태를 덮어쓰거나 충돌을 일으킴.
  3. **L3 인프라와 L4 워크로드 간 의존성 및 시점 불일치 (Readiness Disconnect)**:
     - *지적*: SRE
     - *내용*: L4에서 ArgoCD가 부트스트랩되는 즉시 Git 저장소에서 앱들을 Pull하여 배포하려 시도함. 그러나 L3에서 준비되어야 할 AWS 리소스(ECR 이미지, IAM OIDC Role, RDS 데이터베이스, Secrets 등)가 완료되지 않았거나 ECR에 컨테이너 이미지가 푸시되기 전이라면 즉시 `ImagePullBackOff` 또는 `AccessDenied` 등 광범위한 CrashLoop에 빠짐.
  4. **Inline HCL `yamlencode` 구조의 유지보수성 및 자동완성 제약**:
     - *지적*: Platform
     - *내용*: `l4-bootstrap/main.tf` 내부에서 K8s 매니페스트 구조를 `yamlencode({ applications = [ ... ] })` 형태로 하드코딩하여 작성함. K8s 스키마 검증과 IDE 자동완성을 받을 수 없어 오타나 구조적 에러에 취약하며, 독립적인 K8s 매니페스트나 템플릿 파일(`templatefile()`) 대비 모듈성이 떨어짐.

---

### 🛡️ 테마 2. [GitHub Actions OIDC 인증 보안 및 최소 특권 제어]
* **개요**: CI 파이프라인의 AWS OIDC 인증 연동 시 과도하게 넓은 신뢰 범위와 파괴적인 ECR 권한으로 인한 클라우드 계정 탈취 및 인프라 파괴 위험.
* **에이전트별 날것의 안건 상세**:
  1. **치명적 취약점: Wildcard `sub` Claim (`repo:*/*:*`) 허용 (Critical Security Risk)**:
     - *지적*: DevSecOps, Platform, SRE, FinOps (전원 일치 지적)
     - *내용*: `github_actions_oidc.tf`의 OIDC Trust Policy에서 대상 주체를 `"token.actions.githubusercontent.com:sub" = "repo:*/*:*"`로 완전 개방함. 이는 **전 세계 어떤 외부인의 GitHub 계정이나 저장소**에서도 AWS STS를 통해 프로덕션 ECR Push Role을 Assume할 수 있음을 의미하며, 공격자가 악성 컨테이너 이미지를 프로덕션 ECR에 덮어쓸 수 있는 극심한 취약점.
  2. **ECR 권한 최소 특권 원칙 위반 (`AmazonEC2ContainerRegistryPowerUser`)**:
     - *지적*: DevSecOps, Platform, SRE, FinOps
     - *내용*: IAM Role에 광범위한 `PowerUser` 관리형 정책이 부착되어 있어, 계정 내 **모든 ECR 저장소**에 대한 생성/수정 및 파괴적 삭제(`ecr:BatchDeleteImage`) 권한을 가짐. 단일 파이프라인 탈취나 스크립트 오작동 시 타 서비스의 프로덕션 이미지가 삭제되거나 AWS 계정 전역에 Shadow ECR 리소스가 난립할 수 있음.
  3. **계정 전역 리소스(OIDC Provider)의 환경 레벨(L3 Prod) 정의 중복 충돌**:
     - *지적*: Platform, FinOps
     - *내용*: `aws_iam_openid_connect_provider.github`는 AWS 계정 단위의 Global 리소스임에도 환경별 폴더인 `environments/prod/l3-app-integration` 내부에 생성하도록 정의됨. 향후 동일 AWS 계정 내에 Dev, Staging 등 타 환경을 추가 구축할 경우 `EntityAlreadyExists` 에러와 함께 IaC 충돌 유발.
  4. **다중 환경 및 브랜치 보호 스코핑 부재**:
     - *지적*: DevSecOps, Platform
     - *내용*: 단일 정적 Role(`github-actions-ecr-push-role`)에 환경별 보호(`environment:prod`)나 Git 브랜치 검증(`refs/heads/main`), `job_workflow_ref` 제한이 없어, 검증되지 않은 개발 브랜치나 포크(Fork)된 저장소의 PR에서도 프로덕션 ECR Role을 사용할 수 있음.
  5. **하드코딩된 인증서 지문(Thumbprint) 관리 위험**:
     - *지적*: DevSecOps, SRE, Platform
     - *내용*: OIDC Provider 설정에 인증서 Thumbprint(`6938fd4d98bab...`)가 정적으로 하드코딩됨. GitHub Action 인증서 상위 CA가 갱신될 경우 인증이 즉시 끊겨, 재해 복구(DR)나 긴급 배포가 필요한 상황에서 CI 파이프라인이 전면 중단될 위험.

---

### ☸️ 테마 3. [ArgoCD Root App of Apps 동기화 제어 및 거버넌스 가드레일]
* **개요**: Root App of Apps가 안전장치나 권한 격리 없이 클러스터 전체에 대한 제어권을 맹목적으로 행사하여 발생하는 보안 및 장애 파급 위험.
* **에이전트별 날것의 안건 상세**:
  1. **무제한 `default` AppProject 사용 및 네임스페이스 격리 부재**:
     - *지적*: DevSecOps, Platform
     - *내용*: Root App of Apps가 ArgoCD의 기본 `default` 프로젝트(`project = "default"`)에 할당됨. 소스 Repo 화이트리스트, 대상 Cluster/Namespace 제한, 리소스 Kind(예: `ClusterRoleBinding`, `MutatingWebhookConfiguration`, Pod Security Policy 등) 거부 정책이 없어 클러스터 최고 권한 리소스를 무제한 생성할 수 있음.
  2. **무조건적 자동 Prune / Self-Heal의 파괴적 폭발 반경 (Blast Radius)**:
     - *지적*: SRE, Platform, FinOps
     - *내용*: 자동 동기화 정책에 `prune=true`, `selfHeal=true`가 Sync Windows나 `ignoreDifferences`, Backoff 제한 없이 적용됨. Git 매니페스트 경로 오타나 부주의한 병합 시 클러스터 내 전체 서비스 워크로드(Pod, PVC, Ingress)가 연쇄 삭제(Cascade Deletion)되며, SRE의 긴급 장애 대응(Hotfix) 조치를 ArgoCD가 반제어적으로 즉시 덮어써 복구를 방해함.
  3. **가변 브랜치(`targetRevision="main"`) 추적으로 인한 비결정적 동기화**:
     - *지적*: SRE, Platform
     - *내용*: 불변하는 Git Tag나 커밋 SHA 대신 움직이는 브랜치(`main`)를 추적함. DR 클러스터 복구 시점에 `main` 브랜치 최신 끝단에 검증되지 않거나 깨진 코드가 병합되어 있을 경우 복구 직후 부트-루프(Boot-loop) 발생.
  4. **`CreateNamespace=true`를 통한 거버넌스 없는 네임스페이스 동적 자생**:
     - *지적*: SRE
     - *내용*: 애플리케이션 매니페스트가 자율적으로 네임스페이스를 생성하도록 허용되어 있음. Terraform L2/L3 인프라단에서 정의해야 할 `ResourceQuota`, `LimitRange`, `NetworkPolicy`, Pod Security Label 등이 빠진 채 네임스페이스가 자생하여 노이지 네이버 자원 고갈 및 OOM 위험 노출.
  5. **Git 저장소 인증(Secret) 및 커밋 서명(GPG/Cosign) 검증 부재**:
     - *지적*: DevSecOps, Platform
     - *내용*: Git URL이 HTTPS로 참조되지만 인증 Secret 바인딩이 누락되어 있어 Private Repo 전환 시 부트스트랩이 불가능하며, Git 커밋에 대한 암호학적 서명 검증이 없어 악의적이거나 비인가된 커밋이 클러스터에 맹목적으로 동기화됨.

---

### ♻️ 테마 4. [인프라-워크로드 생애주기 관리, 비용 효율성 및 DR 복원력]
* **개요**: 인프라 프로비저닝(Terraform)과 애플리케이션 운영(K8s/GitOps) 간의 제어권 중첩 및 생애주기 불연속성으로 인한 비용 누수와 재해 복구 실패 위험.
* **에이전트별 날것의 안건 상세**:
  1. **ArgoCD 컨트롤러 자원 미설정(Requests/Limits) 및 동적 렌더링 오버헤드**:
     - *지적*: FinOps, SRE, Platform
     - *내용*: ArgoCD Helm 차트 배포 시 core 컨트롤러(`server`, `repo-server`, `application-controller` 등)에 대한 Resource Requests/Limits를 생략하고, 전역적으로 Kustomize `--enable-helm` 동적 렌더링 옵션을 켜둠. 매 동기화 루프마다 CPU와 메모리가 급증하여 노드 오버프로비저닝 및 불필요한 Karpenter 스케일링을 유발함.
  2. **Teardown 시 K8s Finalizer 교착 및 동적 AWS 리소스 고아화 (Resource Orphanage)**:
     - *지적*: FinOps, SRE, DevSecOps
     - *내용*: `terraform destroy` 수행 시 ArgoCD의 Application Finalizer(`resources-finalizer.argocd.argoproj.io`)로 인해 리소스 삭제가 교착(Deadlock)되어 VPC/EKS 삭제가 차단됨. 또한 ArgoCD가 띄운 K8s Ingress/Service가 생성한 AWS ALB, ENI, Target Group과 비어있지 않은 ECR(`force_delete = false`)이 Terraform State 외부에 고아 리소스로 남아서 지속적인 클라우드 비용 누수를 일으킴.
  3. **Terraform CI execution의 직무 분리(SoD) 위반 및 평문 상태 파일 노출**:
     - *지적*: DevSecOps
     - *내용*: Terraform L4 부트스트랩 파이프라인이 `aws eks get-token`을 통해 K8s 최고 관리자 권한을 직접 획득해 클라우드와 클러스터 제어권을 한곳에서 동시에 장악함. 또한 SSM 파라미터(CA 인증서, 클러스터 정보 등)를 S3 상태 파일에 평문 저장하며, S3 암호화(`encrypt=true`) 및 DynamoDB 잠금 보장이 없어 동시 실행 시 상태 오염 위험.
  4. **리전 및 저장소 종속성 하드코딩 (멀티 리전 DR 유연성 결여)**:
     - *지적*: SRE, Platform
     - *내용*: AWS 리전(`ap-northeast-2`)과 S3 백엔드 버킷 이름, Git Repo 주소 등 핵심 파라미터가 코드 내부에 하드코딩되어 있어, 재해 복구(DR) 시 2차 리전(`ap-northeast-1` 등)으로의 자동화된 신속 복구가 불가능함.

## [Area 3] `localy-manifests` 부트스트랩 및 ArgoCD 애플리케이션 관리 정의 영역

* **정찰 수행일**: 2026-07-26
* **타겟 파일 좌표**:
  * `bootstrap/` 폴더 (`platform-addons-root.yaml`, `workloads-root.yaml`, `platform-apps/`, `workload-apps/`)
  * `argocd-apps/` 폴더 (`base/`, `overlays/`)
  * `apps/` 폴더 전체 (`alb-controller`, `cert-manager`, `services`, `storage` 등 13개 핵심 애플리케이션 정의)
* **투입 담당자**: Platform, DevSecOps, SRE, FinOps 전문 에이전트

---

### 🧠 테마 1. [GitOps Root 아키텍처 스플릿 브레인(Split-Brain) 및 저장소 파편화]
* **개요**: Root App of Apps가 두 곳에 중복 정의되어 발생하는 이중 제어권 충돌, 동일 앱 간의 버전/설정 불일치, 방치된 고아 폴더 문제.
* **에이전트별 날것의 안건 상세**:
  1. **이중 Root App of Apps 경쟁 구조 (`bootstrap/` vs `argocd-apps/`)**:
     - *지적*: Platform, FinOps, SRE (전원 일치 지적)
     - *내용*: Root 매니페스트가 `bootstrap/`(Platform Addons Root + Workloads Root -> `platform/` 및 `workloads/` 바라봄)과 `argocd-apps/`(Kustomize Root -> `apps/` 및 `workloads/` 바라봄) 두 곳에 완전 분리되어 공존함. 클러스터 제어 주체가 분산된 '스플릿 브레인(Split-Brain)' 구조로서, 두 Root가 동시 활성화될 경우 ArgoCD가 동일한 워크로드와 컨트롤러에 대해 무한히 Sync와 Prune을 반복하는 파괴적인 통제권 경쟁(Thrashing Loop) 유발.
  2. **동일 앱 간 치명적 버전 및 설정 충돌 (Version & Configuration Drift)**:
     - *지적*: Platform, FinOps, SRE
     - *내용*: 동일 플랫폼/워크로드가 두 Root에 중복 정의되어 있으며 내용이 심각하게 상충함. 예: `node-local-dns`는 `bootstrap`에서 kubernetes-sigs 차트 v0.1.3을 띄우고 `argocd-apps`에서는 DeliveryHero 차트 v2.8.0을 띄움. `karpenter`는 `bootstrap`에서 빈 기본 차트를 띄우고 `argocd-apps`에서는 IRSA/EKS 설정이 담긴 `values-prod.yaml`을 띄움. 또한 워크로드의 `sync-wave`가 10 vs 20으로 상이하며, 대상 브랜치(`HEAD` vs `main`)와 Replica `ignoreDifferences` 유무까지 불일치함.
  3. **방치된 폴더 및 고아 매니페스트 (Orphaned / Abandoned Directories)**:
     - *지적*: Platform, FinOps, DevSecOps
     - *내용*: `apps/services/`와 `apps/platform-core/`는 `.gitkeep`만 있는 빈 폴더이며, `platform/cilium`, `jaeger`, `otel-collector`, `prometheus-adapter` 및 `workloads/db-migration` 등 완성된 매니페스트들이 어떤 Root App에서도 참조되지 않고 방치됨. 이는 인프라 파편화와 클라우드 자원 관리 사각지대를 유발함.

---

### ☸️ 테마 2. [ArgoCD 동기화 폭발 반경(Blast Radius) 및 파이프라인 교착 위험]
* **개요**: 안전장치 없는 자동 Prune/Self-Heal, CRD 보존 설정 부재, 오토스케일러(HPA)와의 충돌 및 정교하지 못한 Sync Wave로 인한 클러스터 장애 위험.
* **에이전트별 날것의 안건 상세**:
  1. **Root App Finalizer 및 무조건적 Prune/Self-Heal에 의한 연쇄 파괴 (Cascade Deletion)**:
     - *지적*: SRE, DevSecOps, Platform
     - *내용*: Root App과 자식 App 모두에 `prune=true`, `selfHeal=true` 및 `resources-finalizer`가 Backoff 제한 없이 설정됨. Git 오타나 브랜치 병합 오류 시 클러스터 전체 서비스와 컨트롤러가 통째로 연쇄 삭제(Cascade Deletion)되며, SRE의 긴급 장애 대응(Hotfix) 조치를 ArgoCD가 즉시 덮어써 복구를 차단함.
  2. **CRD 보호(`Delete=false`) 부재로 인한 Custom Resource 연쇄 삭제 위험**:
     - *지적*: SRE
     - *내용*: `cert-manager`, `karpenter`, `alb-controller`, `kyverno` 등 CRD를 배포하는 앱들이 `argocd.argoproj.io/sync-options: Delete=false` 없이 `prune=true`로 동작함. 차트 업그레이드나 Prune 시 CRD가 삭제되면 K8s가 클러스터 내의 모든 `Certificate`, `NodePool`, `TargetGroupBinding`을 연쇄 파괴하여 인프라 전면 중단 유발.
  3. **ArgoCD와 HPA(오토스케일러) 간 무한 충돌 (Replication Fighting Loop)**:
     - *지적*: FinOps, SRE
     - *내용*: `argocd-apps/base/` 내 6개 워크로드 앱 전원에 Deployment `spec.replicas`에 대한 `ignoreDifferences` 규칙이 빠져 있음. 트래픽 급증으로 HPA가 Pod을 늘리면 ArgoCD의 Self-Heal이 이를 Git 설정값(2개)으로 강제 축소(Kill)하여 Pod이 끊임없이 생성/삭제되는 무한 루프 및 서비스 중단 발생.
  4. **Sync Wave(동기화 순서) 설계 결함 및 레이스 컨디션**:
     - *지적*: SRE
     - *내용*: `cert-manager`(wave -4)가 Pod Ready 직후 인증서/Webhook 준비 전 `ingress-core`(wave -3)가 떠서 HTTPS 리스너 실패. `karpenter-controller`(wave -2) 직후 `karpenter-provisioner`(wave -1)가 떠서 Webhook API 에러. `keycloak`(wave 10)과 백엔드 마이크로서비스(wave 10)가 동시에 떠서 JWKS/OIDC 초기화 전 Auth CrashLoop 유발.
  5. **무거운 CRD 앱에 대한 `ServerSideApply=true` 누락**:
     - *지적*: SRE, Platform
     - *내용*: `cert-manager`, `alb-controller`, `kube-prometheus-stack`, `kyverno` 등에 `ServerSideApply=true`가 빠져 있어 K8s Client-side apply 어노테이션 256KB 한도(`Too long: must have at most 262144 bytes`) 초과로 동기화 실패.

---

### 🛡️ 테마 3. [GitOps 보안 거버넌스 및 공급망 취약점 가드레일]
* **개요**: 무제한 `default` AppProject 사용, 민감 비밀번호 평문 노출, IRSA 권한 탈취 위험 및 컨테이너 호스트 노드 침해 위험.
* **에이전트별 날것의 안건 상세**:
  1. **100% 무제한 `default` AppProject 사용 (Policy Gaps)**:
     - *지적*: DevSecOps, Platform
     - *내용*: 모든 Application이 `project: default`에 매핑되어 소스 Repo 화이트리스트, 목적지 Namespace(`kube-system`, `argocd` 등), 리소스 Kind(클러스터 권한, Webhook 등) 제한 없이 K8s 최고 권한 리소스를 무제한 생성 가능.
  2. **가변 브랜치(`HEAD`/`main`) 추적 및 커밋/차트 서명 검증 부재**:
     - *지적*: DevSecOps, Platform, SRE
     - *내용*: 불변 Commit SHA나 Tag 대신 가변 참조(`HEAD`, `main`)를 추적하며, 수많은 외부 Helm 저장소(AWS, Grafana, DeliveryHero 등)에서 다운로드할 때 암호학적 서명(Cosign/GPG) 검증이 없어 공급망 오염에 취약.
  3. **IRSA 권한 탈취(Identity Hijacking) 방어 정책 누락**:
     - *지적*: DevSecOps
     - *내용*: `loki`, `alarm-pipeline`을 제외한 `alb-controller`, `cert-manager`, `external-dns`, `karpenter` 등 고권한 AWS IAM 역할이 바인딩된 ServiceAccount에 대한 Kyverno 보호 정책 및 RBAC 가드레일이 없어, 해당 네임스페이스 내 임의 Pod이 IAM 권한 탈취 가능.
  4. **민감 정보 평문 노출 및 컨테이너 호스트 침해 위험**:
     - *지적*: DevSecOps
     - *내용*: `kube-prometheus-stack`에 Grafana 관리자 비밀번호(`SuperSecret123!`)가 평문 하드코딩되어 있고, 백엔드 앱들은 DB 비밀번호를 환경변수(`envFrom`)로 주입하여 유출 위험. 또한 Fluent Bit InitContainer는 Root 권한 및 Host Root 파일시스템(`hostPath` - `/var/log`, `/etc/machine-id` 등)을 마운트하여 호스트 노드 탈취 위험.

---

### 🛠️ 테마 4. [개발자 경험(DevEx) 병목 및 인프라-워크로드 연계 결함]
* **개요**: 다중 환경 구조 미비, 극심한 Boilerplate 반복 작업, 공통 가드레일 고아화 및 Ingress 블랙홀링으로 인한 운영 혼선.
* **에이전트별 날것의 안건 상세**:
  1. **다중 환경(Dev/Staging) 구조 전무 및 10개 Boilerplate 파일 반복**:
     - *지적*: Platform
     - *내용*: 오직 `prod` 오버레이만 존재하여 Dev/Staging 환경 승격(Promotion)이 원천 불가능. 또한 단일 마이크로서비스 추가 시 `ApplicationSet`이나 공통 Helm 차트가 없어 10개의 개별 YAML 파일(Deployment, PDB, NetworkPolicy, ExternalSecret 등)을 일일이 수동 복사/작성해야 하는 극심한 DevEx 병목.
  2. **공통 가드레일(`common/guardrails`) 고아화 및 ResourceQuota 교착**:
     - *지적*: FinOps, DevSecOps
     - *내용*: `common/guardrails`에 CPU/Memory Quota와 LimitRange가 정의되어 있으나 워크로드 Kustomization에 단 한 번도 참조/import되지 않아 실제로 적용되지 않음(고아화). 만약 적용될 경우 `cart-service` HPA 최대치(15개 Pod -> 15Gi Memory)가 Namespace Quota(8Gi)에 걸려 오토스케일링이 교착되는 모순 구조.
  3. **TargetGroupBinding 플레이스홀더 미치환 및 Ingress 블랙홀링**:
     - *지적*: SRE, Platform
     - *내용*: `user-service`, `cart-service`의 `target-group-binding.yaml`에 `"PLACEHOLDER_ARN"`이 그대로 있으며 Prod 오버레이에서 치환되지 않아 ALB 타겟 그룹 등록이 100% 실패함. 또한 공통 Ingress(`ingress-core`)는 도메인(`feifo.click`) 트래픽 전체를 실제 서비스가 아닌 존재하지 않는 `target-app-service`(default namespace)로 라우팅하여 전면 502/503 블랙홀링 유발.

## [Area 4] `localy-manifests/workloads` 및 공통 컴포넌트(`common/`) 정의 영역

* **정찰 수행일**: 2026-07-26
* **타겟 파일 좌표**:
  * `workloads/` 폴더 내 7개 서비스 디렉터리 (`cart-service`, `db-migration`, `edge-service`, `order-service`, `payment-service`, `store-service`, `user-service`)의 Base 및 Prod Overlay
  * `common/guardrails/` 폴더 (`limit-range.yaml`, `network-policy.yaml`, `resource-quota.yaml` 등 공통 정책)
* **투입 담당자**: Platform, DevSecOps, SRE, FinOps 전문 에이전트

---

### 🧠 테마 1. [오토스케일러(HPA/KEDA)와 Namespace ResourceQuota 간의 치명적 교착 및 자원 산정 오류]
* **개요**: 오토스케일러 최대 Replica 설정과 K8s Namespace Quota 간의 모순으로 인한 스케일업 차단, 명시적 자원 할당 누락 및 Burst 플래핑 문제.
* **에이전트별 날것의 안건 상세**:
  1. **HPA/KEDA 최대 Replica 설정과 ResourceQuota 간의 치명적 모순(Deadlock)**:
     - *지적*: FinOps, SRE, DevSecOps (공동 지적)
     - *내용*: `common/guardrails/resource-quota.yaml`이 Namespace CPU 한도를 4.0 CPU, Memory를 8Gi로 제한함. 그러나 `payment-service`(Limit 1.5 CPU)는 KEDA로 최대 10개 Pod까지 늘어나도록 설정되어 있어, 실제로는 2개 Pod 이상 증설 시 K8s API가 `403 Forbidden / ResourceQuota exceeded` 에러를 내며 스케일업을 원천 차단함(80% 스케일링 역량 상실!). 동일한 이유로 `order-service`는 최대 4개(60% 상실), `cart-service`는 최대 8개(46% 상실)에서 강제 교착(Hard-Locked)되어 트래픽 급증 시 대규모 서비스 장애 유발.
  2. **명시적 자원 할당(Requests/Limits) 누락 및 LimitRange 의존 위험**:
     - *지적*: FinOps, DevSecOps, SRE
     - *내용*: `cart-service`, `edge-service`는 Request/Limit이 전무하여 LimitRange(100m CPU / 256Mi Mem Request)에 맹목적으로 의존함. 특히 `cart-service`는 JVM Heap을 75%(`-XX:MaxRAMPercentage=75.0`)로 설정했으나 K8s는 256Mi를 기준으로 스케줄링하여 Node 메모리 초과 및 OOM Kill 발생 위험. 또한 `store-service`, `user-service`는 CPU Limit을 생략함.
  3. **과도한 Burst 비율 및 초민감 스케일링 플래핑(Flapping)**:
     - *지적*: FinOps, SRE
     - *내용*: `payment`(6x CPU Burst)와 `order`(5x CPU Burst)는 Pod 다수가 동시 Burst 시 Node CPU 스틀링 발생. `edge-service`는 CPU LimitRange 100m 기준 60% 사용률(단 60m CPU!)에서 HPA가 즉시 작동하여 미세한 트래픽에도 Pod이 무한 생성/삭제(Flapping)되는 비용 누수 유발.

---

### 🛡️ 테마 2. [워크로드 보안 고립화 실패 및 데이터베이스 최소 권한(Least Privilege) 붕괴]
* **개요**: Pod 보안 컨텍스트 누락으로 인한 Root 실행 위험, DB 최소 권한 붕괴 및 공유 마스터 계정 오용, 횡적 이동(Lateral Movement) 취약점.
* **에이전트별 날것의 안건 상세**:
  1. **Pod/Container 보안 컨텍스트 전무 (Root 권한 실행 및 파일시스템 변조 위험)**:
     - *지적*: DevSecOps
     - *내용*: 6개 서비스 전원 `runAsNonRoot: true`, `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false`, Capability Drop, Seccomp Profile이 빠져 있어 기본적으로 Root(`uid 0`)로 실행되며 런타임 시 악성 바이너리 실행 및 권한 상승에 무방비.
  2. **DB 최소 권한 붕괴 및 전사 공유 마스터 계정 오용**:
     - *지적*: DevSecOps, SRE
     - *내용*: `db-migration` Job에서 도메인별 최소 권한 IAM 계정(`storeuser`, `orderuser`, `paymentuser`)을 생성하지만, 정작 서비스 매니페스트는 이를 전혀 쓰지 않고 AWS Secrets Manager의 단일 전사 마스터 계정(`localy-prod-database-credentials`)을 100% 공유 사용함. 심지어 Job 스크립트는 `GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public`을 모든 서비스 유저에게 부여하여 도메인 간 데이터 분리(Isolation)가 완전히 붕괴됨.
  3. **NetworkPolicy 횡적 이동(Lateral Movement) 및 외부 C2 exfiltration 위험**:
     - *지적*: DevSecOps, SRE
     - *내용*: DB(5432) 및 Kafka(9092) Egress 규칙에 목적지 IP/Namespace 제한(`to:`)이 없어 VPC 내 임의의 DB/브로커에 접속 가능. 특히 TCP 443 Egress가 무제한 개방되어 악성코드 통신(C2 Callback) 및 데이터 탈취에 취약하며, `cart-service` $\rightarrow$ `order-service` 통신은 NetworkPolicy에서 누락되어 결제 시 호출이 차단되는 구성 오류 발견.
  4. **민감 비밀번호 환경변수(`envFrom`) 주입 유출 Risk**:
     - *지적*: DevSecOps, Platform
     - *내용*: `order-service`, `payment-service`는 DB 비밀번호를 Volume Mount 대신 `envFrom: secretRef`로 주입하여 프로세스 테이블(`/proc/self/environ`), 크래시 덤프, APM Trace 로그에 비밀번호가 평문 노출됨.

---

### ☸️ 테마 3. [트래픽 무중단 배포(Zero-Downtime) 결함 및 AWS ALB 연동 끊김 위험]
* **개요**: Deregistration Delay와 PreStop Hook 간의 타임아웃 불일치, TGB 명칭/포트 불일치, Readiness Gate 누락 및 프로브 부재.
* **에이전트별 날것의 안건 상세**:
  1. **ALB Deregistration Delay vs PreStop Hook / Grace Period 모순**:
     - *지적*: SRE
     - *내용*: AWS ALB Target Group의 기본 Deregistration Delay는 300초(5분)이나, 워크로드의 `preStop` Hook(15초)과 `terminationGracePeriodSeconds`(45~60초)는 이보다 훨씬 짧음. 배포나 Scale-In 시 ALB가 트래픽을 비우기 전에 Kubelet이 Pod을 강제 종료(SIGKILL)하여 504 Gateway Timeout 유발.
  2. **TargetGroupBinding(TGB) 플레이스홀더 미치환 및 명칭 불일치**:
     - *지적*: SRE, Platform
     - *내용*: `cart-service`, `user-service`, `edge-service`의 `targetGroupARN`이 Prod 오버레이에서도 `"PLACEHOLDER_ARN"` 등으로 치환되지 않고 방치됨. 또한 `cart`와 `user`의 TGB가 참조하는 Service 명칭(`cart-service-svc`, `user-service-svc`)과 실제 Service 명칭(`cart-service`, `user-service`)이 불일치하여 ALB 연동이 100% 실패함.
  3. **AWS ALB Readiness Gate(`readinessGates: []`) 누락 및 설정 불일치**:
     - *지적*: SRE, Platform
     - *내용*: `cart`, `store`, `user`는 실제 TGB 연동 유무와 상관없이 명시적으로 빈 배열(`[]`)을 설정했고, 정작 게이트웨이인 `edge-service`는 이를 빠뜨림. ALB Target Health 등록이 완료되기 전에 롤링 업그레이드가 진행되어 배포 중 502 Bad Gateway 발생.
  4. **프로브(Liveness/Readiness/Startup) 전무 및 1초 타임아웃 위험**:
     - *지적*: SRE
     - *내용*: `cart`, `store`, `user`는 Health Probe가 전혀 없어 Deadlock 시 자동 복구가 불가능하며, `order`, `payment`는 Startup Probe가 없어 DB/MSK 초기화 지연 시 SIGKILL 무한 부트루프 발생. `edge-service`는 Liveness를 엉뚱한 경로로 검사하며 기본 타임아웃이 1초로 짧아 잦은 오진(Kill) 유발.

---

### 🛠️ 테마 4. [Kustomize 매니페스트 파편화 및 공통 가드레일 고아화 (DevEx 병목)]
* **개요**: 공통 가드레일(`common/guardrails`) 미적용으로 인한 정책 공백, 10여 개 Boilerplate YAML 중복 복사, 마이크로서비스 간 설정 불일치.
* **에이전트별 날것의 안건 상세**:
  1. **공통 가드레일(`common/guardrails`) 미적용(고아화) 및 표준 파편화**:
     - *지적*: Platform, DevSecOps
     - *내용*: `common/guardrails/kustomization.yaml`에 Component로 정의된 LimitRange와 ResourceQuota가 7개 워크로드 중 단 한 곳의 `kustomization.yaml`에도 `components:`로 import되지 않고 방치됨(고아화). 이로 인해 각 팀이 baseline 정책 없이 제각각 매니페스트를 작성함.
  2. **10여 개 Boilerplate YAML 반복 및 마이크로서비스 간 설정 불일치(Drift)**:
     - *지적*: Platform
     - *내용*: ServiceMonitor, PDB(`maxUnavailable: 1`), SecretStore가 6개 서비스에 100% 동일하게 중복 복사되어 유지보수 부담 가중. 또한 서비스마다 Kustomize 패치 문법(`patchesStrategicMerge` vs `patches` target), 컨테이너 명칭(`app` vs 서비스명), Reloader 어노테이션 유무, Secret 주입 방식이 제각각으로 파편화됨.
  3. **`db-migration` 잡 구조적 아키텍처 위반**:
     - *지적*: Platform, SRE
     - *내용*: Kustomize Base/Overlay 구조를 따르지 않고 Root에 단일 YAML(`db-init-job.yaml`)로 방치되어 있으며, ArgoCD 배포에서 제외되고 특정 서비스(`payment-service-sa`, `payment-service-secret`)에 하드코딩으로 종속되어 도메인 간 결합도를 높임.

## [Area 5] `localy-manifests/platform` 네트워킹 및 모니터링/애드온 영역

* **정찰 수행일**: 2026-07-26
* **타겟 파일 좌표**: `platform/` 폴더 내 11개 플랫폼 애드온 전체 (`cilium`, `external-secrets-operator`, `jaeger`, `karpenter`, `keda`, `keycloak`, `kube-prometheus-stack`, `node-local-dns`, `otel-collector`, `prometheus-adapter`, `reloader`)
* **투입 담당자**: Platform, DevSecOps, SRE, FinOps 전문 에이전트

---

### 🧠 테마 1. [GitOps Root 아키텍처 스플릿 브레인(Split-Brain) 및 고아 매니페스트 방치]
* **개요**: 어떤 Argo App에도 참조되지 않는 데드 코드 방치, `platform/`과 `apps/` 간 심각한 버전 불일치, Kustomize Helm 렌더링 오용.
* **에이전트별 날것의 안건 상세**:
  1. **어떤 ArgoCD Root App에서도 참조되지 않는 고아 매니페스트 방치 (Dead Code)**:
     - *지적*: Platform
     - *내용*: `cilium` (CNI는 IaC 부트스트랩 단계에서 관리되어야 함에도 Kustomize로 시도되다 방치됨), `jaeger` 및 `otel-collector` (렌더링된 정적 덤프 `rendered.yaml`, `agent-render.yaml` 등과 Helm 정의가 뒤섞인 채 방치됨), `prometheus-adapter` (KEDA 도입 후 방치된 고아 코드), 그리고 `platform/kube-prometheus-stack` (ArgoCD가 실제로 띄우는 `apps/kube-prometheus-stack`의 방치된 중복 카피) 등 5개 애드온이 어떤 Root App에서도 참조되지 않고 방치되어 GitOps 혼선 및 매니페스트 비대화 유발.
  2. **`platform/`과 `apps/` 간의 심각한 버전/설정 불일치 (Split-Brain Version Drift)**:
     - *지적*: Platform
     - *내용*: `node-local-dns`는 `platform`에서 v0.1.3 (kubernetes-sigs) vs `apps`에서 v2.8.0 (DeliveryHero)을 사용하며 ConfigMap 덮어쓰기 여부가 다름. `kube-prometheus-stack`은 v58.2.0 vs v70.0.0으로 무려 12개 메이저 버전이 상이함. `karpenter`는 `platform`에서 `localy-prod-eks`를 타겟팅하고 빈 기본값을 쓰지만 `apps`에서는 `prod-eks`와 IRSA 설정을 사용하며, 심지어 `platform`의 오버레이 파일에 EUC-KR/CP949 한글 인코딩 깨짐이 있어 파서 오류 발생.
  3. **Kustomize `--enable-helm` 오용으로 인한 Repo-Server 부하 및 Helm 제어권 상실**:
     - *지적*: Platform
     - *내용*: Helm 차트를 Kustomize로 동적 렌더링하면 ArgoCD repo-server의 네트워크/CPU 부하가 급증하고, K8s에 순수 YAML로 인젝션되어 Helm 릴리스 이력(`helm rollback`, 릴리스 히스토리)을 상실함. 또한 애드온마다 Root 렌더링, Base 렌더링, Overlay 렌더링 방식이 제각각으로 파편화됨.

---

### ☸️ 테마 2. [핵심 플랫폼 컨트롤러 고가용성(HA/PDB) 부재 및 RWO EBS 볼륨 교착 위험]
* **개요**: Keycloak의 잘못된 NodePool 참조로 인한 스케줄링 실패(Pending), RWO 볼륨 탈착 지연으로 인한 단절, 단일 Replica 컨트롤러 위험.
* **에이전트별 날것의 안건 상세**:
  1. **Keycloak의 존재하지 않는 NodePool(`default`) 참조로 인한 영구적 스케줄링 실패 (Pending Deadlock)**:
     - *지적*: FinOps, DevSecOps, SRE (공동 지적)
     - *내용*: 3개 JVM Replica를 설정했으나 `nodeSelector: karpenter.sh/nodepool: default`로 지정됨. 실제 클러스터에는 `platform-pool`과 `workload-pool`만 존재하므로, Keycloak Pod 전체가 배포 즉시 영구적으로 `Pending`(`UNSCHEDULABLE`) 상태에 빠짐. 또한 PDB가 빠져 있고 엄격한 Anti-Affinity를 사용하여 노드 부족 시 복구 불능.
  2. **RWO(ReadWriteOnce) EBS 볼륨 탈부착 지연으로 인한 모니터링/OTel 단절 위험**:
     - *지적*: SRE
     - *내용*: Prometheus(50Gi RWO gp3)와 OTel Gateway(3x 5Gi RWO gp3)가 Pod Disruption Budget(PDB) 없이 단일 Replica 또는 StatefulSet으로 동작함. 노드 드레인이나 업그레이드 시 RWO 볼륨의 AWS Multi-Attach 탈착 지연(최대 6분 이상)으로 인해 Pod이 다른 노드에서 뜨지 못하고 장시간 모니터링/추적 블랙아웃 발생.
  3. **핵심 컨트롤러(`keda`, `eso`, `reloader`, `prometheus-adapter`) 단일 Replica 및 PDB 부재**:
     - *지적*: SRE
     - *내용*: KEDA, External-Secrets, Reloader 등이 HA나 PDB 없이 `replicas: 1`로 동작하며 시스템 노드(`platform-pool`) 바인딩 설정도 빠져 있음. 노드 유지보수 시 K8s Custom Metrics API 단절(오토스케일링 마비), ESO Webhook 장애(Secret 연동 중단), ConfigMap 변경 이벤트 유실 유발.
  4. **`node-local-dns` Corefile 설정 오타로 인한 외부 DNS 전면 블랙아웃 위험**:
     - *지적*: SRE
     - *내용*: `overlays/prod/kustomization.yaml`에서 ConfigMap 패치 시 Corefile 내용 중 `cluster.local:53` 블록만 남기고 외부 포워딩 블록(`.:53`)과 역방향 DNS(`in-addr.arpa`)를 덮어써 버림. 이로 인해 AWS API, RDS, 외부 결제 게이트웨이 등 모든 외부 DNS 조회 시 `REFUSED`/`SERVFAIL`이 반환되어 클러스터 전체 외부 네트워크 마비 유발.

---

### 🛡️ 테마 3. [플랫폼 보안 거버넌스 취약점 및 평문 기밀 정보(Secret) 유출 위험]
* **개요**: Keycloak Git Repo 평문 계정 노출, ESO IAM 인증(`auth`) 누락으로 인한 권한 탈취, 관측성 트래픽 무암호화 및 과권한.
* **에이전트별 날것의 안건 상세**:
  1. **Keycloak Git 저장소 내 평문 계정 하드코딩 및 관리자 과권한 부여**:
     - *지적*: DevSecOps
     - *내용*: `realm-import.json` 파일에 `user-service`의 OIDC Client Secret과 `testuser`의 기본 비밀번호(`password123`)가 평문으로 하드코딩되어 Git 버전에 영구 박제됨. 또한 서비스 계정(`service-account-user-service`)에 Realm 전체의 계정을 제어할 수 있는 과도한 관리자 권한(`manage-users`)이 부여됨.
  2. **External-Secrets(ESO) SecretStore의 IAM 인증(`auth`) 블록 누락 및 권한 탈취**:
     - *지적*: DevSecOps
     - *내용*: `keycloak-store` SecretStore에서 AWS Secrets Manager 연동 시 `auth` 블록을 생략함. 이 경우 ESO Controller의 기본 IAM 역할(`prod-eks-eso-controller-role`)을 그대로 상속받게 되며, 악의적인 테넌트가 임의의 ExternalSecret을 만들어 AWS 계정 내의 모든 Secret을 무차별 조회/탈취할 수 있는 치명적 취약점 발견.
  3. **모니터링/추적 데이터 무암호화(`insecure: true`) 및 OpenSearch 무인증 접근**:
     - *지적*: DevSecOps
     - *내용*: OTel Agent $\rightarrow$ Gateway $\rightarrow$ Jaeger 간 OTLP 트래픽이 무암호화(`tls: insecure: true`)로 전송되어 HTTP 토큰, 세션, SQL 쿼리문이 노드 간 평문 노출됨. 또한 Jaeger의 AWS OpenSearch 연결이 SigV4 인증이나 계정 없이 무인증으로 열려 있어 VPC 내 임의 Pod이 인덱스를 삭제하거나 엿볼 수 있음.
  4. **Grafana 사이드카 및 Prometheus Scrape 권한 무제한(`ALL`) 및 Reloader/KEDA 클러스터 과권한**:
     - *지적*: DevSecOps
     - *내용*: Grafana 사이드카가 전체 네임스페이스(`searchNamespace: ALL`)의 ConfigMap/Secret을 읽을 수 있어 악성 대시보드 인젝션에 취약하며, Prometheus Selector가 nil로 설정되어 전체 네임스페이스를 라벨 필터링 없이 무차별 스크랩함. Reloader와 KEDA 역시 전역 ClusterRole로 동작하여 네임스페이스 간 간섭 및 예기치 못한 클러스터 전체 재시작 위험.
  5. **Cilium CNI 호스트명 플레이스홀더(`API_SERVER_IP`) 미치환 방치**:
     - *지적*: SRE
     - *내용*: `values.yaml`에서 `k8sServiceHost: API_SERVER_IP`가 리터럴 문자열 그대로 방치되어 있어 `kubeProxyReplacement: true` 적용 시 Cilium Agent가 연결에 실패하고 클러스터 네트워크 전체가 다운되는 결함.

---

### 💰 테마 4. [플랫폼 자원 할당 전무(No Requests/Limits) 및 중복 관측성 스택 비용 낭비]
* **개요**: 8개 애드온의 자원 할당 부재, OTel+Jaeger 2중 홉 파이프라인 자원 낭비, KEDA vs Prometheus-Adapter 중복, Karpenter `WhenEmpty` 비효율.
* **에이전트별 날것의 안건 상세**:
  1. **11개 애드온 중 8개의 CPU/Memory 자원 할당(Request/Limit) 전무**:
     - *지적*: FinOps
     - *내용*: `cilium`, `eso`, `karpenter`, `keda`, `node-local-dns`, `prometheus-adapter`, `reloader`, `keycloak` 등 8개 컴포넌트에 자원 할당 설정이 전혀 없음. 특히 Keycloak은 3개 JVM Pod이 Heap/CPU 제한 없이 돌며 Node OOM Kill과 CPU 기아 현상을 일으키고, OTel DaemonSet과 Gateway는 CPU Limit이 없어 트래픽 처리 중 Node 연산 자원을 독점함.
  2. **2중 홉 관측성 파이프라인(`otel` + `jaeger`) 중복 실행으로 인한 CPU/Memory 비용 누수**:
     - *지적*: FinOps
     - *내용*: OTel Gateway(3개 Pod, 3 CPU 예약)에서 직접 OpenSearch로 보내지 않고 Jaeger Collector(2~5개 Pod, 1~2.5 CPU 예약)를 거치는 2중 홉(Double-Hop) 구조를 사용. 추적 수집 파이프라인에만 기본 4~5.5개 이상의 CPU 코어와 4~14GB 메모리를 낭비하며, AZ(가용 영역) 간 크로스 트래픽 전송 비용 및 EBS 볼륨(총 65Gi 이상) 중복 할당 유발.
  3. **KEDA와 Prometheus-Adapter의 기능 중복 및 PromQL API 중복 호출 오버헤드**:
     - *지적*: FinOps
     - *내용*: KEDA 내부에 자체 메트릭 서버(`external.metrics.k8s.io`)와 Prometheus Scaler가 있음에도 동일 기능의 `prometheus-adapter`를 중복으로 설치하여 동시 PromQL 쿼리 및 K8s API 등록 오버헤드 유발.
  4. **Karpenter NodePool `WhenEmpty` 비효율 및 `spec.limits` 부재(AWS 빌 쇼크 위험)**:
     - *지적*: FinOps
     - *내용*: `platform-pool`이 `WhenEmpty` 정책을 사용하여 시스템 DaemonSet이 있는 노드를 최대 14일 동안 절대 축소(Downscale)하지 않고 유휴 비용을 낭비함. 또한 Spot 인스턴스를 금지(`on-demand`만 허용)하고 ARM64 일반 인스턴스(`m6g`, `c6g`)만 쓰도록 하여 가성비 높은 가변 인스턴스(`t4g`)를 원천 차단함. 결정적으로 두 NodePool 모두 클러스터 최대 자원 한계치인 `spec.limits`가 빠져 있어 HPA 오작동이나 트래픽 급증 시 무제한 인스턴스 프로비저닝으로 인한 AWS 요금 폭탄(Bill Shock) 위험 입증.
