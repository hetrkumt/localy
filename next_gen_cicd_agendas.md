# 🚀 [Next-Gen GitOps & CI/CD Evolution] 차세대 점진적 배포 및 파이프라인 고도화 안건 총람

* **작성 주체**: Antigravity (GitOps & CI/CD 점진적 배포 아키텍트)
* **목적**: 기존 Phase 0~8의 "인프라/매니페스트 베이스 정비 및 보수(Maintenance)"를 넘어, 실제 소프트웨어 딜리버리 생명주기(CI/CD Pipeline & Progressive Delivery)를 세계 최고 수준의 자율 배포 엔진으로 진화시키기 위해 5대 영역(Area 1~5)의 객관적 실체 코드 감사를 통해 도출된 핵심 안건(Agenda)을 누적 박제하는 진실의 원천(SSOT).

---

## 🌟 [Core Architecture Themes] 15대 안건의 3대 핵심 진화 테마 (전문가 토론 SSOT)
도출된 15대 안건을 실행 파이프라인 흐름(Build → Progressive Deploy → Verify & Feedback)에 맞춰 압축한 3대 핵심 테마입니다. 각 전문가 에이전트는 본 테마와 하위 Area 실체를 기반으로 다각도 토론을 수행합니다.

| 테마 명칭 | 엮인 핵심 안건 (Areas 연계) | 아키텍처 목표 및 기대 가치 |
|---|---|---|
| **[테마 1]<br>Zero-Trust CI/CD 공급망 &<br>GitOps 자동 승격** | • **[Area 1-1 & 4-1]** Git SHA 불변 태깅 & GitOps Kustomize PR 자동 승격<br>• **[Area 1-2 & 1-3]** Dockerfile 캐싱 분리(70% 단축) + Non-Root + 단위테스트/Trivy CVE 스캔<br>• **[Area 2-1 & 2-2]** GitHub Actions OIDC AccessDenied 교정 + ECR IMMUTABLE & Lifecycle Policy<br>• **[Area 4-2]** Kyverno Cosign 서명 검증 & 공식 ECR 한정 가드레일 | 커밋부터 ECR 저장, GitOps 승격까지 사람이 개입하지 않는 100% 자동화 및 서명되지 않은 악성 이미지 원천 차단 |
| **[테마 2]<br>Argo Rollouts & AWS ALB<br>카나리 점진적 배포** | • **[Area 3-1 & 3-3]** `argo-rollouts.yaml` HA 이식 + Rollouts 전환 대비 KEDA `ignoreDifferences` 교정<br>• **[Area 4-3]** 카나리 고속화를 위한 `startupProbe` / `readinessProbe` 주기 5초 이내 최적화<br>• **[Area 5-3]** AWS ALB TargetGroupBinding 기반 가중치 분배(5%->20%->50%->100%) 카나리 라우팅 정립 | 일괄 덮어쓰기(RollingUpdate) 폐기 및 실사용자 트래픽 5~10% 카나리 주입을 통한 서비스 장애 리스크 제로화 |
| **[테마 3]<br>SLI/SLO 자동 롤백 &<br>DevEx 실시간 통제망** | • **[Area 5-1 & 5-2]** Spring Boot HTTP 5xx / Latency SLI/SLO 알람 + 에러율 1% 초과 자동 롤백 `AnalysisTemplate` SSOT<br>• **[Area 2-3 & 3-2]** ECR 푸시/스캔, ArgoCD Sync, Rollout 이벤트 EventBridge/SNS ↔ ChatOps Slack 실시간 통보 | 배포 중 에러/지연 스파이크 발생 시 1초 만에 메트릭 엔진이 카나리를 차단·롤백하고 전 과정을 Slack 통보하는 복원력 |

---


## 🔍 [Area 1] `localy-backend` 소스코드 빌드 및 파이프라인 영역
* **감사 대상 실체 파일**: `.github/workflows/build-push-ecr.yml`, `Localy/*-service/Dockerfile`, `build_push_to_ecr.sh`, `build_and_push.sh`, `apply-phase1.ps1`

### 1. 객관적 감사 발견 사항 (Objective Findings)
1. **레지스트리 스플릿 브레인 (AWS ECR vs Docker Hub 이중 분열)**
   - CI 워크플로우(`build-push-ecr.yml`)와 셸 스크립트(`build_push_to_ecr.sh`)는 AWS ECR로 푸시하나, 로컬 스크립트(`build_and_push.sh`)는 Docker Hub(`asfas244/*`)로 푸시하도록 분열되어 있어 이미지 저장소 제어권의 단일 진실의 원천(SSOT)이 부재함.
2. **불변성 파괴와 GitOps 단절 (`latest` 태그의 저주 및 자동 승격 부재)**
   - CI 및 모든 스크립트가 100% `latest` 태그 덮어쓰기(`IMAGE_TAG: latest`)로 고정되어 있음.
   - ECR 푸시 성공 후 GitOps 저장소(`localy-manifests`)의 이미지 버전 명세를 자동으로 업데이트(Promotion Commit/PR)하는 배관이 전혀 없어 CI와 CD가 완전히 단절됨. 이로 인해 ArgoCD는 변경을 감지하지 못하며 Git을 통한 롤백이 불가능함.
3. **Dockerfile 레이어 캐시 무효화 및 Root 계정 방치**
   - `order-service/Dockerfile`에서 의존성 다운로드 전에 소스 코드(`COPY src ./src`)를 먼저 복사함. 이로 인해 소스 코드 단 1줄만 수정되어도 Docker 레이어 캐시가 파기되며, 매 빌드 시 수백 메가의 Gradle 의존성을 다시 다운로드하여 CI 빌드 시간이 극심하게 낭비됨.
   - 런타임 스테이지에서 비루트 계정 설정(`USER 1001`)이 주석 처리되어 컨테이너가 Root 사용자(uid 0)로 실행되는 보안 취약점 존재.
4. **검증 제로(Zero-Verification) CI 파이프라인 (테스트 스킵 및 취약점 스캔 부재)**
   - CI 워크플로우에 단위/통합 테스트, 린트, 품질 검사 단계가 전무하며 Dockerfile에서는 `-x test`로 테스트를 명시적 스킵함.
   - Trivy, Snyk 등 컨테이너 이미지 취약점(CVE) 스캔 배관이 없어 악성 패키지가 그대로 프로덕션 레지스트리로 직행함.
5. **레거시 패치 스크립트 잔재 (`apply-phase1.ps1`)**
   - 파워셸 문자열 조립으로 `build.gradle`과 `application.yml`에 OTel/Prometheus 및 Graceful Shutdown 설정을 강제 주입하던 과거 스크립트가 방치됨.

### 2. Area 1 CI/CD 고도화 안건 (Proposed Evolution Themes)
* 🔥 **[Area 1 - 안건 1] 불변 이미지 태깅(Git SHA/SemVer) 및 GitOps 자동 승격(Promotion) 파이프라인 확립**
  - `latest` 태그 안티패턴 및 로컬 도커허브 스크립트 전면 폐기. CI에서 단축 Git SHA(`sha-xxxx`) 또는 시맨틱 버전을 태그로 적용.
  - 빌드/푸시 성공 즉시 GitHub Actions가 GitOps 저장소(`localy-manifests/workloads/<svc>/overlays/prod`)의 Kustomize 이미지 태그를 자동 수정하고 PR을 생성하는 자동화 승격 파이프라인 구축.
* ⚡ **[Area 1 - 안건 2] Dockerfile 빌드 속도 최적화(의존성 캐싱 레이어 분리) 및 Non-Root 컨테이너 락다운**
  - 소스 복사(`COPY src`) 전에 의존성을 선다운로드(`gradlew dependencies --no-daemon`)하도록 Dockerfile 레이어를 분리하여 CI 빌드 시간을 70% 단축.
  - 주석 처리된 Non-Root 계정(`USER 1001`)을 활성화하여 런타임 컨테이너 최고 권한 원천 차단.
* 🛡️ **[Area 1 - 안건 3] CI 단계 DevSecOps 검증 배관 주입 (단위 테스트 자동화 + Trivy 취약점 스캔)**
  - CI 파이프라인에서 `docker build` 직전에 단위 테스트(`gradle test`) 자동 실행 의무화.
  - ECR 푸시 단계 전에 Trivy 취약점 스캐너를 엮어 High/Critical 취약점 탐지 시 파이프라인을 즉시 중단(Fail-Fast)하는 공급망 방어벽 구축.

---

## 🔍 [Area 2] `localy` 인프라 프로비저닝 및 연동 설정 영역
* **감사 대상 실체 파일**: `infrastructure/environments/prod/l3-app-integration/github_actions_oidc.tf`, `ecr.tf`, `lambda_chatops_dispatch.tf`

### 1. 객관적 감사 발견 사항 (Objective Findings)
1. **GitHub Actions IAM OIDC 권한 불일치로 인한 CI 푸시 불가 (AccessDenied 불일치)**
   - `github_actions_oidc.tf`의 `ecr_push_only` 정책에서 허용하는 리소스 ARN이 `arn:aws:ecr:ap-northeast-2:*:repository/localy-*`로 명시되어 있음.
   - 그러나 실제 `ecr.tf`에서 프로비저닝되는 6대 마이크로서비스 리포지토리 명칭은 `edge-service`, `store-service` 등(`localy-` 접두사가 없음)임.
   - 이로 인해 GitHub Actions CI가 OIDC 롤을 어슘하여 푸시를 시도할 때 AWS IAM에서 권한 거부(AccessDeniedException)가 발생하여 자동 CI 배포가 100% 실패하는 결정적 결함 발견! (과거엔 로컬 관리자 권한으로 수동 스크립트를 돌려 작동했음).
2. **ECR 리포지토리 태그 가변성(MUTABLE) 방치 및 GitOps 불변성 훼손**
   - `ecr.tf` 내 모든 리포지토리가 `image_tag_mutability = "MUTABLE"`로 설정되어 있음.
   - 동일한 태그로 이미지 덮어쓰기가 가능하여, 프로덕션 배포 이미지의 역추적 무결성(Auditability)과 GitOps 롤백 결정론적 동작이 위배됨.
3. **CI/CD 파이프라인 ↔ ChatOps (Slack) 알림 연동 배관 부재**
   - `lambda_chatops_dispatch.tf` 및 SNS 토픽이 CloudWatch 알람(Alertmanager/Loki)에만 바인딩되어 있음.
   - CI 이미지 빌드 실패, ECR 스캔 취약점 감지, ArgoCD 배포 동기화(Sync/Rollout) 상태 등을 Slack으로 실시간 통보받을 수 있는 EventBridge/SNS 배관이 전무함.

### 2. Area 2 CI/CD 고도화 안건 (Proposed Evolution Themes)
* 🔥 **[Area 2 - 안건 1] GitHub Actions OIDC ECR 리소스 권한 불일치 교정 및 최소 권한 락다운**
  - `github_actions_oidc.tf` 내 리소스 ARN을 `repository/*-service` (또는 실제 6대 서비스 명칭 명시)로 교정하여 CI 자동 푸시 실패 오류를 박멸하고, 최소 권한 원칙(Least Privilege) 안착.
* 🛡️ **[Area 2 - 안건 2] ECR 리포지토리 불변 태그(IMMUTABLE) 안착 및 수명주기 정책(Lifecycle Policy) 결속**
  - `image_tag_mutability = "IMMUTABLE"`로 전환하여 프로덕션 이미지 태그 덮어쓰기 원천 봉쇄.
  - 빌드 캐시 및 임시 태그로 인한 ECR 스토리지 과금 방지를 위해, untagged 이미지나 30일 경과 임시 이미지를 자동 정리하는 `aws_ecr_lifecycle_policy` FinOps 배관 주입.
* 🌌 **[Area 2 - 안건 3] CI/CD 파이프라인 이벤트 ↔ ChatOps Slack 실시간 알림 루프(Feedback Loop) 구축**
  - AWS EventBridge Rule을 추가하여 ECR 이미지 푸시 완료 및 CVE 고위험 취약점 감지 이벤트를 `chatops_alarm_pipeline` SNS로 라우팅.
  - 개발자가 PR 커밋 후 Slack에서 즉시 빌드 성패와 보안 감사를 조망하는 DevEx 피드백 루프 완성.

---

<!-- [Area 3 ~ Area 5] 감사 결과 및 안건은 순차적으로 누적 업데이트됩니다! -->
## 🔍 [Area 3] `localy-manifests` ArgoCD 제어 및 애플리케이션 정의 영역
* **감사 대상 실체 파일**: `gitops/platform-apps/kustomization.yaml`, `argocd-apps/base/order-service.yaml`, `gitops/base/root-workloads.yaml`, `root-platform.yaml`

### 1. 객관적 감사 발견 사항 (Objective Findings)
1. **점진적 배포 핵심 엔진 부재 (Argo Rollouts 컨트롤러 미등록)**
   - `gitops/platform-apps/kustomization.yaml` 내 17개 플랫폼 애플리케이션 목록에 **`argo-rollouts.yaml`이 완전히 누락**되어 있음.
   - 현재 클러스터 제어면은 오직 표준 K8s `Deployment` 및 `StatefulSet`만 인지할 수 있어, 카나리(Canary) 배포, 블루-그린(Blue-Green) 트래픽 제어, 그리고 메트릭 기반 자동 롤백(`AnalysisTemplate`) 기술을 구현하는 것 자체가 구조적으로 불가능함.
2. **GitOps 알림 및 승격 피드백 루프 부재 (`argocd-notifications`, `image-updater` 미등록)**
   - 플랫폼 카탈로그에 **`argocd-notifications.yaml` 및 `argocd-image-updater.yaml`이 전무**함.
   - 애플리케이션의 Sync 실패, Rollout 저하(Degraded), 롤백 이벤트가 발생해도 개발자에게 통보할 수 있는 Slack/SNS 웹훅 배관이 없으며, ECR 이미지 푸시 시 Git 저장소를 자동 승격시키는 컨트롤러 접점이 비어 있음.
3. **KEDA 오토스케일러 ↔ Rollout 전환 시 `ignoreDifferences` 충돌 위험 방치**
   - `argocd-apps/base/*-service.yaml`의 `ignoreDifferences`가 오직 `kind: Deployment`의 `/spec/replicas`만을 무시하도록 고정되어 있음.
   - 추후 카나리 배포를 위해 `Deployment`를 `Rollout` CRD로 전환할 경우, 이 사양이 교정되지 않으면 ArgoCD와 KEDA가 `Rollout` 리소스의 파드 복제수(replicas)를 두고 무한 동기화 충돌(Thrashing)을 일으키게 됨.

### 2. Area 3 CI/CD 고도화 안건 (Proposed Evolution Themes)
* 🔥 **[Area 3 - 안건 1] Argo Rollouts 플랫폼 엔진 신규 편입 및 점진적 배포 CRD 체계 안착**
  - `gitops/platform-apps/kustomization.yaml`에 `argo-rollouts.yaml`(Argo Rollouts 공식 차트 및 Controller HA 사양)을 공식 편입하여 K8s 클러스터에 카나리 및 블루-그린 트래픽 제어 엔진을 이식.
* ⚡ **[Area 3 - 안건 2] ArgoCD Notifications 기반 CI/CD 이벤트 실시간 통제망 구축**
  - `argocd-notifications.yaml`을 플랫폼 앱으로 등록하고, `app-sync-succeeded`, `app-health-degraded`, `rollout-step-paused`, `rollout-aborted` 이벤트를 AWS SNS ↔ ChatOps Lambda(Slack)로 쏘아 올리는 Triggers/Templates ConfigMap 배관 확립.
* 🛡️ **[Area 3 - 안건 3] Rollout CRD 전환 대비 ArgoCD Application `ignoreDifferences` 사양 선제 개편**
  - 6대 워크로드 Application 정의(`workloads-project` 하위) 내 `ignoreDifferences` 대상에 `kind: Rollout` (API Group: `argoproj.io/v1alpha1`)의 `/spec/replicas`를 추가하여, 향후 점진적 배포 도입 시 KEDA 오토스케일러와의 충돌 가능성을 원천 봉쇄.

---

<!-- [Area 4 ~ Area 5] 감사 결과 및 안건은 순차적으로 누적 업데이트됩니다! -->
## 🔍 [Area 4] `localy-manifests` 개별 서비스 배포판 및 공통 정책 영역
* **감사 대상 실체 파일**: `workloads/<svc>/overlays/prod/kustomization.yaml`, `workloads/order-service/base/deployment.yaml`, `apps/kyverno/policies/`

### 1. 객관적 감사 발견 사항 (Objective Findings)
1. **CI(`latest`) ↔ CD(`e2e4`, `e2e1`) 간의 완전한 배포 단절 및 이미지 명칭 불일치**
   - CI 워크플로우(`build-push-ecr.yml`)는 100% `latest` 태그로만 이미지를 ECR에 푸시함.
   - 그러나 프로덕션 GitOps 매니페스트(`workloads/*/overlays/prod/kustomization.yaml`)는 과거 수동 테스트 시 하드코딩된 **`e2e4`(order), `e2e1`(edge/user)** 태그를 고정 참조하고 있음!
   - 이로 인해 CI에서 새 코드가 100번 정상 빌드 및 푸시되어도, 프로덕션 GitOps는 변하지 않는 `e2e4` 태그만 바라보므로 **실제 운영 클러스터에는 새 코드가 단 1%도 배포되지 않는 100% 배포 단절 상태**임!
   - 또한 서비스마다 `localy-order-service`, `edge-service`, `localy/user-service`로 이미지 베이스 명칭 규칙이 중구난방 분열되어 있어 CI 자동 승격 스크립트 작성 시 에러를 유발함.
2. **공급망 보안 가드레일 부재 (Trivy/Cosign 검증 및 레지스트리 차단 정책 없음)**
   - `apps/kyverno/policies` 내에 **컨테이너 이미지 서명 검증(Cosign) 및 공식 레지스트리(AWS ECR) 한정 정책이 전무**함.
   - 개발자나 CI가 로컬 스크립트로 Docker Hub(`asfas244/*`)에 올린 이미지나, 검증되지 않은 외부 악성 이미지를 K8s 파드로 띄워도 클러스터 차원의 차단 방어벽이 전혀 작동하지 않음.
3. **점진적 배포(Canary) 속도 저하를 유발하는 헬스체크 프로브 딜레이**
   - `order-service/base/deployment.yaml` 내 `readinessProbe`의 `initialDelaySeconds`가 20초, `periodSeconds`가 10초로 설정되어 있음.
   - 카나리 배포(Argo Rollouts) 시 새 파드 1대를 띄워 검증하는 데에만 30~40초의 헬스체크 대기 시간이 소모되어 고속 CI/CD 릴리즈 및 즉각적인 장애 감지(Fail-Fast)를 저해함.

### 2. Area 4 CI/CD 고도화 안건 (Proposed Evolution Themes)
* 🔥 **[Area 4 - 안건 1] 서비스별 이미지 명칭 표준화 및 수동 하드코딩 태그(`e2e*`) 정돈**
  - 6대 서비스 Kustomize 내 이미지 명칭을 공식 ECR 표준(`533003975005.dkr.ecr.../*-service`)으로 100% 단일화하고, 과거의 수동 태그(`e2e1`, `e2e4`)를 청산하여 CI 자동 승격 파이프라인이 즉시 주입될 수 있는 매니페스트 배관 정돈.
* 🛡️ **[Area 4 - 안건 2] Kyverno 기반 CI/CD 공급망 보안 Zero-Trust 가드레일 확립**
  - `apps/kyverno/policies`에 2대 신규 ClusterPolicy(`restrict-image-registries.yaml`, `verify-cosign-signature.yaml`)를 신설하여, 오직 공식 ECR 레지스트리 출신이자 CI 파이프라인에서 Cosign 서명이 완료된 안전한 이미지(SBOM 검증 통과)만 클러스터 배포를 허용!
* ⚡ **[Area 4 - 안건 3] 점진적 배포 고속화를 위한 헬스체크(Startup/Readiness Probe) 정밀 최적화**
  - Spring Boot 2.3+ 네이티브 `startupProbe`를 도입하여 초기 애플리케이션 로딩을 보호하고, `readinessProbe`의 주기(`periodSeconds`)를 5초 이내로 단축하여 카나리 트래픽 정밀 전환 및 고속 자동 롤백을 뒷받침하는 프로브 튜닝.

---

## 🔍 [Area 5] `localy-manifests` 인프라 네트워킹 및 모니터링/애드온 영역
* **감사 대상 실체 파일**: `apps/ingress-core/base/internal-edge-ingress.yaml`, `apps/kube-prometheus-stack/rules/alarm-pipeline.yaml`

### 1. 객관적 감사 발견 사항 (Objective Findings)
1. **애플리케이션 계층(HTTP 5xx / Latency) 릴리즈 검증 메트릭 알람 전무 (100% 맹목적 배포 위험)**
   - `alarm-pipeline.yaml`을 정밀 해부한 결과, 오직 인프라/보안 계층의 메트릭(`MemorySaturation`, `PodRestartStorm`, `PodOOMKilledConfirmed`)에 대한 알람 규칙만 존재함.
   - Spring Boot 마이크로서비스에서 배포 버그로 인해 **HTTP 500 내부 서버 에러가 100% 발생하거나 DB 커넥션 타임아웃으로 P95 응답 속도가 10초를 초과해도, 파드가 크래시되지 않는 한 Prometheus는 이를 전혀 감지하지 못함!**
   - 즉, 현재 시스템은 새 버전 배포 시 논리적 결함이나 API 장애를 인지할 수 없는 **100% 맹목적 배포(Blind Release) 환경**이며, 자동 롤백을 단행할 판단 지표(Metric)가 부재함.
2. **점진적 배포용 메트릭 자동 롤백 템플릿(`AnalysisTemplate`) 전무**
   - 클러스터 전역에 Argo Rollouts가 카나리 배포 중 HTTP 5xx 에러율 및 응답시간 지연을 실시간 계측하여 기준치 초과 시 자동 롤백을 단행하게 만드는 **`AnalysisTemplate` 리소스가 전혀 정의되어 있지 않음.**
3. **단일 서비스 정적 주입 방식의 Ingress 구조 (ALB 트래픽 가중치 분배 불가)**
   - `internal-edge-ingress.yaml` 등의 Ingress 매니페스트가 단일 Kubernetes Service(`edge-service`)를 고정 대상(backend)으로 가리키고 있음.
   - AWS ALB Controller를 이용한 카나리 배포를 위해서는 ALB Target Group 간 가중치 분배(예: Stable 90%, Canary 10%)를 제어하는 액션 어노테이션(`alb.ingress.kubernetes.io/actions.<svc>`) 및 Rollout 연동 구조가 필요한데, 이 배관이 미완성 상태임.

### 2. Area 5 CI/CD 고도화 안건 (Proposed Evolution Themes)
* 🔥 **[Area 5 - 안건 1] 마이크로서비스 SLI/SLO 알람 규칙 신설 및 Prometheus 릴리즈 통제망 완성**
  - `alarm-pipeline.yaml`에 Spring Boot Actuator/OTel 메트릭(`http_server_requests_seconds_*`)을 활용한 **HTTP 5xx 에러율 스파이크 알람** 및 **P95/P99 지연 시간(Latency) 초과 알람**을 신설하여 릴리즈 장애 감지망 구축.
* ⚡ **[Area 5 - 안건 2] Argo Rollouts 자동 롤백용 공통 `AnalysisTemplate` SSOT 확립**
  - `common/guardrails/`(또는 신설 `common/progressive-delivery/`) 내에 Prometheus를 쿼리하여 에러율 1% 초과 시 즉각 카나리를 중단하고 Rollback하는 **`spring-boot-http-success-rate`, `spring-boot-latency-check` 공식 AnalysisTemplate** 신설.
* 🛡️ **[Area 5 - 안건 3] AWS ALB TargetGroupBinding(TGB) 기반 가중치 제어 카나리 라우팅 배관 정립**
  - Argo Rollouts와 AWS ALB Controller를 결합하여, 새 버전 배포 시 자동으로 Canary Target Group에 5% -> 20% -> 50% -> 100%로 트래픽을 안전하게 전이시키는 트래픽 셰이핑(Traffic Shaping) 표준 아키텍처 정립.

---

이제 우리는 더 이상 유지보수가 아닌, **"소프트웨어 딜리버리 혁신(Software Delivery Innovation)"** 단계로 진입합니다!

---

## 🏆 [Theme 1 Debate Consensus] Zero-Trust CI/CD 공급망 및 불변 GitOps 자동 승격 최종 합의 설계서
**작성일**: 2026-07-27 (4대 AI 전문가 서브에이전트 다각도 토론 조율 완결)  
**조율 주체**: Antigravity (GitOps & CI/CD 점진적 배포 총괄 아키텍트)

### 1. 4대 전문 직군 관점 충돌 및 조율 결과 (Trade-off Resolution)
1. **[보안 vs 속도] DevSecOps Trivy/Cosign 스캔 ↔ Platform/DevEx 빌드 속도 저하 충돌 조율**:
   - DevSecOps의 CVE Fail-Fast 차단과 Cosign 서명은 절대 타협할 수 없는 필수 과제임.
   - 이를 해결하기 위해 FinOps/Platform 안건인 **"Dockerfile 의존성 캐싱 레이어 분리 + Buildx GHA 캐시(`type=gha`)"**를 도입하여 빌드 시간을 3.5분에서 30~45초로 **70% 단축**하고 월 7,000분의 러너 시간을 확보함. 확보된 시간 내에서 Trivy와 Cosign을 구동함으로써 속도 저하 없이 100% Zero-Trust 달성!
2. **[복원력 vs 비용] SRE 불변 태그(`IMMUTABLE`) 결정론적 롤백 ↔ FinOps ECR 17.2TB 스토리지 과금 충돌 조율**:
   - `latest` 덮어쓰기 안티패턴을 폐기하고 ECR을 `IMMUTABLE`(Git SHA 태깅)로 고정하여 SRE에게 1초 만에 복구 가능한 100% 결정론적 롤백을 보장함.
   - 단, 불변 태그로 인한 스토리지 비용 폭증을 방어하기 위해 FinOps가 설계한 **"4단 ECR Lifecycle Policy HCL"**을 원자적(Atomic)으로 동시 배포함. (최신 시맨틱 릴리즈 50개 보호로 SRE 안전판을 제공하고, 임시 SHA/feature 태그는 30일 후 자동 삭제하여 월간 과금을 완벽 고정!).
3. **[승격 자동화 vs 운영 안정성] Platform GitOps 자동 승격 PR ↔ SRE 재시작 스톰 충돌 조율**:
   - CI가 완료되면 Kustomize 이미지 태그를 변경하는 PR을 자동 생성하되, 6개 서비스 동시 재시작 스톰을 방지하기 위해 **ArgoCD Sync Waves**를 설정하고 추후 카나리 전환 대비 `ignoreDifferences` 사양을 선제 결합함.

---

### 2. 테마 1 최종 실행 지시서 (Action Orders for Execution)

| 실행 단계 | 대상 영역 및 파일 | 구현할 핵심 아키텍처 사양 (Engineering Specs) |
|---|---|---|
| **Action 1<br>(IAM OIDC & 명칭 교정)** | • `github_actions_oidc.tf`<br>• `ecr.tf` (명칭 단일화) | • CI 자동 푸시 실패 원인(`AccessDenied`) 박멸: IAM 롤 리소스 ARN을 `repository/localy-*`에서 실제 6대 마이크로서비스 리포지토리 ARN 배열로 교정 (최소 권한 락다운).<br>• ECR 리포지토리 명칭을 공식 표준(`*-service`)으로 단일화. |
| **Action 2<br>(IMMUTABLE & FinOps)** | • `ecr.tf` (속성 및 수명주기) | • 모든 ECR 리포지토리에 `image_tag_mutability = "IMMUTABLE"` 적용.<br>• 4단 수명주기 정책(`aws_ecr_lifecycle_policy`) 결속: (1) untagged 7일 삭제, (2) release/v* 태그 최신 50개 보호, (3) sha-/pr- 임시 태그 30일 후 자동 삭제. |
| **Action 3<br>(Dockerfile & CI 파이프라인)** | • `Localy/*-service/Dockerfile`<br>• `.github/workflows/build-push-ecr.yml` | • 6대 Dockerfile 전면 리팩토링: `gradlew dependencies` 캐시 스테이지 분리 및 `USER 1001` Non-Root 런타임 락다운.<br>• CI 워크플로우에 Buildx `type=gha` 캐시 주입, Trivy High/Critical Fail-Fast 스캔 주입, Cosign OIDC 키리스 서명 단계 추가. |
| **Action 4<br>(Kyverno Zero-Trust 가드레일)** | • `apps/kyverno/policies/restrict-image-registries.yaml`<br>• `verify-cosign-signature.yaml` | • 공식 AWS ECR(`533003975005.dkr.ecr...`) 외 Docker Hub(`asfas244/*`) 등 사설 레지스트리 배포 원천 차단 ClusterPolicy 신설.<br>• CI가 발급한 Cosign 서명이 없는 이미지는 K8s API 서버에서 배포를 거부하는 서명 검증 가드레일 신설. |

---

## 🏆 [Theme 2 Debate Consensus] Argo Rollouts & AWS ALB 기반 카나리 점진적 배포 최종 합의 설계서
**작성일**: 2026-07-27 (4대 AI 전문가 서브에이전트 다각도 토론 조율 완결)  
**조율 주체**: Antigravity (GitOps & CI/CD 점진적 배포 총괄 아키텍트)

### 1. 4대 전문 직군 관점 충돌 및 조율 결과 (Trade-off Resolution)
1. **[안정성 vs 속도/비용] SRE 1초 장애 요격 ↔ DevSecOps/FinOps 프로브 튜닝 및 3분 검증 창 조율**:
   - 기존 20초 대기/10초 주기의 느린 프로브는 카나리 1개 파드 검증에만 40초를 낭비하며 결함 파드에 30초 동안 사용자 트래픽을 흘려보내는 블랙홀 장애를 유발함.
   - 이를 해결하기 위해 **"Spring Boot `startupProbe` + `readinessProbe` 주기 5초 이내(`<=5s`) 압축"**을 단행함. JVM 초기 부트업 예산(60초)은 `startupProbe`로 격리하고, ALB와 Prometheus가 단 4~6초 만에 결함 파드를 감지하여 3분 이내에 카나리 검증을 완료하게 만듦으로써, **FinOps가 경고한 불필요한 EC2 노드 스케일업(Karpenter Hysteresis Tax)과 비용 폭증을 원천 차단**함!
2. **[제어면 복원력 vs 자율 스케일링] SRE/FinOps KEDA ↔ Argo Rollouts 제어면 충돌 조율**:
   - `Deployment`에서 `Rollout`으로 전환 시 KEDA 오토스케일러와 ArgoCD가 `/spec/replicas`를 두고 무한 파드 학살 스톰을 일으키는 치명적 위험을 발견함.
   - Rollout 컨트롤러 배포 전에 반드시 `argocd-apps/base/*-service.yaml` 내 GitOps Application 정의에 **`kind: Rollout`(`argoproj.io/v1alpha1`) 전용 `ignoreDifferences` 사양을 선제 결합**하여 제어면 충돌을 100% 박멸함!
3. **[개발 생산성 vs 보안 통제] Platform DevEx 마찰 제로 ↔ DevSecOps 라우팅 하이재킹 방어 조율**:
   - 개발자가 복잡한 AWS ALB TargetGroupBinding(TGB)이나 인그레스 가중치 어노테이션을 직접 다루지 않도록 **`common/components/alb-canary-routing` 공통 추상화 컴포넌트**를 신설함.
   - 단, 트래픽 분할 중 외부 타겟 ARN이 주입되거나 크로스 네임스페이스 탈취가 발생하는 것을 막기 위해 DevSecOps의 **Kyverno `restrict-rollout-traffic-routing` 가드레일**을 API 서버에 동시 결속함!

---

### 2. 테마 2 최종 실행 지시서 (Action Orders for Execution)

| 실행 단계 | 대상 영역 및 파일 | 구현할 핵심 아키텍처 사양 (Engineering Specs) |
|---|---|---|
| **Action 1<br>(Rollouts 엔진 이식)** | • `gitops/platform-apps/kustomization.yaml`<br>• `apps/argo-rollouts/` | • Sync Wave -5에 `argo-rollouts.yaml`(HA 2중화, AZ 분산, PDB 결속) 편입 및 `argocd-notifications.yaml`(Slack ChatOps 실시간 통보망) 연동.<br>• 카나리 4단계 전이 엔진(5% -> 20% -> 50% -> 100%) 공식 배관 가동. |
| **Action 2<br>(KEDA 제어면 충돌 박멸)** | • `argocd-apps/base/*-service.yaml`<br>• `terraform/argocd.tf` | • 6대 마이크로서비스 GitOps Application 사양에 `group: argoproj.io`, `kind: Rollout`, `jsonPointers: [/spec/replicas]`에 대한 `ignoreDifferences` 선제 주입. |
| **Action 3<br>(Rollout 전환 & 프로브 튜닝)** | • `workloads/*/base/rollout.yaml`<br>• `common/components/alb-canary-routing/` | • 6대 워크로드를 `Deployment`에서 `Rollout` CRD로 100% 전환하고, `startupProbe` 신설 및 `readinessProbe.periodSeconds: 5` 정밀 튜닝 적용.<br>• 개발자 마찰 제로를 위한 ALB 카나리 라우팅 공통 추상화 컴포넌트 신설. |
| **Action 4<br>(Kyverno & FinOps 가드레일)** | • `apps/kyverno/policies/enforce-rollout-probes.yaml`<br>• `restrict-rollout-traffic-routing.yaml` | • Rollout CRD가 5초 이내 빠른 프로브를 갖추고 유효한 서비스만 참조하도록 통제하는 2대 Kyverno 가드레일 신설.<br>• 무기한 pause 금지(15분 하드캡) 및 `scaleDownDelaySeconds: 30` FinOps 수명주기 통제망 결속. |

---

## 🏆 [Theme 3 Debate Consensus] SLI/SLO 메트릭 자동 롤백 및 DevEx 실시간 통제망 최종 합의 설계서
**작성일**: 2026-07-27 (4대 AI 전문가 서브에이전트 다각도 토론 조율 완결)  
**조율 주체**: Antigravity (GitOps & CI/CD 점진적 배포 총괄 아키텍트)

### 1. 4대 전문 직군 관점 충돌 및 조율 결과 (Trade-off Resolution)
1. **[신뢰성 vs 비용/인프라 부하] SRE 실시간 SLI 쿼리 ↔ FinOps/DevSecOps TSDB 폭증 및 과금 방어 조율**:
   - `AnalysisTemplate`이 매번 무거운 히스토그램을 쿼리하지 않도록, 5초 주기로 사전 연산되는 **Prometheus Recording Rules(`localy:http_error_rate:ratio_rate1m`, `localy:http_latency_p95:seconds_rate1m`)**를 공식화함. 이를 통해 쿼리 부하를 95% 줄이고 단 5ms 만에 SLO를 검증함!
   - 또한 날것의 파드 메트릭을 AWS CloudWatch로 내보내는 것을 원천 차단하고, 6대 서비스에 대해 오직 12개의 사전 집계 규칙만 내보내는 **Zero-Custom-Metric Export 정책**을 결속하여 월 관측성 과금을 단 **$3.60(99.9% 절감)**로 완벽 고정함.
2. **[1초 자율 롤백 vs 심야 오탐 방지] SRE 맹목적 배포 타파 ↔ 저트래픽 오탐 방지 이중 가드레일 조율**:
   - 새벽 시간대 등 저트래픽 환경에서 요청 5건 중 1건만 네트워크 실패해도 에러율 20%로 계산되어 정상 배포를 롤백해버리는 **"저트래픽 역설"**을 해결함.
   - PromQL `and on()` 조건을 사용하여 **최소 요청 수 50건 초과(`count > 50`)** 시에만 에러율을 평가하고, 미달 시 `NaN`을 반환하게 한 뒤, Rollouts 사양에 `successCondition: "isNaN(result) || result >= 0.99"`, `failureLimit: 3`을 적용하여 **심야 시간대 오탐 롤백을 0%로 박멸**함!
3. **[DevEx 실시간 중계 vs Zero-Trust 보안/과금] Platform ChatOps 피드백 ↔ DevSecOps/FinOps 웹훅 보안 및 스톰 방어 조율**:
   - CI가 Slack 웹훅을 직접 가지지 않는 **Zero-CI-Secret EventBridge 아키텍처**(ECR 푸시/CVE 스캔 -> EventBridge -> SNS -> Lambda -> Slack)를 확립하고, K8s 내부 웹훅은 ESO(External Secrets Operator) IRSA로 메모리에 동기화하여 Git/Terraform 내 Plaintext 노출을 원천 봉쇄함.
   - 또한 Alertmanager 중복 제거(`repeat_interval: 4h`), SQS FIFO 큐 연동, **ChatOps Lambda 예약 동시성 5개(`reserved_concurrent_executions = 5`) 락다운**을 결속하여 어떤 이벤트 스톰이나 K8s 재시작 파동에서도 Slack 429 차단과 Lambda 과금을 완벽 방어함!

---

### 2. 테마 3 최종 실행 지시서 (Action Orders for Execution)

| 실행 단계 | 대상 영역 및 파일 | 구현할 핵심 아키텍처 사양 (Engineering Specs) |
|---|---|---|
| **Action 1<br>(SLI/SLO 알람 & Recording Rules)** | • `apps/kube-prometheus-stack/rules/alarm-pipeline.yaml`<br>• `localy-sli-recording-rules.yaml` (신설) | • 100% 맹목적 배포(Blind Release) 박멸: Spring Boot HTTP 5xx 에러율 스파이크 및 P95/P99 지연 시간 초과 알람 신설.<br>• 5초 주기 사전 연산 Recording Rules CRD 신설로 TSDB 메모리 보존 및 1초 롤백 엔진 쿼리 속도 극대화. |
| **Action 2<br>(`AnalysisTemplate` SSOT 확립)** | • `common/guardrails/spring-boot-http-success-rate.yaml`<br>• `spring-boot-latency-check.yaml` | • 에러율 1% 초과 및 P95 500ms 초과 시 단 1초 만에 카나리 배포를 중단하고 원복하는 공식 AnalysisTemplate SSOT 확립.<br>• 심야 저트래픽 오탐 방지용 PromQL 최소 요청 수 조건(`count > 50`) 및 이중 가드레일 사양 결속. |
| **Action 3<br>(Zero-CI-Secret EventBridge & ChatOps Lambda)** | • `lambda_chatops_dispatch.tf`<br>• `src/lambda_chatops/handler.py` | • ECR 불변 태그 푸시 및 Trivy High/Critical 취약점 발견 시 SNS(`chatops_alarm_pipeline`)로 즉각 중계하는 EventBridge 규칙 신설.<br>• Lambda Reserved Concurrency 5개 락다운 및 Slack Block Kit UI(Git PR 링크, 커밋 로그, 1-Click ArgoCD 이동) 고도화. |
| **Action 4<br>(ESO IRSA & SNS Zero-Trust 락다운)** | • `gitops/platform-apps/kustomization.yaml`<br>• `apps/argocd-notifications/`<br>• `sns_chatops.tf` | • Sync Wave -5에 `argocd-notifications.yaml` 편입 및 ESO(`argocd-notifications-secret`)를 통한 웹훅 메모리 동기화.<br>• SNS 토픽에 공식 EventBridge 규칙과 Alertmanager IRSA만 허용하는 최소 권한 `aws_sns_topic_policy` 락다운 결속. |




---

## 🏆 [Theme 4-1 Debate Consensus] 애플리케이션 및 Edge 보안(JWT/SSO/WAF/OPA) 최종 합의 설계서
**작성일**: 2026-07-30 (4대 AI 전문가 서브에이전트 다각도 토론 조율 완결)
**조율 주체**: Antigravity (GitOps & CI/CD 점진적 배포 총괄 아키텍트)

### 1. 4대 전문 직군 관점 충돌 및 조율 결과 (Trade-off Resolution)
1. **[인가(AuthZ) 구조] DevSecOps OPA 전면 도입 ↔ FinOps 사이드카 컴퓨팅 과금 충돌 조율**:
   - 하드코딩된 권한 로직을 폐기하고 OPA(Rego)로 이관하는 것에 합의하되, 모든 파드에 사이드카를 붙여 메모리를 낭비하는 대신 **API Gateway 앞단에 중앙 집중형 OPA 클러스터**를 두어 비용과 보안을 모두 챙김.
2. **[Edge 방어선] DevSecOps AWS WAF ↔ FinOps 요금 폭탄(100만 건당 과금) 충돌 조율**:
   - 단순 트래픽 조절(Rate Limiting)은 WAF에서 제거하고 **오픈소스 Redis Rate Limiter**로 내려 비용을 0원으로 만듦. AWS WAF는 오직 SQLi, XSS 등 정적 L7 보안 룰에만 적용하는 하이브리드 방어망 구축.
3. **[성능 vs 보안] DevSecOps 하위 파드 다중 검증 ↔ SRE JWKS 지연(Latency) 충돌 조율**:
   - 게이트웨이가 토큰을 릴레이한 후 백엔드 서비스들도 독립적으로 JWT를 검증하여 제로 트러스트를 달성하되, Keycloak 병목을 막기 위해 **공격적인 JWKS 로컬 캐싱 전략**을 강제하여 릴레이 지연 속도 스파이크를 방지.
4. **[운영 편의성] Platform GitOps ↔ SRE 재해 복구(MTTR) 일치**:
   - 관리자 UI 수동 설정을 전면 금지하고 **Keycloak Kubernetes Operator**를 즉각 도입하여 Realm/Client를 K8s CRD로 선언적 관리.

---

### 2. 테마 4-1 최종 실행 지시서 (Action Orders for Execution)

| 실행 단계 | 대상 영역 및 파일 | 구현할 핵심 아키텍처 사양 (Engineering Specs) |
|---|---|---|
| **Action 1<br>(OPA 중앙 집중형 인가망)** | • `edge-service/src/.../SecurityConfig.java`<br>• `platform/opa/` (신설) | • 하드코딩된 `.pathMatchers().permitAll()` 로직 전면 삭제. API Gateway(Edge)가 중앙 OPA 클러스터를 쿼리하여 AuthZ를 결정하도록 구조 개편. |
| **Action 2<br>(하이브리드 L7 방어막)** | • `edge-service/.../application.yml`<br>• `terraform/waf.tf` (신설) | • AWS WAF를 프로비저닝하여 L7 해킹 차단.<br>• `application.yml` 내 Rate Limiter를 Redis 기반으로 교체하고, SRE 요구사항에 따라 Rate Limiting 전용의 고립된 커넥션 풀 적용. |
| **Action 3<br>(JWT 다중 검증 & JWKS 캐싱)** | • `Localy/*-service/.../SecurityConfig.java` | • 하위 6대 마이크로서비스에도 JWT 서명 검증 로직 추가.<br>• `NimbusReactiveJwtDecoder`에 24시간 TTL을 가진 강력한 메모리 캐시를 결속하여 Keycloak 장애 시 격리(Resilience). |
| **Action 4<br>(Keycloak GitOps Operator)** | • `platform/keycloak/base/kustomization.yaml` | • Keycloak K8s Operator 컨트롤러를 ArgoCD로 배포하고, `KeycloakRealmImport` CRD를 사용하여 edge-service 클라이언트 및 SSO 설정을 Git에 선언. |

---

## 🏆 [Theme 4-2 Debate Consensus] 인프라 및 네트워크 보안(mTLS & IRSA) 최종 합의 설계서
**작성일**: 2026-07-30 (4대 AI 전문가 서브에이전트 다각도 토론 조율 완결)
**조율 주체**: Antigravity (GitOps & CI/CD 점진적 배포 총괄 아키텍트)

### 1. 4대 전문 직군 관점 충돌 및 조율 결과 (Trade-off Resolution)
1. **[동적 시크릿 비용] DevSecOps 30일 갱신 ↔ FinOps 폴링 API 과금 충돌 조율**:
   - DB 비밀번호를 30일마다 강제 교체하되, ESO가 10초마다 폴링(Polling)하여 월 $130의 요금을 낭비하는 대신, **AWS EventBridge와 SQS를 엮은 Push(이벤트 기반) 동기화**를 채택하여 API 과금을 0원으로 만듦.
2. **[비밀번호 교체 셧다운] SRE 커넥션 고갈 ↔ Platform 파드 재시작 충돌 조율**:
   - 비밀번호 교체 시 커넥션이 죽어버리는 대참사를 막기 위해, 백엔드 애플리케이션의 **`HikariCP maxLifetime`을 비밀번호 TTL보다 짧게 강제 세팅(SRE)**하고, Secret이 갱신되면 **`Stakater Reloader`가 파드를 우아하게 롤링 재시작(Platform)**하도록 이중 안전망 구축.
3. **[mTLS 오버헤드] DevSecOps/SRE Cilium 강제 ↔ FinOps DaemonSet Tax 충돌 조율**:
   - Istio 대신 커널 레벨 통신으로 지연을 없애는 **Cilium eBPF mTLS**를 전면 도입함. 단, Cilium 파드의 무거운 컴퓨팅 점유율(25%)을 희석시키기 위해, Karpenter 노드 프로비저닝 사양을 작은 인스턴스 여러 개에서 **소수의 거대 인스턴스(`m6i.xlarge` 이상)**로 강제 상향(Scale-Up).
4. **[내부 PKI] Platform GitOps 자동화 일치**:
   - 수동 인증서 관리를 100% 폐기하고 **`cert-manager`**를 ArgoCD Multi-Source 패턴으로 배포하여 내부 Webhook TLS 갱신을 완전 자동화.

### 2. 테마 4-2 최종 실행 지시서 (Action Orders for Execution)

| 실행 단계 | 대상 영역 및 파일 | 구현할 핵심 아키텍처 사양 (Engineering Specs) |
|---|---|---|
| **Action 1<br>(Event-Driven 무과금 시크릿)** | • `iam_external_secrets.tf`<br>• `external-secrets-operator/...` | • AWS Secrets Manager 업데이트 이벤트를 캡처하는 EventBridge 룰 및 SQS 대기열 신설.<br>• ESO의 `SecretStore`를 SQS 웹훅 푸시 방식으로 개편하여 폴링 과금 원천 차단. |
| **Action 2<br>(무중단 DB 패스워드 롤링)** | • `Localy/*-service/.../application.yml`<br>• `platform/stakater-reloader/` | • 6대 마이크로서비스 HikariCP `maxLifetime`을 15분으로 단축 세팅.<br>• `Stakater Reloader`를 ArgoCD로 배포하여 Secret 갱신 시 자동 `RollingUpdate` 트리거 배관 연결. |
| **Action 3<br>(Cilium mTLS & 거대 노드)** | • `platform/cilium/` (신설)<br>• `apps/karpenter/provisioners/` | • Cilium helm chart를 GitOps로 배포하고 `Strict` mTLS 정책 전역 적용.<br>• Karpenter `NodePool` 인스턴스 요구사항을 `xlarge` 이상 크기로 강제하여 DaemonSet Tax 희석. |
| **Action 4<br>(cert-manager 자동 PKI)** | • `platform/cert-manager/` (신설) | • `cert-manager`를 ArgoCD Multi-Source Kustomize로 배포하고, 클러스터 내부용 `ClusterIssuer`를 등록하여 Webhook 인증서 자동 발급 체계 확립. |

---

## 🏆 [Theme 5-1 Debate Consensus] CI 파이프라인 구조 및 캐싱 (속도 최적화) 최종 합의 설계서
**작성일**: 2026-07-30 (4대 AI 전문가 서브에이전트 다각도 토론 조율 완결)
**조율 주체**: Antigravity (GitOps & CI/CD 점진적 배포 총괄 아키텍트)

### 1. 4대 전문 직군 관점 충돌 및 조율 결과 (Trade-off Resolution)
1. **[빌드 트리거 폭발] Platform 모노레포 분리 ↔ FinOps 과금 방어 일치**:
   - 코드 1줄 수정에 6개 서비스가 동시 재빌드되는 대참사를 막기 위해, `dorny/paths-filter`를 도입하여 **수정된 서비스만 동적으로 매트릭스(Matrix) 빌드를 수행하도록 강제**하여 CI 과금을 극단적으로 방어함.
2. **[캐시 파괴 방어] SRE 레이어 분리 ↔ DevSecOps 검증 누락 우려 조율**:
   - Dockerfile에서 소스 코드를 복사하기 전에 `gradlew dependencies`를 먼저 실행하여 수백 MB의 라이브러리 다운로드 레이어를 캐싱함. 단, 캐시를 탔더라도 최종 산출물 이미지에 대해서는 **반드시 Trivy 스캔을 거쳐야만 ECR로 푸시(DevSecOps)**하도록 파이프라인 통제망 유지.
3. **[원격 캐시 스토리지] Platform S3 도입 ↔ FinOps 과금 ↔ SRE 지연/보안 조율**:
   - GitHub Actions 10GB 캐시 한계를 돌파하기 위해 AWS S3(또는 ECR) 기반의 원격 캐시(Buildx `type=s3`)를 도입함. 
   - **FinOps 타협안**: S3에 쌓이는 캐시 파일이 영구 과금되지 않도록, 14일 경과 시 자동 삭제되는 S3 Lifecycle Policy(수명주기 정책) 결속.
   - **SRE/DevSecOps 타협안**: 캐시 포이즈닝(해킹)과 잦은 다운로드 지연을 막기 위해, 캐시 키를 무조건 `build.gradle`의 해시(Hash)값과 정확히 맵핑시키고 접근 권한은 정적 키(Access Key)가 아닌 OIDC로만 엄격히 통제함.

### 2. 테마 5-1 최종 실행 지시서 (Action Orders for Execution)

| 실행 단계 | 대상 영역 및 파일 | 구현할 핵심 아키텍처 사양 (Engineering Specs) |
|---|---|---|
| **Action 1<br>(동적 Path Filtering)** | • `.github/workflows/build-push-ecr.yml` | • `dorny/paths-filter` 액션을 주입하여 백엔드/프론트엔드 및 개별 마이크로서비스 경로 변경을 감지하고, 변경된 서비스명만 빌드 매트릭스(Matrix)로 전달하도록 파이프라인 재설계. |
| **Action 2<br>(Dockerfile Multi-stage 캐싱)** | • `Localy/*-service/Dockerfile` | • `COPY src` 실행 이전에 `COPY build.gradle` 및 `./gradlew dependencies` 명령어를 우선 배치하여 Docker 레이어 캐시 무효화 원천 봉쇄. |
| **Action 3<br>(무제한 S3/ECR 원격 캐시)** | • `.github/workflows/build-push-ecr.yml`<br>• `terraform/s3_cache.tf` (신설) | • Docker Buildx 캐시 저장소를 `type=registry`(ECR) 또는 `type=s3`로 전환.<br>• 원격 캐시 접근은 기존 셋업된 `aws-actions/configure-aws-credentials` (OIDC)를 재활용하고, S3/ECR에 14일 자동 삭제 정책 결속. |

---

## 🏆 [Theme 5-2 Debate Consensus] 파이프라인 품질 게이트 및 보안 검증 최종 합의 설계서
**작성일**: 2026-07-30 (4대 AI 전문가 서브에이전트 다각도 토론 조율 완결)
**조율 주체**: Antigravity (GitOps & CI/CD 점진적 배포 총괄 아키텍트)

### 1. 4대 전문 직군 관점 충돌 및 조율 결과 (Trade-off Resolution)
1. **[동시성 제어] FinOps 비용 절감 ↔ DevSecOps Race Condition 방어 일치**:
   - 4인 만장일치로 GitHub Actions에 `concurrency: cancel-in-progress: true` 옵션을 도입함. PR에 커밋을 연속 푸시할 경우, 돌고 있던 무의미한 이전 빌드를 즉각 취소하여 **CI 컴퓨팅 비용(FinOps)을 절감**하고 병렬 빌드로 인한 **태그 덮어쓰기 Race Condition(DevSecOps)을 원천 봉쇄**함.
2. **[품질 게이트] DevSecOps Fail-Fast ↔ Platform DevEx ↔ SRE 지연 방어 조율**:
   - JaCoCo 커버리지 80% 미달 및 SonarQube 취약점 발견 시 빌드를 폭파(Fail-Fast)시키는 것에 합의함. 단, 개발 편의성을 위해 **PR 단계에서는 변경된 파일만 스캔(Delta Scan)**하고, SRE 요구에 따라 SonarQube 응답 대기에 **5분 하드 타임아웃**을 결속하여 파이프라인 멈춤 장애(Fragility)를 예방함. (운영 환경은 FinOps 제안대로 Self-hosted로 비용 통제)
3. **[SBOM 자재명세서] SRE ECR 증명(Attestation) ↔ FinOps 스토리지 과금 조율**:
   - `org.cyclonedx.bom` Gradle 플러그인으로 생성된 SBOM을 ECR에 직접 업로드(Attestation)하여 완벽한 공급망 무결성을 확보함(SRE/DevSecOps). 단, ECR 스토리지 요금 폭탄을 막기 위해 **PR 커밋 빌드 시에는 SBOM을 폐기하고 오직 `main` 브랜치 병합 시에만 ECR에 푸시(FinOps)**하도록 타협함.

---

### 2. 테마 5-2 최종 실행 지시서 (Action Orders for Execution)

| 실행 단계 | 대상 영역 및 파일 | 구현할 핵심 아키텍처 사양 (Engineering Specs) |
|---|---|---|
| **Action 1<br>(GHA 빌드 동시성 제어)** | • `.github/workflows/build-push-ecr.yml` | • Workflow 최상단에 `concurrency` 그룹(`github.workflow-github.ref`) 매핑 및 `cancel-in-progress: true` 락다운 결속. |
| **Action 2<br>(SonarQube/JaCoCo 80% 컷)** | • `Localy/*-service/build.gradle`<br>• `terraform/sonarqube.tf` (신설) | • Gradle에 JaCoCo(`minimum: 0.80`) 및 SonarQube 플러그인 결속.<br>• GHA 파이프라인에 SonarQube Quality Gate 통과 대기 스텝(Timeout 5m) 신설. |
| **Action 3<br>(CycloneDX SBOM ECR 증명)** | • `Localy/*-service/build.gradle`<br>• `.github/workflows/build-push-ecr.yml` | • Gradle 빌드 수명주기에 SBOM 생성(`bom.json`) 플러그인 편입.<br>• ECR 푸시 스텝 이후 GHA `docker buildx imagetools` 또는 `cosign attach`를 사용하여 `main` 브랜치 한정으로 SBOM Attestation 업로드. |

---

## 🏆 [Theme 6-1 Debate Consensus] 동적 스케일링 성능 및 비용 최적화 최종 합의 설계서
**작성일**: 2026-07-30 (4대 AI 전문가 서브에이전트 다각도 토론 조율 완결)
**조율 주체**: Antigravity (GitOps & CI/CD 점진적 배포 총괄 아키텍트)

### 1. 4대 전문 직군 관점 충돌 및 조율 결과 (Trade-off Resolution)
1. **[콜드 스타트 지연] SRE 타임아웃 ↔ FinOps 과금 방어 조율 (오버프로비저닝 웜풀)**:
   - 파드 0개 상태에서 트래픽이 들어올 때 EC2가 부팅되는 60초 지연(SRE)과 무조건 스케일다운을 강제하는 요금 절감(FinOps) 사이의 완벽한 타협안 도출.
   - 가장 낮은 우선순위(`PriorityClass: -10`)를 가진 가짜 `pause` 파드를 띄워 인프라를 예열해 두고, KEDA가 실제 파드를 스케일업하면 쿠버네티스 스케줄러가 **가짜 파드를 즉시 축출(Preemption)하고 그 자리에 실제 파드를 0초 만에 스케줄링(Platform)**하는 웜풀 메커니즘을 채택함.
2. **[노드 압축 방어] FinOps 공격적 삭제 ↔ SRE/DevSecOps 안정성 조율**:
   - `consolidationPolicy: WhenUnderutilized`를 켜서 텅 빈 노드를 가차 없이 삭제하되, 파드가 축출될 때 활성 커넥션이 끊어지지 않도록 **PDB(Pod Disruption Budget)**를 강제 적용함.
   - 또한, 압축 과정에서 파드들이 한 노드에 몰려 단일 장애점(SPOF)이 되는 것을 막기 위해, 필수 서비스에 **Pod Anti-Affinity 분산 규칙(DevSecOps)**을 하드코딩하여 팩킹 한계선을 방어함.
3. **[ARM64 전면 도입] FinOps 요금 절감 ↔ Platform DevEx 조율**:
   - 요금을 40% 절감하는 AWS Graviton(ARM64)을 전면 혼용하기 위해 `kubernetes.io/arch: ["arm64", "amd64"]` NodePool을 확정함.
   - 개발자에게 특정 Taint/Toleration 작성을 강제하지 않고, CI에서 Multi-arch 빌드만 지원하면 **Karpenter가 자동으로 가장 싼 ARM 노드를 집어오도록(Platform)** DevEx를 극대화함.

---

### 2. 테마 6-1 최종 실행 지시서 (Action Orders for Execution)

| 실행 단계 | 대상 영역 및 파일 | 구현할 핵심 아키텍처 사양 (Engineering Specs) |
|---|---|---|
| **Action 1<br>(우선순위 기반 웜풀 구축)** | • `platform/priority-classes/` (신설)<br>• `apps/dummy-pause-pods/` (신설) | • `value: -10`인 `PriorityClass`를 생성하고, 리소스를 소모하지 않는 `registry.k8s.io/pause` 이미지를 배포하여 Karpenter 노드 예열 웜풀(Warm Pool) 가동. |
| **Action 2<br>(노드 압축 PDB/분산 방어망)** | • `Localy/*-service/.../deployment.yaml`<br>• `Localy/*-service/.../pdb.yaml` | • 노드 축출 시 안전망으로 PDB(`minAvailable: 1`)를 적용.<br>• Deployment에 `requiredDuringSchedulingIgnoredDuringExecution` 기반 Pod Anti-Affinity 추가하여 노드 간 파드 분산 강제. |
| **Action 3<br>(ARM64 자동화 및 권한 통제)** | • `.github/workflows/build-push-ecr.yml`<br>• `apps/karpenter/.../ec2-node-class.yaml` | • GHA 빌드 스텝에 `docker buildx` Multi-arch(`linux/amd64,linux/arm64`) 빌드 구성 추가.<br>• Karpenter Node IAM Role이 최소 권한 원칙에 따라 와일드카드(`*`)가 없도록 권한 감사(DevSecOps). |

---

## 🏆 [Theme 6-2 Debate Consensus] 안정성 및 무중단 수명주기 최종 합의 설계서
**작성일**: 2026-07-30 (4대 AI 전문가 서브에이전트 다각도 토론 조율 완결)
**조율 주체**: Antigravity (GitOps & CI/CD 점진적 배포 총괄 아키텍트)

### 1. 4대 전문 직군 관점 충돌 및 조율 결과 (Trade-off Resolution)
1. **[Spot 비율 통제] FinOps 80% 과금 절감 ↔ SRE/DevSecOps 방어망 조율**:
   - 운영(Prod) 환경의 컴퓨팅 비용을 극단적으로 낮추기 위해 **Spot 인스턴스 비율을 80%**로 끌어올리되(FinOps), 최소한의 방어선으로 **On-Demand 인스턴스를 20%** 혼용하기로 합의함.
   - 쿠버네티스의 `topologySpreadConstraints`를 `karpenter.sh/capacity-type` 키에 매핑하여 On-Demand와 Spot 노드 간에 파드를 분산시키고, SQS `interruptionQueue`를 결속하여 AWS의 2분 전 Spot 강제 회수 경고를 Karpenter가 낚아채 파드를 안전하게 대피(Drain)시키도록 이중 안전망을 구축함. (개발/스테이징 환경은 100% Spot 강제).
2. **[OS 패치 자동화] DevSecOps Drift 강제 ↔ Platform/SRE 무중단 방어 조율**:
   - 구형 리눅스 커널의 취약점을 방치하지 않기 위해 Karpenter의 **'Drift'** 기능을 전면 활성화하고 `expireAfter: 720h`(30일) 수명 제한을 강제함(DevSecOps).
   - 단, AWS가 새 EKS AMI를 출시했을 때 Karpenter가 모든 노드를 동시에 날려버리는 대참사를 막기 위해, NodePool 설정에 `disruption.budgets (maxUnavailable: 20%)`을 걸어 롤링 업데이트 속도를 제어함(Platform/SRE).
3. **[AZ 붕괴 방어] 멀티 가용영역 팩킹 강제 (만장일치)**:
   - AWS의 특정 데이터센터(AZ)에 불이 나거나 Spot 재고가 고갈되어도 서비스가 생존할 수 있도록, 모든 애플리케이션의 매니페스트에 `topology.kubernetes.io/zone` 기반의 `topologySpreadConstraints(maxSkew: 1)`를 하드코딩하여 파드들이 여러 AZ에 완벽히 쪼개져 분산되도록 강제함.

---

### 2. 테마 6-2 최종 실행 지시서 (Action Orders for Execution)

| 실행 단계 | 대상 영역 및 파일 | 구현할 핵심 아키텍처 사양 (Engineering Specs) |
|---|---|---|
| **Action 1<br>(Spot/On-Demand 하이브리드)** | • `Localy/*-service/.../deployment.yaml`<br>• `apps/karpenter/.../node-pool.yaml` | • Deployment에 `topologySpreadConstraints`(`karpenter.sh/capacity-type`) 적용.<br>• NodePool에 `spot`과 `on-demand` Capacity Type을 동시 허용하고, SQS `interruptionQueue` 활성화 상태 유지. |
| **Action 2<br>(Drift 무중단 OS 패치 속도 제어)** | • `apps/karpenter/.../node-pool.yaml` | • `expireAfter: 720h` 유지 및 `disruption.budgets` 설정 추가(`nodes: 20%` 제한)를 통해 Drift 시 노드가 한 번에 폭파되는 현상 방지. |
| **Action 3<br>(Multi-AZ 하드 분산)** | • `Localy/*-service/.../deployment.yaml` | • Deployment에 `topology.kubernetes.io/zone` 기반 `maxSkew: 1` `topologySpreadConstraints`를 강제하여 AZ 단위의 고가용성(HA) 확보. |

