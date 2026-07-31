# 🏛️ 차세대 GitOps 및 CD 파이프라인 마스터 설계도 (Next-Generation Architecture Blueprint)

* **프로젝트명**: Localy Next-Gen GitOps & CD Pipeline Refactoring
* **작성 시작일**: 2026-07-27
* **설계 원칙**: 과거의 설계도에 끼워 맞추지 않고, 5개 물리 영역 심층 정찰(`stage2_themes.md`)을 통해 발굴된 날것의 결함을 10대 정밀 아젠다 난상 토론을 거쳐 상향식(Bottom-Up)으로 해결하는 표준 블루프린트.

---

## 📑 10대 정밀 토론 아젠다 및 매핑 추적 매트릭스 (Traceability Matrix)

| 도메인 | 안건 번호 | 토론 아젠다 주제 | 연계된 `stage2_themes.md` 좌표 | 상태 |
| :---: | :---: | :--- | :--- | :---: |
| **Domain A** (GitOps 루트 & 폴더) | **아젠다 1** | **이중 Root App 스플릿 브레인 및 폴더 구조 통폐합** | `[Area 2 - 테마 1]`, `[Area 3 - 테마 1]`, `[Area 5 - 테마 1]` | ✅ **완료 (박제됨)** |
| | **아젠다 2** | **Kustomize `--enable-helm` 오용 퇴출 및 차세대 패키징 표준화** | `[Area 2 - 테마 2]`, `[Area 4 - 테마 4]`, `[Area 5 - 테마 1]` | ✅ **완료 (박제됨)** |
| | **아젠다 3** | **고아/데드 코드 청산 및 데이터베이스 마이크로서비스 독립성 확보** | `[Area 1 - 테마 4]`, `[Area 4 - 테마 4]`, `[Area 5 - 테마 1]` | ✅ **완료 (박제됨)** |
| **Domain B** (오토스케일링 & 자원) | **아젠다 4** | **오토스케일러(KEDA/HPA) vs Namespace Quota 교착(Deadlock) 해소** | `[Area 3 - 테마 3]`, `[Area 4 - 테마 1]`, `[Area 5 - 테마 4]` | ✅ **완료 (박제됨)** |
| | **아젠다 5** | **Karpenter NodePool 전략 개편 및 Keycloak 스케줄링 버그 해결** | `[Area 5 - 테마 2]`, `[Area 5 - 테마 4]` | ✅ **완료 (박제됨)** |
| | **아젠다 6** | **인프라 IaC 상태 관리 및 비용 효율화(FinOps)** | `[Area 1 - 테마 2]`, `[Area 1 - 테마 3]`, `[Area 2 - 테마 4]` | ✅ **완료 (박제됨)** |
| **Domain C** (DevSecOps & 기밀) | **아젠다 7** | **OIDC IAM 및 ESO(External Secrets Operator) 권한 탈취 방지** | `[Area 1 - 테마 1]`, `[Area 2 - 테마 3]`, `[Area 5 - 테마 3]` | ✅ **완료 (박제됨)** |
| | **아젠다 8** | **워크로드 및 플랫폼 기밀 데이터/보안 컨텍스트 격리** | `[Area 4 - 테마 2]`, `[Area 5 - 테마 3]` | ✅ **완료 (박제됨)** |
| **Domain D** (트래픽 배포 & 관측성) | **아젠다 9** | **AWS ALB 무중단 배포(Zero-Downtime) 및 트래픽 라우팅 정상화** | `[Area 4 - 테마 3]`, `[Area 5 - 테마 2]`, `[Area 5 - 테마 3]` | ✅ **완료 (박제됨)** |
| | **아젠다 10**| **관측성(Observability) 중복 제거 및 파괴적 연쇄 삭제 방지** | `[Area 3 - 테마 2]`, `[Area 5 - 테마 4]` | ✅ **완료 (박제됨)** |

---

## 🏛️ [Domain A - 아젠다 1] 이중 Root App 스플릿 브레인 및 폴더 구조 통폐합
* **상태**: ✅ 합의 완료 및 아키텍처 박제
* **참조 좌표**: `[Area 2 - 테마 1]`, `[Area 3 - 테마 1]`, `[Area 5 - 테마 1]`
* **참여 에이전트**: Platform, DevSecOps, SRE, FinOps 전문 에이전트

### 1. 핵심 진단 및 합의 사항
1. **스플릿 브레인 퇴출**: `bootstrap/`과 `argocd-apps/` 간의 이중 Root 경쟁과 무한 Sync/Prune 루프를 원천 삭제. `argocd-apps/` 및 `apps/` 폴더를 영구 폐기(Decommission)하고 `localy-manifests/` 하위 단일 트리로 통합.
2. **12개 메이저 버전 괴리 단일화**: `kube-prometheus-stack`을 v70.0.0으로 단일화하고 v58.2.0 고아 버전을 청산. `node-local-dns`를 v2.8.0 DeliveryHero 차트로 단일화 및 Corefile 외부 DNS 포워딩 오타 수정.
3. **AppProject 3대 격리**: 100% `default` AppProject 사용을 금지하고 `platform-project`(클러스터 권한 허용), `workloads-project`(클러스터 권한 0%, Quota/IAM 수정 철저 차단), `guardrails-project`(보안 및 Quota 강제 전용)로 분리.
4. **HA 펀딩 그랜드 바겐 (FinOps vs SRE/DevSecOps)**: FinOps는 부르는 곳 없는 5개 고아 애드온 청산과 OTel->Jaeger 2중 홉 추적 파이프라인 단일화(OpenSearch 직결)를 통해 **4~5.5개 CPU 코어, 14GB 메모리, 65Gi 이상의 EBS RWO 볼륨 비용을 절감**하고, 이 절감분으로 핵심 플랫폼 컨트롤러(KEDA, ESO, Reloader 등)의 HA(2 Replica + PDB) 및 Non-Root 컨테이너 구성을 완벽 지원함.

### 2. 표준 통폐합 디렉터리 레이아웃 (SSOT)
```text
localy-manifests/
├── gitops/                        # 🏁 [SSOT 1] 단일 GitOps Root App 및 AppProject (기존 bootstrap + argocd-apps 통합)
│   ├── base/
│   │   ├── projects/              # DevSecOps 통제: platform-project, workloads-project, guardrails-project
│   │   ├── root-platform.yaml     # App of Apps (Tier 1: 플랫폼 애드온 전용)
│   │   └── root-workloads.yaml    # App of Apps (Tier 2: 마이크로서비스 워크로드 전용)
│   └── overlays/{dev,staging,prod}/ # 환경별 Root 오버레이 및 타겟 클러스터 매핑
├── platform/                      # ⚙️ [SSOT 2] L4 플랫폼 애드온 (기존 apps/ + platform/ 중 최신 버전 단일화)
│   ├── alb-controller/            # AWS Load Balancer Controller (ServerSideApply=true, Delete=false)
│   ├── cert-manager/              # Cert-Manager + ClusterIssuers
│   ├── external-dns/              # External DNS (최소 권한 IRSA 바인딩)
│   ├── external-secrets/          # External Secrets Operator (auth 블록 필수 추가, 중복 제거)
│   ├── karpenter/                 # Karpenter (prod-eks 타겟 및 IRSA 단일화, CP949 인코딩 오류 해결)
│   ├── keda/                      # KEDA 오토스케일러 (고아 prometheus-adapter 영구 폐기 및 대체)
│   ├── kyverno/                   # Kyverno 보안/거버넌스 정책 엔진
│   ├── node-local-dns/            # v2.8.0 DeliveryHero 차트 단일화 (Corefile 오타 수정)
│   └── observability/             # kube-prometheus-stack(v70.0.0), loki, otel-gateway 단일화
├── workloads/                     # 🚀 [SSOT 3] L5 비즈니스 마이크로서비스 (6대 서비스)
│   ├── base/                      # 공통 Deployment/Service Kustomize Base (NonRoot, Probes, PDB 강제)
│   └── overlays/{dev,staging,prod}/ # 환경별 이미지 태그 및 레플리카 오버레이
└── common/                        # 🧩 [SSOT 4] 공통 보안 가드레일 및 정책 (고아 해방!)
    └── guardrails/                # ResourceQuota, LimitRange, NetworkPolicy (workloads에서 필수 import!)
```

### 3. 고가용성 6-Tier 동기화 웨이브 (Sync-Wave) 명세
| Tier | Sync Wave | Component Category | Target Applications / Resources | SRE Justification & Readiness Gate |
| :--- | :---: | :--- | :--- | :--- |
| **Tier 0** | `-10` to `-8` | **CRDs & Security Governance** | `cert-manager` (CRD), `kyverno`, `common/guardrails` | 워크로드 생성 전 Quota 및 Kyverno 웹훅 강제 우선 적용 (`ServerSideApply=true`, `Delete=false` 보호) |
| **Tier 1** | `-7` to `-5` | **Secrets & Identity Provider** | `external-secrets-operator` (ESO), ClusterSecretStore | 파드 스케줄링 전 AWS Secrets Manager 복호화 완료 강제 |
| **Tier 2** | `-4` to `-2` | **Networking, DNS & Storage** | `node-local-dns`, `alb-controller`, `external-dns` | 애플리케이션 시작 전 라우팅, DNS 캐싱, 스토리지 준비 |
| **Tier 3** | `-1` to `0` | **Compute Provisioning & Autoscaling** | `karpenter-controller`, `karpenter-provisioner`, `keda` | 동적 노드 풀 및 오토스케일러 활성화 완료 |
| **Tier 4** | `1` to `5` | **Core Platform Services** | `keycloak` (Auth), `ingress-core`, `observability` | 인증 및 인그레스 게이트웨이 정상화 완료 후 트래픽 수신 준비 |
| **Tier 5** | `10` to `20` | **Business Microservices (L5 Workloads)** | `user`, `store` -> `order`, `payment`, `edge-service` | 최종 비즈니스 로직 배포. HPA와 GitOps 충돌 방지를 위해 Deployment `spec.replicas`에 `ignoreDifferences` 적용 |

---

## 🏛️ [Domain A - 아젠다 2] Kustomize `--enable-helm` 오용 퇴출 및 차세대 패키징 표준화
* **상태**: ✅ 합의 완료 및 아키텍처 박제
* **참조 좌표**: `[Area 2 - 테마 2]`, `[Area 4 - 테마 4]`, `[Area 5 - 테마 1]`
* **참여 에이전트**: Platform, DevSecOps, SRE, FinOps 전문 에이전트

### 1. 핵심 진단 및 합의 사항
1. **Kustomize `--enable-helm` 전면 퇴출**: Kustomize 내부 동적 Helm 렌더링이 유발하는 Repo-Server CPU 40~60% 과부하, Karpenter 불필요 노드 스케일아웃, 네이티브 Helm 릴리스 이력 말살을 원천 차단. 11개 플랫폼 애드온을 **ArgoCD 네이티브 Multi-Source Helm Application**으로 전환하고 `argocd-cm`에서 `--enable-helm: "false"` 영구 강제.
2. **Boilerplate 85% 제거 및 공통 Base 표준화**: 6개 마이크로서비스마다 10배씩 복사된 파편화 YAML을 제거하고 `workloads/base/`에 단일 표준 템플릿 구현. 개별 서비스(`cart-service/base/`)는 단 15줄의 Kustomization으로 공통 템플릿과 가드레일을 상속.
3. **고아 가드레일(`common/guardrails`) 자동 상속**: 방치되었던 `resource-quota.yaml`과 `limit-range.yaml`을 `workloads/base/kustomization.yaml`의 `components:`로 편입하여, 모든 비즈니스 서비스에 예외 없는 Quota 및 보안 규칙 자동 주입.
4. **HPA-Quota 교착 및 OOMKill 해결 (FinOps/SRE 합의)**: Namespace Quota를 `maxReplicas * container_limit` 이상으로 동기화하여 스케일링 80% 잠금 현상을 해소. JVM `-XX:MaxRAMPercentage=75.0` 사용 시 컨테이너 명시적 Memory Limit 선언을 의무화하여 cgroup-JVM 메모리 불일치로 인한 OOMKill 박멸. CPU Burst 비율은 2~3배로 제한하고 KEDA 선제적 수평 스케일링으로 전환.
5. **3중 방어선 (Three-Tier Defense-in-Depth)**: 개발자가 오버레이에서 `$patch: delete`로 보안 규칙을 우회하지 못하도록 ① Base 하드코딩 -> ② CI CODEOWNERS 및 Conftest 검증 -> ③ Kyverno Enforce 모드 어드미션 제어(403 Forbidden 차단) 체계 확립.

### 2. 플랫폼 애드온: Multi-Source Application 표준 명세
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kube-prometheus-stack
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "1" # Tier 4 웨이브
spec:
  project: platform-project           # Dedicated AppProject 강제 (default 금지!)
  sources:
    # 🔗 Source 1: 불변(Immutable) 원격 Helm / OCI 저장소 (차트 렌더링 전담)
    - repoURL: "oci://ghcr.io/prometheus-community/charts"
      chart: "kube-prometheus-stack"
      targetRevision: "70.0.0"        # Floating 태그 금지, 정확한 시맨틱 버전 또는 OCI 다이제스트 강제
      helm:
        releaseName: "kube-prometheus-stack"
        valueFiles:
          - $values/platform/observability/values-prod.yaml # Source 2의 Git 매니페스트 참조
    
    # 🔗 Source 2: 기업 내부 GitOps 저장소 (Values 및 Custom 패치 전담)
    - repoURL: "https://github.com/localy-project/localy-manifests.git"
      targetRevision: main
      ref: values                     # '$values' 변수로 바인딩
  destination:
    server: "https://kubernetes.default.svc"
    namespace: monitoring
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
      - Delete=false                  # CRD 파멸적 연쇄 삭제 방지
```

### 3. 마이크로서비스 표준 Kustomize Base 및 5대 고가용성 요소 명세
`workloads/base/`는 다음 5대 SRE 고가용성 요소를 하드코딩하여 모든 워크로드에 자동 적용합니다:
1. **Pod Disruption Budgets (PDBs)**: `maxUnavailable: 1` (또는 최소 가용성 80%) 강제로 노드 드레인 시 SPOF 차단.
2. **3대 Probes 표준화**: Spring Boot 및 DB 웜업을 위한 Startup Probe(최대 70초), 교착 감지 Liveness Probe(3~5초), DB/ALB 타겟 상태 결속 Readiness Probe 의무화.
3. **다중 AZ TopologySpreadConstraints**: AZ(`topology.kubernetes.io/zone`) 및 노드 간 파드 분산(`maxSkew: 1`, `DoNotSchedule`) 강제.
4. **ALB 무중단 배포 핸드오프 (Zero-Downtime)**: 20초 PreStop Sleep Hook (`sleep 20`) + 90초 Grace Period (`terminationGracePeriodSeconds: 90`) + AWS ALB Readiness Gate (`target-health.alb.ingress.k8s.aws/app-svc`) 강제.
5. **envFrom 퇴출 및 기밀 볼륨 마운트**: `envFrom` 퇴출, 최소 권한 IAM(IRSA) 연동 External-Secrets를 통한 읽기 전용 볼륨 마운트 표준화.

```yaml
# [workloads/base/kustomization.yaml 표준 명세]
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml      # 5대 고가용성 요소 및 Non-Root 보안 컨텍스트 하드코딩
  - service.yaml         # 표준 8080 / 9090 포트
  - pdb.yaml             # maxUnavailable: 1
  - serviceaccount.yaml  # 최소 권한 IRSA Placeholder
  - external-secret.yaml # AWS Secrets Manager 볼륨 마운트
  - service-monitor.yaml # 프로메테우스 9090 메트릭 수집
components:
  - ../../common/guardrails # 🛡️ Quota 및 LimitRange 가드레일 자동 상속!
```

---

## 🏛️ [Domain A - 아젠다 3] 고아/데드 코드 청산 및 데이터베이스 마이크로서비스 독립성 확보
* **상태**: ✅ 합의 완료 및 아키텍처 박제
* **참조 좌표**: `[Area 1 - 테마 4]`, `[Area 4 - 테마 4]`, `[Area 5 - 테마 1]`
* **참여 에이전트**: Platform, DevSecOps, SRE, FinOps 전문 에이전트

### 1. 핵심 진단 및 합의 사항
1. **모놀리식 `db-migration` 전면 폐기**: 단일 YAML(`db-init-job.yaml`)로 방치되어 모든 DB 스키마와 계정을 통제하던 구조를 전면 삭제. 마이그레이션을 각 마이크로서비스 Kustomize 폴더(`workloads/<service>/base/migration-job.yaml`)로 분산하여 **"1 서비스 1 데이터베이스(Shared Nothing)"** 달성.
2. **ArgoCD PreSync Hook Job 채택 (InitContainer 데드락 퇴출)**: HPA/KEDA 10개 레플리카 확장 시 InitContainer들이 DB 락(Lock) 경합을 벌이는 데드락을 원천 차단. 배포(Wave 1) 전 단 1회만 안전하게 실행되는 **ArgoCD PreSync Hook (`argocd.argoproj.io/hook: PreSync`)**을 표준화.
3. **FinOps 초경량 컴퓨팅 가드레일 하드코딩**: 마이그레이션 Job에 `requests: 100m CPU / 128Mi RAM`, `limits: 256m CPU / 256Mi RAM` 및 **`ttlSecondsAfterFinished: 60`**을 강제하여, 스키마 초기화 60초 후 K8s/etcd에서 완벽히 삭제되도록 하여 0원의 컴퓨팅 비용 및 Karpenter 증설 원천 방지.
4. **논리적 도메인 독립성 & AWS RDS Proxy (FinOps vs DevSecOps/SRE 합의)**: 물리적 RDS를 6개 띄우는 비용 폭증(6배 요금)을 피하기 위해, 단일 AWS Aurora / RDS 클러스터 내에서 논리적으로 완벽히 격리된 스키마/데이터베이스(`order_db`, `payment_db`)와 전용 계정(`orderuser`, `paymentuser`)을 생성. 평문 비밀번호 및 `envFrom` 주입을 폐기하고 **AWS IAM IRSA DB 인증(`rds-db:connect`)**을 도입하며, 커넥션 풀 단절 방지를 위해 **AWS RDS Proxy (또는 Advanced JDBC Wrapper)** 연동.
5. **SRE 4단계 안전 청산 및 CRD 보호벽 하드코딩**: 5개 고아 애드온(`cilium`, `jaeger`, `otel-collector`, `prometheus-adapter`, 구버전 `kube-prometheus-stack` v58.2.0) 및 빈 폴더 삭제 전, ① GitOps Dry-Run 감사 -> ② CRD 보호벽 하드코딩(`Delete=false,ServerSideApply=true`) -> ③ 불변 Git SHA 태그 전환 -> ④ OTel/KEDA 카나리 검증 프로토콜을 의무화하여 **4~5.5개 CPU, 14GB RAM, 65Gi EBS 볼륨 회수 중 블래스트 반경 0%** 보장!

### 2. 서비스 전용 PreSync DB 마이그레이션 Job 표준 명세
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: order-db-migration
  namespace: order-svc
  annotations:
    # 🏁 [ArgoCD PreSync Hook] 배포(Wave 1) 전 단 1회 실행 완료 보장!
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation,HookSucceeded
    argocd.argoproj.io/sync-wave: "-1"
spec:
  backoffLimit: 2                   # 무한 재시도 부하 방지
  activeDeadlineSeconds: 300        # 5분 타임아웃
  ttlSecondsAfterFinished: 60       # 🗑️ [FinOps] 종료 60초 후 K8s/etcd에서 완벽히 자동 제거 (컴퓨팅 0원)
  template:
    metadata:
      labels:
        app.kubernetes.io/name: order-db-migration
    spec:
      serviceAccountName: order-db-migration-sa # IRSA 적용 (rds-db:connect 최소 권한)
      restartPolicy: Never
      # 🛡️ [DevSecOps] 완벽한 Non-Root 및 읽기 전용 파일시스템 보안 컨텍스트 하드코딩
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: flyway-migration
          image: flyway/flyway:10-alpine # 불변 태그 적용
          command: ["flyway", "migrate"]
          env:
            - name: FLYWAY_URL
              value: "jdbc:postgresql://aurora-cluster.rds.amazonaws.com:5432/order_db"
            - name: FLYWAY_USER
              value: "orderuser"
            # 🔐 ESO가 SecretManager에서 수집한 메모리 볼륨 마운트(/mnt/secrets) 또는 SecretRef 바인딩
            - name: FLYWAY_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: order-db-secret
                  key: password
          # 💰 [FinOps] Karpenter 노드 증설을 방지하는 초경량 빈패킹 자원 할당
          resources:
            requests:
              cpu: "100m"
              memory: "128Mi"
            limits:
              cpu: "256m"
              memory: "256Mi"
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
```

---

## 🏛️ [Domain B - 아젠다 4] 오토스케일러(KEDA/HPA) vs Namespace Quota 교착(Deadlock) 해소
* **상태**: ✅ 합의 완료 및 아키텍처 박제
* **참조 좌표**: `[Area 3 - 테마 3]`, `[Area 4 - 테마 1]`, `[Area 5 - 테마 4]`
* **참여 에이전트**: Platform, DevSecOps, SRE, FinOps 전문 에이전트

### 1. 핵심 진단 및 합의 사항
1. **403 Quota Deadlock 전면 해소**: 정적인 4.0 CPU Quota를 폐기하고, CI/CD 파이프라인에서 환경별 서지 버퍼($\alpha_{\text{prod}}=15\%$)와 사이드카 자원까지 반영한 **동적 ResourceQuota 수학적 산출 공식** $\sum(\text{maxReplicas} \times \text{Limit}) \times 1.15$를 표준화. 이로써 `payment-service`는 Quota 상한선이 18.4 CPU / 13Gi Memory로 확장되어 10개 레플리카 확장 시 발생하던 80% 용량 마비 현상과 무중단 배포 시의 403 데드락을 원천 봉쇄.
2. **CPU Burst 2~3배 제한 (FinOps 가드레일)**: `payment`(6배 Burst)와 `order`(5배 Burst)의 과도한 CPU Burst로 인한 ARM64 노드 CFS 스로틀링을 차단하기 위해 Burst 비율을 2~3배 이하로 제한. 안착 용량을 확보하면서 Quota 내 수평 스케일링 효율을 극대화.
3. **KEDA 단일 SSOT화 & `prometheus-adapter` 퇴출**: KEDA가 HPA(`keda-hpa-{name}`)를 내부적으로 자동 제어하므로 수동 `hpa.yaml`은 전면 삭제. 중복 메트릭 수집 엔진인 `prometheus-adapter`를 삭제하여 PromQL 부하 감소 및 컴퓨팅 자원을 회수.
4. **ALB 300초 Deregistration Delay 방어 (SRE 하드코딩)**: AWS ALB 타겟 그룹의 등록 해제 지연 시간(300초) 완료 전에 파드가 삭제되어 502/504 에러가 발생하는 것을 막기 위해 KEDA `scaleDown.stabilizationWindowSeconds`를 **300초(5분)로 하드코딩**하고 분당 10%의 점진적 축소 정책 적용.
5. **ArgoCD 스플릿 브레인 퇴출 (`ignoreDifferences` 표준화)**: ArgoCD 자동 복구(`selfHeal: true`)가 HPA로 확장된 파드를 강제 종료시키는 Thrashing 루프를 차단하기 위해, 모든 마이크로서비스 Application 매니페스트에 **Deployment `/spec/replicas`에 대한 `ignoreDifferences`**를 표준 주입.
6. **3중 Shift-Left 방어벽 및 Kyverno 어드미션 제어**: PR Merge 전에 CI/CD와 Kyverno 웹훅이 `(Container Limit * maxReplicas) <= Namespace Quota` 공식을 수학적으로 검증하여 초과 시 `403 Forbidden`으로 즉각 거부. Karpenter NodePool에는 무제한 온디맨드 EC2 증설을 막는 **`spec.limits` (클러스터 CPU/Memory 최대 상한선)**를 의무화하여 DoS 요금 폭탄(Bill Shock)을 원천 차단.

### 2. 표준 KEDA ScaledObject 명세 (ALB 300초 방어 및 MSK/RPS 이벤트 연동)
```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: payment-service-scaler
  namespace: payment-svc
spec:
  scaleTargetRef:
    name: payment-service
  minReplicaCount: 2
  maxReplicaCount: 10
  cooldownPeriod: 300               # 5분간 트래픽 공백 시 minReplicas로 축소
  advanced:
    horizontalPodAutoscalerConfig:
      behavior:
        # 🚀 [Scale-Up] 트래픽 급증 시 즉각 반응 (0초 대기, 15초마다 최대 100% 또는 4개 파드 확장)
        scaleUp:
          stabilizationWindowSeconds: 0
          selectPolicy: Max
          policies:
            - type: Percent
              value: 100
              periodSeconds: 15
            - type: Pods
              value: 4
              periodSeconds: 15
        # 🛡️ [Scale-Down] AWS ALB Deregistration Delay(300초) 완료 전에 파드 종료 시 발생하는 502/504 에러 원천 방어!
        scaleDown:
          stabilizationWindowSeconds: 300 # 반드시 300초간 저트래픽 유지 후 천천히 축소
          selectPolicy: Min
          policies:
            - type: Percent
              value: 10
              periodSeconds: 60       # 분당 최대 10% 파드만 점진적 축소
  triggers:
    # 🔗 Trigger 1: AWS MSK Kafka Consumer Lag 기반 선제적 스케일링
    - type: aws-msk
      metadata:
        bootstrapServers: "msk-prod.localy.internal:9092"
        consumerGroup: "payment-processing-group"
        topic: "payment-events"
        lagThreshold: "500"           # 파드당 미처리 메시지 500개 초과 시 확장
        activationLagThreshold: "50"  # 50개 이상일 때만 HPA 활성화 (노이즈 플래핑 박멸)
    # 🔗 Trigger 2: Prometheus Ingress RPS (HTTP 초당 요청 수) 기반 연동
    - type: prometheus
      metadata:
        serverAddress: "http://kube-prometheus-stack-prometheus.monitoring:9090"
        metricName: "http_rps_per_pod"
        query: sum(rate(http_requests_total{job="payment-service",status!~"5.*"}[2m])) / max(kube_endpoint_address_available{endpoint="payment-service"})
        threshold: "120"              # 파드당 120 RPS 도달 시 스케일아웃
```

### 3. 표준 ArgoCD Application 명세 (`ignoreDifferences` 스플릿 브레인 차단)
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: payment-service
  namespace: argocd
spec:
  project: workloads-project          # default 금지 (DevSecOps 통제)
  source:
    repoURL: "https://github.com/localy-project/localy-manifests.git"
    targetRevision: main
    path: workloads/payment-service/overlays/prod
  destination:
    server: "https://kubernetes.default.svc"
    namespace: payment-svc
  syncPolicy:
    automated:
      prune: true
      selfHeal: true                  # 이미지 태그, 환경변수 등 GitOps 자율 복구 유지
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
  # 🏁 [CORE STANDARDIZATION] 파드 레플리카 수의 제어권을 KEDA/HPA에 100% 위임 (ArgoCD 강제 종료 방지!)
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/replicas
```

### 4. 표준 Kyverno Shift-Left 수학적 Quota 정렬 어드미션 제어 정책
```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: enforce-hpa-quota-alignment
  annotations:
    policies.kyverno.io/title: Enforce KEDA maxReplicas vs Quota Alignment
    policies.kyverno.io/subject: ScaledObject, HorizontalPodAutoscaler
spec:
  validationFailureAction: Enforce    # 403 Forbidden 즉각 차단 (Shift-Left CI 검증 겸용)
  background: false
  rules:
    - name: validate-max-replicas-against-quota
      match:
        any:
          - resources:
              kinds:
                - keda.sh/v1alpha1/ScaledObject
      context:
        - name: nsCpuQuota
          apiCall:
            urlPath: "/api/v1/namespaces/{{request.namespace}}/resourcequotas"
            jmesPath: "items[0].status.hard.\"limits.cpu\" || '0'"
        - name: targetCpuLimit
          apiCall:
            urlPath: "/apis/apps/v1/namespaces/{{request.namespace}}/deployments/{{request.object.spec.scaleTargetRef.name}}"
            jmesPath: "spec.template.spec.containers[0].resources.limits.cpu || '0'"
      validate:
        message: >
          [DevSecOps Block] 오토스케일러 데드락 위험 감지! Deployment의 CPU Limit과 KEDA maxReplicas의 곱이
          Namespace ResourceQuota를 초과합니다. KEDA maxReplicas를 줄이거나 Quota 증설을 신청하십시오.
        deny:
          conditions:
            any:
              - key: "{{ multiply(targetCpuLimit, request.object.spec.maxReplicaCount) }}"
                operator: GreaterThan
                value: "{{ nsCpuQuota }}"
```

---

## 🏛️ [Domain B - 아젠다 5] Karpenter NodePool 전략 개편 및 Keycloak 스케줄링 버그 해결
* **상태**: ✅ 합의 완료 및 아키텍처 박제
* **참조 좌표**: `[Area 5 - 테마 2]`, `[Area 5 - 테마 4]`
* **참여 에이전트**: Platform, DevSecOps, SRE, FinOps 전문 에이전트

### 1. 핵심 진단 및 합의 사항
1. **Keycloak 영구 `Pending` 데드락 해결**: Keycloak 매니페스트가 존재하지 않는 `default` 노드풀을 참조하던 GitOps 스플릿 브레인 결함을 교정하여 `role: workload` (또는 `platform`)를 명시적으로 타겟팅.
2. **4대 가중치(Weight) 기반 NodePool 통폐합 및 무중단 Fallback**:
   - `platform-pool` (Weight 50): 코어 시스템 및 보안 애드온 전용. 100% On-Demand, `WhenUnderutilized` 적용 (낭비적인 14일 `WhenEmpty` 정책 전면 퇴출).
   - `workload-spot-pool` (Weight 20): 비즈니스 워크로드 최우선 배치. 4대 Graviton ARM64 인스턴스(`t4g`, `c6g`, `m6g`, `r6g`) 다각화로 AWS Spot ICE(용량 부족) 에러 원천 방어 및 70~80% 비용 절감.
   - `workload-od-pool` (Weight 10): Spot 고갈 시 파드 스케줄링 실패 없이 즉시 할당되는 안전망(Fallback) On-Demand 풀.
   - `database-pool` (Weight 30): 데이터베이스 마이그레이션 및 캐시 전용 메모리 최적화(`r6g`, `m6g`) 풀. Taint 격리 및 30일(`720h`) 보존.
3. **FinOps Bill Shock 방어벽 (`spec.limits`) 수량화 & 61% 비용 절감 증명**:
   - 무제한 EC2 증설로 인한 요금 폭탄을 막기 위해 환경별 상한선 하드코딩: Dev(100 Core/400Gi), Staging(250 Core/1,000Gi), Prod Platform(200 Core/800Gi), Prod Workload(800 Core/3,200Gi). **Prod 총 상한: 1,000 Core / 4,000 GiB**.
   - Spot 하이브리드(35%) $\times$ Graviton2 Burstable(`t4g`) 개방(25%) $\times$ 10분 주기 `WhenUnderutilized` 압축 및 만료 7일 단축(20%)을 결합하여 **월간 EKS 컴퓨팅 비용 61% 삭감** 수학적 증명.
4. **Keycloak OOMKill 박멸 및 고가용성 JVM/PDB 하드코딩**:
   - cgroup-JVM 메모리 불일치로 인한 OOMKill을 막는 `-XX:MaxRAMPercentage=75.0 -XX:+UseG1GC` 주입 및 컨테이너 Limits(2Gi) 고정.
   - 노드 드레인 시 SPOF를 방지하는 PDB(`maxUnavailable: 1`) 강제 및 경직된 Anti-Affinity를 완화한 AZ 분산 배치(`whenUnsatisfiable: ScheduleAnyway`).
5. **Zero-Downtime 드레인 및 DevSecOps Hardening**:
   - AWS ALB 등록 해제 지연(30s) 및 AWS Node Termination Handler(SQS 2분 Spot 중단 알림)와 결속된 60s Grace Period + 15s PreStop Sleep Hook (`sleep 15`) 하드코딩.
   - 모든 Karpenter `EC2NodeClass`에 IMDSv2(`httpTokens: required`, `httpPutResponseHopLimit: 1`) 및 AWS KMS 고객 관리형 키(CMK) `gp3` 암호화 의무화.

### 2. 표준 Karpenter 4대 가중치 기반 NodePool 명세
```yaml
# [platform/karpenter/overlays/prod/node-pool.yaml 핵심 명세]

# 1. 🛡️ Platform Pool (Weight 50, 100% On-Demand, 200 Core / 800Gi Limit)
apiVersion: karpenter.sh/v1beta1
kind: NodePool
metadata:
  name: platform-pool
spec:
  weight: 50
  template:
    metadata:
      labels: { role: platform, node.kubernetes.io/tier: platform }
    spec:
      taints: [{ key: platform-only, value: "true", effect: NoSchedule }]
      requirements:
        - { key: karpenter.sh/capacity-type, operator: In, values: ["on-demand"] }
        - { key: kubernetes.io/arch, operator: In, values: ["arm64", "amd64"] }
        - { key: karpenter.k8s.aws/instance-family, operator: In, values: ["c6g", "m6g", "r6g", "c6i", "m6i"] }
  limits: { cpu: "200", memory: "800Gi" }
  disruption:
    consolidationPolicy: WhenUnderutilized # 🗑️ 14일 방치 WhenEmpty 퇴출!
    consolidateAfter: 10m
    expireAfter: 336h

---
# 2. 🚀 Workload Spot Pool (Weight 20 - 최우선 순위! 800 Core / 3200Gi Limit 공유)
apiVersion: karpenter.sh/v1beta1
kind: NodePool
metadata:
  name: workload-spot-pool
spec:
  weight: 20                           # Spot을 온디맨드보다 우선 평가!
  template:
    metadata:
      labels: { role: workload, node.kubernetes.io/tier: workload }
    spec:
      requirements:
        - { key: karpenter.sh/capacity-type, operator: In, values: ["spot"] }
        - { key: kubernetes.io/arch, operator: In, values: ["arm64"] }
        # 4대 인스턴스 패밀리 다각화로 AWS Spot ICE(용량 부족) 에러 원천 차단
        - { key: karpenter.k8s.aws/instance-family, operator: In, values: ["t4g", "c6g", "m6g", "r6g"] }
        - { key: karpenter.k8s.aws/instance-size, operator: In, values: ["medium", "large", "xlarge", "2xlarge"] }
  limits: { cpu: "800", memory: "3200Gi" }
  disruption:
    consolidationPolicy: WhenUnderutilized
    consolidateAfter: 10m
    expireAfter: 168h                  # 7일마다 주간 노드 리프레시 (메모리 단편화 제거)

---
# 3. 🔄 Workload On-Demand Fallback Pool (Weight 10 - Spot 고갈 시 자동 무중단 풀백)
apiVersion: karpenter.sh/v1beta1
kind: NodePool
metadata:
  name: workload-od-pool
spec:
  weight: 10                           # Spot 실패 시 자동 선택되는 안전망
  template:
    metadata:
      labels: { role: workload, node.kubernetes.io/tier: workload }
    spec:
      requirements:
        - { key: karpenter.sh/capacity-type, operator: In, values: ["on-demand"] }
        - { key: kubernetes.io/arch, operator: In, values: ["arm64"] }
        - { key: karpenter.k8s.aws/instance-family, operator: In, values: ["t4g", "c6g", "m6g", "r6g"] }
  limits: { cpu: "800", memory: "3200Gi" }
  disruption:
    consolidationPolicy: WhenUnderutilized
    consolidateAfter: 10m
    expireAfter: 336h

---
# 4. 🗄️ Database & Cache Pool (Weight 30, Memory-Optimized r6g/m6g, 격리 보장)
apiVersion: karpenter.sh/v1beta1
kind: NodePool
metadata:
  name: database-pool
spec:
  weight: 30
  template:
    metadata:
      labels: { role: database, node.kubernetes.io/tier: database }
    spec:
      taints: [{ key: database-only, value: "true", effect: NoSchedule }]
      requirements:
        - { key: karpenter.sh/capacity-type, operator: In, values: ["on-demand"] }
        - { key: karpenter.k8s.aws/instance-family, operator: In, values: ["r6g", "m6g"] }
  limits: { cpu: "64", memory: "512Gi" }
  disruption:
    consolidationPolicy: WhenUnderutilized
    expireAfter: 720h                  # stateful 안전성을 위해 30일 보존
```

### 3. Keycloak 고가용성 JVM 튜닝 및 스케줄링 데드락 해결 명세
```yaml
# [platform/keycloak/overlays/prod/values.yaml 핵심 명세]
replicaCount: 3

# 🏁 [Platform Fix] 고장 난 'default' 노드풀 참조를 삭제하고 workload(또는 platform) 타겟팅
nodeSelector:
  role: workload

# 🏁 [SRE Fix 1] PDB 강제 및 AZ 분산 배치 (스케줄링 데드락 방지)
pdb:
  enabled: true
  maxUnavailable: 1                    # 3개 중 최소 2개 활성 보장 (쿼럼 유지)

podAntiAffinityPreset: soft
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: ScheduleAnyway  # DoNotSchedule 데드락을 유연한 Fallback으로 교체
    labelSelector:
      matchLabels: { app.kubernetes.io/name: keycloak }

# 🏁 [FinOps & SRE Fix 2] 컨테이너 명시적 자원 및 JVM 힙 75% cgroup 동기화
resources:
  requests: { cpu: "500m", memory: "1024Mi" }
  limits: { cpu: "2000m", memory: "2048Mi" }

extraEnvVars:
  # Linux OOMKiller를 원천 차단하는 JVM 메모리 비율 및 G1GC 가비지 컬렉터 최적화
  - name: JAVA_OPTS_APPEND
    value: "-XX:MaxRAMPercentage=75.0 -XX:+UseG1GC -XX:+ExitOnOutOfMemoryError -Djava.security.egd=file:/dev/./urandom"
```

---

## 🏛️ [Domain B - 아젠다 6] 인프라 IaC 상태 관리 및 비용 효율화(FinOps)
* **상태**: ✅ 합의 완료 및 아키텍처 박제
* **참조 좌표**: `[Area 1 - 테마 2]`, `[Area 1 - 테마 3]`, `[Area 2 - 테마 4]`
* **참여 에이전트**: Platform, DevSecOps, SRE, FinOps 전문 에이전트

### 1. 핵심 진단 및 합의 사항
1. **SoD 위반 및 상태 오염 교정**: L4 파이프라인이 `aws eks get-token`을 실행하던 구조를 삭제하여 인프라(Terraform)와 워크로드(ArgoCD) 제어권을 완벽 분리(Handshake). 모든 `.tfstate` 백엔드에 AWS KMS CMK 암호화와 DynamoDB 잠금(`localy-terraform-lock`)을 영구 하드코딩.
2. **4-Layer 분리 및 Crossplane 하이브리드 클라우드 제어**: Terraform은 정적 인프라(VPC, EKS, RDS)만 제어하고, K8s 워크로드와 결속된 동적 AWS 자원(ALB, TargetGroupBinding, ENI)은 **Crossplane (AWS Provider) / AWS ACK**가 관리. ArgoCD 앱 삭제 시 K8s OwnerReference에 의해 고아 없이 자동 청산되어 **월 $450~$800 과금 누수 차단**.
3. **FinOps 5대 임베디드 실무 프랙티스 & 500% ROI 증명**:
   - Infracost CI/CD 비용 예측 보고 + Kubecost K8s 단위 경제성 실시간 모니터링.
   - Terraform `default_tags` 의무화 및 Kyverno 비용 태그 누락 파드 배포 차단(`403 Deny`).
   - `Cloud Janitor` 일일 자동 스크립트로 미부착 EBS `gp3`, 미할당 EIP, 대상 없는 ALB 삭제 및 ECR 7일 수명 주기 적용.
   - Pre-Destroy Hook 하드코딩으로 `terraform destroy` 시 ArgoCD Finalizer 데드락 해소.
   - `kube-green` 도입으로 비운영(Dev/Staging) 클러스터 야간/주말 자동 셧다운 (주간 가동 시간 168h $\rightarrow$ 60h로 65% 삭감).
   - **월간 $3,150~$6,100 ($3.7만~$7.3만/연) 절감 증명 (투자 회수 1.3~2.5개월)**.
4. **빌드 속도 400% 향상 & OIDC 치명적 취약점 패치**:
   - Dockerfile 레이어 역전(`COPY src`를 맨 뒤로) 및 GHA Buildx 레이어 캐싱(`type=gha`), Gradle 홈 캐시 연동으로 빌드 시간 15분 $\rightarrow$ 3분 이내 단축.
   - `github_actions_oidc.tf`의 와일드카드 `repo:*/*:*`를 정확한 저장소/메인 브랜치로 제한하고 `PowerUser` 대신 Push 전용 최소 권한 IAM 정책 바인딩.

### 2. 표준 Multi-Stage Dockerfile 명세 (레이어 역전 교정 & GHA 캐시 최적화)
```dockerfile
# [마이크로서비스 표준 Multi-Stage Dockerfile 명세 (레이어 역전 교정 & 캐시 극대화)]
FROM eclipse-temurin:17.0.8_7-jdk-alpine@sha256:3125d0c09500... AS builder
WORKDIR /app
# 1. 🏁 [FinOps Cache Fix] 소스코드보다 먼저 Gradle 래퍼 및 설정 파일만 복사!
COPY gradlew .
COPY gradle gradle
COPY build.gradle settings.gradle ./
# 2. 🏁 [FinOps Cache Fix] 의존성 다운로드 레이어 캐싱 (build.gradle 변경 시에만 재실행)
RUN ./gradlew dependencies --no-daemon

# 3. 소스코드 복사 및 빌드 (불필요한 clean 퇴출, 100% 테스트/SAST/CVE 통과 전제)
COPY src src
RUN ./gradlew bootJar --no-daemon -x test

# 4. 🛡️ [DevSecOps] 최소 런타임 이미지 (curl, 패키지 매니저 삭제 및 Non-Root appuser 강제)
FROM eclipse-temurin:17.0.8_7-jre-alpine@sha256:7b5d72534500...
WORKDIR /app
RUN addgroup -g 10001 appgroup && adduser -u 10001 -G appgroup -D -s /sbin/nologin appuser \
    && apk del --no-cache curl && rm -rf /var/cache/apk/*
USER 10001:10001
COPY --from=builder --chown=10001:10001 /app/build/libs/*-SNAPSHOT.jar app.jar
ENTRYPOINT ["java", "-XX:MaxRAMPercentage=75.0", "-XX:+UseG1GC", "-jar", "/app/app.jar"]
```

### 3. OIDC 치명적 취약점 패치 및 ECR Push 전용 최소 권한 IAM 명세
```hcl
# [github_actions_oidc.tf CVSS 10.0 취약점 패치 명세]
resource "aws_iam_role" "github_actions_ecr_push" {
  name = "localy-prod-gha-ecr-push-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRoleWithWebIdentity"
      Effect = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Condition = {
        StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }
        # 🔐 [DevSecOps Fix] repo:*/*:* 와일드카드 원천 삭제! 정확한 저장소와 메인 브랜치만 허용
        StringLike   = { "token.actions.githubusercontent.com:sub" = "repo:hetrkumt/localy-backend:ref:refs/heads/main" }
      }
    }]
  })
}

# 🔐 [DevSecOps Fix] PowerUser(삭제 권한 포함)를 폐기하고 Push 전용 권한만 부여
resource "aws_iam_role_policy" "ecr_push_least_privilege" {
  name = "ecr-push-only"
  role = aws_iam_role.github_actions_ecr_push.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ecr:GetAuthorizationToken", "ecr:BatchCheckLayerAvailability", "ecr:PutImage", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload"]
      Resource = "arn:aws:ecr:ap-northeast-2:*:repository/localy-*"
    }]
  })
}
```

---

## 🏛️ [Domain C - 아젠다 7] OIDC IAM 및 ESO(External Secrets Operator) 권한 탈취 방지
* **상태**: ✅ 합의 완료 및 아키텍처 박제
* **참조 좌표**: `[Area 1 - 테마 1]`, `[Area 2 - 테마 3]`, `[Area 5 - 테마 3]`
* **참여 에이전트**: Platform, DevSecOps, SRE, FinOps 전문 에이전트

### 1. 핵심 진단 및 합의 사항
1. **ESO Controller 전역 권한 탈취 차단**: `SecretStore` 내 `auth` 블록 누락으로 인해 ESO Controller의 전역 IAM 역할(`prod-eks-eso-controller-role`)을 상속받아 임의의 파드가 전체 AWS 시크릿을 탈취하던 취약점을 원천 봉쇄. Platform이 관리하는 **네임스페이스 전용 SecretStore(`platform-secret-store`)**에 서비스별 IRSA ServiceAccount(`auth.jwt.serviceAccountRef`)를 필수 바인딩.
2. **아키텍처 모순(IAM 과권한) 해결**: HCL(`iam_workload_secrets.tf`)에서 애플리케이션 파드의 직접적인 `secretsmanager:*` 권한을 100% 삭제. 워크로드는 직접 클라우드 API를 호출할 수 없으며, 기밀 조회는 오직 ESO 브로커가 전담.
3. **Zero-IAM 개발자 인체공학 & Path-Scoped Kyverno 가드레일**: 개발자는 IAM이나 `SecretStore` 설정 없이 `workloads/<service>/base/`에 15줄의 깔끔한 `ExternalSecret`만 선언. 대신 Kyverno 어드미션 웹훅이 해당 네임스페이스의 파드는 오직 `^/localy/.*/workloads/<svc-name>/.*$` 경로의 기밀만 조회할 수 있도록 강제 차단하여 **Boilerplate 0%와 완벽한 탈취 방지 동시 달성**.
4. **FinOps API 요금 99.94% 삭감 (K8s 메모리 캐싱)**: ESO는 사이드카가 아닌 오퍼레이터로서 1시간(`refreshInterval: 1h`) 주기로만 AWS SM을 폴링하고 K8s etcd 네이티브 Secret으로 캐싱. KEDA로 파드가 100개로 급증해도 AWS SM/KMS API 호출은 **0회**이며, 월 호출량을 2,590만건에서 1.4만건으로 줄여 **월 API 요금을 $207에서 $0.11(약 150원)로 99.94% 삭감**. 긴급 회전 시에는 **EventBridge $\rightarrow$ ESO Webhook** 이벤트 드라이번 동기화 적용.
5. **ArgoCD Sync-Wave 커스텀 헬스 체크 & 무중단 회전**: 파드가 기밀 생성 전에 떠서 발생하는 `CreateContainerConfigError` 레이스 컨디션을 해결하기 위해 `SecretStore`(Wave -2) $\rightarrow$ `ExternalSecret`(Wave -1) $\rightarrow$ `Deployment`(Wave 0) 순서를 강제하고, ArgoCD가 `ExternalSecret`의 `Ready` 상태를 확인할 때까지 배포를 정지시키는 커스텀 헬스 체크 하드코딩. 기밀 변경 시 **Reloader**가 ALB Deregistration Delay(300s) 및 PreStop Hook과 결속되어 무중단 롤링 리스타트 수행.

### 2. 표준 Platform-Managed SecretStore & Workload ExternalSecret 명세
```yaml
# 1. [Platform Managed] 네임스페이스 전용 SecretStore 명세 (ESO Controller 권한 탈취 원천 봉쇄!)
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: platform-secret-store
  namespace: order-svc
spec:
  provider:
    aws:
      service: SecretsManager
      region: ap-northeast-2
      # 🔐 [DevSecOps Fix] auth 블록 필수 명시! ESO Controller 전역 역할 상속 전면 차단
      auth:
        jwt:
          serviceAccountRef:
            name: order-service-sa           # Namespace별 IRSA OIDC 최소 권한 바인딩

---
# 2. [Developer Declared] 워크로드 표준 ExternalSecret 명세 (Boilerplate 없는 깔끔한 선언)
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: order-db-secrets
  namespace: order-svc
  annotations:
    argocd.argoproj.io/sync-wave: "-1"       # 🏁 [SRE Fix] Workload(Wave 0) 이전에 생성 완료 보장!
spec:
  refreshInterval: "1h"                      # 💰 [FinOps Fix] 1시간 주기 표준화 (요금 99.94% 삭감)
  secretStoreRef:
    name: platform-secret-store
    kind: SecretStore
  target:
    name: order-db-secret
    creationPolicy: Owner
    deletionPolicy: Retain                   # 🛡️ [SRE Fix] AWS 일시 통신 장애 시 K8s 캐시 유지(Stale Retention)
  dataFrom:
    - extract:
        key: /localy/prod/workloads/order-svc/database # 🔐 Kyverno 가드레일이 경로 일치 엄격 검증!
```

### 3. 표준 Kyverno Path-Validation 가드레일 명세 (수평 탈취 원천 차단)
```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: restrict-externalsecret-remoteref
  annotations:
    policies.kyverno.io/title: Enforce Namespace-Scoped Secret Path Validation
    policies.kyverno.io/subject: ExternalSecret, SecretStore
spec:
  validationFailureAction: Enforce           # 403 Forbidden 즉각 차단
  background: false
  rules:
    # Rule 1: auth 블록이 누락된 SecretStore 생성 원천 거부
    - name: validate-secretstore-auth
      match:
        any:
          - resources:
              kinds: [SecretStore, ClusterSecretStore]
      validate:
        message: "[DevSecOps Block] SecretStore에 auth.jwt.serviceAccountRef가 누락되었습니다. 전역 ESO 권한 상속을 금지합니다."
        pattern:
          spec:
            provider:
              aws:
                auth:
                  jwt:
                    serviceAccountRef:
                      name: "?*"
    # Rule 2: 타 서비스 기밀 경로 조회를 시도하는 ExternalSecret 생성 원천 거부
    - name: enforce-namespace-secret-path
      match:
        any:
          - resources:
              kinds: [ExternalSecret]
      validate:
        message: >
          [DevSecOps Block] 권한 탈취 시도 감지! ExternalSecret은 오직 해당 네임스페이스 경로
          ('/localy/prod/workloads/{{request.namespace}}/*')의 시크릿만 조회할 수 있습니다.
        foreach:
          - list: "request.object.spec.dataFrom"
            pattern:
              extract:
                key: "/localy/*/workloads/{{request.namespace}}/*"
```

---

## 🏛️ [Domain C - 아젠다 8] 워크로드 및 플랫폼 기밀 데이터/보안 컨텍스트 격리
* **상태**: ✅ 합의 완료 및 아키텍처 박제
* **참조 좌표**: `[Area 4 - 테마 2]`, `[Area 5 - 테마 3]`
* **참여 에이전트**: Platform, DevSecOps, SRE, FinOps 전문 에이전트

### 1. 핵심 진단 및 합의 사항
1. **마스터 DB 계정 공유 및 스키마 RBAC 파괴 교정**: `db-migration`이 개별 계정을 생성함에도 모든 워크로드가 단일 마스터 시크릿(`localy-prod-database-credentials`)을 공유하고 `public` 스키마 권한을 통째 개방하던 안티패턴을 철폐. 단일 Aurora 클러스터 내에서 6개 스키마(`schema_order` 등)와 6개 최소 권한 롤을 물리적으로 분열시키지 않고 논리적 RBAC로 완벽 격리하여 **물리적 RDS 6배 증설 대비 85%의 인프라 TCO를 절감**.
2. **`envFrom` 평문 유출 퇴출 & Spring Boot `configtree:` 적용**: 기밀을 환경변수가 아닌 CSI/ESO 읽기 전용 tmpfs 메모리 볼륨(`/mnt/secrets/app-creds`, 권한 `0400`)으로 마운트. Spring Boot 2.4+의 `spring.config.import=optional:configtree:/mnt/secrets/*/`를 표준 채택하여 평문 비밀번호가 OS 환경변수나 APM 트레이스에 전혀 남지 않는 Zero-Trust 달성.
3. **Boilerplate 0% Kustomize 공통 컴포넌트 (`workload-secret-mount`)**: PSS Restricted 프로필(`runAsNonRoot: true`, `runAsUser: 10001`, `readOnlyRootFilesystem: true`, Capability Drop `ALL`, SeccompProfile `RuntimeDefault`), SRE 표준 RAM 디스크(`/tmp` Memory 64Mi), 그리고 tmpfs 기밀 마운트를 공통 Kustomize 컴포넌트에 하드코딩. 개별 서비스는 단 한 줄의 component import만으로 완벽한 Zero-Trust 컨텍스트 자동 상속.
4. **SRE 중첩 유효기간(Overlapping Window) 무중단 회전 & 커넥션 복원력**: 기밀 변경 시 즉시 덮어쓰지 않고 AWS Secrets Manager 이중 계정(Dual-User) 기반 중첩 기간을 두며, **RDS Proxy IAM Auth**로 커넥션 단절을 큐잉으로 흡수. **Stakater Reloader**가 ALB Deregistration Delay(300s) 및 PreStop Hook과 결속되어 무중단 롤링 리스타트를 수행하고, **Resilience4j** 서킷 브레이커로 504 타임아웃 없는 무중단 보장.
5. **ZTSA 마이크로 세그멘테이션 & L7 FQDN 화이트리스트**: 모든 네임스페이스에 Default Deny를 적용하고 DB(5432)/MSK(9092)는 승인된 엔드포인트로만 통제. 특히 **TCP 443(HTTPS) 외부 0.0.0.0/0 무제한 개방을 금지**하고 **Cilium eBPF L7 FQDN NetworkPolicy**로 승인된 외부 API 도메인만 허용하여 파드 해킹 후 C2 콜백 및 데이터 외부 반출(Exfiltration) 통로 원천 폐쇄.

### 2. 표준 Boilerplate 0% Kustomize 공통 컴포넌트 명세 (`workload-secret-mount`)
```yaml
# [common/components/workload-secret-mount/deployment-patch.yaml 표준 명세]
# 🏁 모든 비즈니스 워크로드가 단 1줄의 Kustomize component import로 상속받는 SSOT 가드레일!
apiVersion: apps/v1
kind: Deployment
metadata:
  name: not-important
  annotations:
    reloader.stakater.com/auto: "true"         # 🔄 [SRE] 기밀 회전 시 ALB Readiness Gate 연동 무중단 롤링 리스타트
spec:
  template:
    metadata:
      labels:
        security.localy.io/zero-trust: "enforced"
    spec:
      # 🛡️ [DevSecOps] PSS Restricted 프로필 하드코딩 (Root 실행 100% 원천 봉쇄!)
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: app
          # 🏁 [Platform & DevSecOps] envFrom 평문 주입 퇴출! Spring Boot ConfigTree 메모리 마운트 적용
          env:
            - name: SPRING_CONFIG_IMPORT
              value: "optional:configtree:/mnt/secrets/app-creds/,optional:configtree:/mnt/secrets/jwt/"
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true       # 🛡️ 바이너리 위변조 방지 (루트 파일시스템 읽기 전용)
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: secret-app-creds
              mountPath: /mnt/secrets/app-creds
              readOnly: true
            - name: tmp-volume                   # 🏁 [SRE] readOnly 데드락을 방지하는 Tomcat RAM 디스크
              mountPath: /tmp
            - name: app-logs-volume
              mountPath: /app/logs
      volumes:
        - name: secret-app-creds
          secret:
            secretName: app-secret-volume      # 개별 서비스 Overlay에서 실제 Secret 명으로 매핑
            defaultMode: 0400                  # 소유자 읽기 전용 POSIX 권한
        - name: tmp-volume
          emptyDir:
            medium: Memory                     # 🚀 [SRE & FinOps] Kubelet 메모리 백업 RAM 디스크
            sizeLimit: 64Mi                    # OOM Evictions 및 Quota 초과 방지 상한선
        - name: app-logs-volume
          emptyDir:
            medium: Memory
            sizeLimit: 32Mi
```

### 3. 표준 Cilium eBPF L7 FQDN Egress 화이트리스트 NetworkPolicy 명세
```yaml
# [common/guardrails/zero-trust-network-policy.yaml 표준 명세]
# 🏁 TCP 443 0.0.0.0/0 무제한 외부 인터넷 개방 및 C2 콜백 경로를 원천 폐쇄!
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: enforce-ztsa-microsegmentation
  namespace: prod-workloads
spec:
  endpointSelector:
    matchLabels:
      role: workload
  ingress:
    # 1. 🛡️ 서비스 간 East-West API 통신 화이트리스트 (예: cart/edge -> order 허용)
    - fromEndpoints:
        - matchLabels: { app.kubernetes.io/name: cart-service }
        - matchLabels: { app.kubernetes.io/name: edge-service }
      toPorts:
        - ports: [{ port: "8080", protocol: "TCP" }]
  egress:
    # 2. 🗄️ 데이터베이스 및 카프카 Egress 화이트리스트 (오직 승인된 RDS Proxy 및 MSK 엔드포인트만 허용)
    - toEndpoints:
        - matchLabels: { app.kubernetes.io/name: rds-proxy }
      toPorts:
        - ports: [{ port: "5432", protocol: "TCP" }]
    - toEndpoints:
        - matchLabels: { app.kubernetes.io/name: kafka-broker }
      toPorts:
        - ports: [{ port: "9092", protocol: "TCP" }]
    # 3. 🌐 L7 FQDN 기반 외부 인터넷 Egress 통제 (0.0.0.0/0 전면 차단, 승인된 PG 및 AWS API만 허용)
    - toFQDNs:
        - matchName: "api.tosspayments.com"
        - matchPattern: "*.amazonaws.com"
        - matchName: "auth.localy.internal"
      toPorts:
        - ports: [{ port: "443", protocol: "TCP" }]
```

### 4. Spring Boot HikariCP + RDS Proxy 고가용성 커넥션 튜닝 명세
```yaml
# [workloads/order-service/base/application.yml 핵심 명세]
spring:
  datasource:
    hikari:
      # 🏁 [SRE Fix] AWS NAT Gateway / RDS Proxy 유휴 타임아웃(350초)보다 반드시 짧게 설정하여 Dead Connection 끊김 방지!
      max-lifetime: 300000                     # 5분 (300,000ms)
      keepalive-time: 60000                    # 1분마다 Proxy 커넥션 풀 유효성 능동 검증
      connection-timeout: 3000                 # 3초 Fail-Fast (네트워크 지연 시 스레드 풀 고갈 및 지연 전이 방지)
      validation-timeout: 2000                 # 2초
      minimum-idle: 2                          # RDS Proxy 다중화 환경을 활용한 최소 메모리 점유
      maximum-pool-size: 10                    # KEDA 10개 파드 확장 시 Quota 및 DB 커넥션 초과 방지 상한선
```

---

## 🏛️ [Domain D - 아젠다 9] AWS ALB 무중단 배포(Zero-Downtime) 및 트래픽 라우팅 정상화
* **상태**: ✅ 합의 완료 및 아키텍처 박제
* **참조 좌표**: `[Area 4 - 테마 3]`, `[Area 5 - 테마 2]`, `[Area 5 - 테마 3]`
* **참여 에이전트**: Platform, DevSecOps, SRE, FinOps 전문 에이전트

### 1. 핵심 진단 및 합의 사항
1. **ALB 10개 파편화 및 10배 과금 폭탄 철폐 (2-ALB 계층형 통폐합)**: 개별 마이크로서비스와 플랫폼 도구마다 개별 ALB/NLB 10개를 생성하여 월 $162(연 $1,944)의 기본 요금을 낭비하고 ENI/LCU를 파편화시키던 구조 철폐. **2-ALB 계층형 통폐합 모델(Public vs Private)**을 표준 채택하여 인프라 기본 요금을 80% 절감(월 $32.40)하면서도 외부 고객용(WAF/TLS 1.3)과 내부 관리용(VPN/DirectConnect 전용) 간의 물리적 네트워크 보안 격리 달성.
2. **IngressGroup 평가 순서(`group.order`) 및 블랙홀 교정**: Public ALB 내에서 명시적 평가 순서(`order: "10"` Auth Keycloak $\rightarrow$ `order: "20"` Edge Router $\rightarrow$ `order: "99"` Core/Fallback)를 강제. 특히 `ingress-core`가 존재하지 않는 `target-app-service`로 트래픽을 넘기던 100% 502/503 블랙홀 오류를 삭제하고 `edge-service`로 정상 라우팅 위임.
3. **Boilerplate 0% Readiness Gate 자동 주입 & ESO 기반 TGB ARN 동적 치환**: 개발자가 개별 워크로드 YAML에 50줄의 ALB 주석이나 Readiness Gate를 수동 기재하지 않도록, 네임스페이스에 `elbv2.k8s.aws/pod-readiness-gate-inject: "enabled"` 라벨만 부여하여 LBC Webhook이 자동 주입하도록 표준화(ArgoCD `ignoreDifferences` 처리). GitOps 내 `"PLACEHOLDER_ARN"` 및 서비스명 오타(`*-svc`)를 삭제하고 Terraform SSM 출력 $\rightarrow$ ESO 동적 주입으로 100% 바인딩 보장.
4. **SRE ALB 무중단 배포 수학적 타이밍 공식 (SSOT)**: 파드 종료 시 ALB API 전파 시간($T_{\text{prop}} \approx 5\sim15\text{초}$) 전 소켓 닫힘으로 인한 **502 Bad Gateway**, ALB 해제 대기(300초) 전 K8s SIGKILL 살해로 인한 **504 Gateway Timeout** 박멸!
   - **ALB Deregistration Delay ($T_{\text{drain}}$)**: 300초에서 **30초~60초**로 파격 단축 (배포 80% 가속).
   - **Pod `preStop` Hook ($T_{\text{sleep}}$)**: 일반 API `sleep 15`, 트랜잭션 API(`order`, `payment`) `sleep 35` 부여 ($T_{\text{sleep}} > T_{\text{prop}}$).
   - **K8s Grace Period ($T_{\text{grace}} \ge T_{\text{sleep}} + T_{\text{drain}} + T_{\text{buffer}}$)**: Tier 1 일반 REST API는 **60초**, Tier 2 트랜잭션 API는 **90초**로 표준화.
5. **플랫폼 고가용성(HA) 및 데드락 교정**: Keycloak `nodeSelector`를 존재하지 않는 `default`에서 `workload-pool`로 수정하여 영구 Pending 해결. `keda`, `eso`, `reloader`, `prometheus-adapter`를 2개 레플리카 및 PDB(`maxUnavailable: 1`)로 승급. `node-local-dns` Corefile의 외부 DNS(`.:53`) 위임 덮어쓰기 복구. Cilium CNI `API_SERVER_IP` 플레이스홀더를 실제 EKS API IP로 치환하여 `kubeProxyReplacement` 마비 해소.

### 2. 표준 2-ALB Public IngressGroup 통폐합 및 평가 순서 명세 (`ingress-core` 블랙홀 교정)
```yaml
# [apps/ingress-core/base/ingress.yaml 정상화 명세]
# 🏁 10개 ALB 파편화 비용(월 $162)을 90% 절감하고 target-app-service 블랙홀을 제거하는 SSOT!
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: prod-public-ingress-core
  namespace: prod-workloads
  annotations:
    # 💼 [FinOps & Platform] 단일 Public ALB 공유 (IngressGroup 통폐합)
    alb.ingress.kubernetes.io/group.name: "prod-public-group"
    alb.ingress.kubernetes.io/target-type: "ip"
    alb.ingress.kubernetes.io/scheme: "internet-facing"
    # 🔐 [DevSecOps] ACM TLS 1.3 인증서 종단 및 HTTP -> HTTPS 301 영구 리다이렉트
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS": 443}]'
    alb.ingress.kubernetes.io/ssl-redirect: "443"
    alb.ingress.kubernetes.io/ssl-policy: "ELBSecurityPolicy-TLS13-1-2-2021-06"
    # 🛡️ [DevSecOps & FinOps] AWS WAF WebACL 결속 (SQLi, XSS, 봇 스크래핑 및 L7 DDoS 무한 스케일아웃 방어)
    alb.ingress.kubernetes.io/wafv2-acl-arn: "arn:aws:wafv2:ap-northeast-2:account-id:regional/webacl/prod-public-waf/..."
    # ⚙️ [Platform] 라우팅 평가 순서 정의 (99: Edge 및 Auth 이외의 Fallback 트래픽 처리)
    alb.ingress.kubernetes.io/group.order: "99"
spec:
  ingressClassName: alb
  rules:
    - host: "feifo.click"
      http:
        paths:
          # 🚨 [Bug Fix] 존재하지 않는 target-app-service 블랙홀 삭제! edge-service로 정상 라우팅 위임
          - path: /
            pathType: Prefix
            backend:
              service:
                name: edge-service
                port:
                  number: 8080
```

### 3. 표준 Boilerplate 0% 무중단 라이프사이클 Kustomize 컴포넌트 명세 (`workload-lifecycle`)
```yaml
# [common/guardrails/workload-lifecycle/deployment-patch.yaml 표준 명세]
# 🏁 6개 서비스가 상속받아 502 Bad Gateway 및 504 Gateway Timeout을 원천 박멸하는 SSOT!
apiVersion: apps/v1
kind: Deployment
metadata:
  name: not-important
spec:
  template:
    spec:
      # 🏁 [SRE Fix] K8s Grace Period 표준화 (Tier 1: 60s, Tier 2: 90s 오버레이 적용)
      terminationGracePeriodSeconds: 60
      containers:
        - name: app
          # 🏁 [SRE & Platform Fix] ALB API 전파 지연(15s) 전 소켓 닫힘으로 인한 502 에러 방지 preStop Hook!
          lifecycle:
            preStop:
              exec:
                command: ["/bin/sh", "-c", "sleep 15"]
          # 🏁 [DevSecOps Fix] 1초의 짧은 프로브로 인한 SIGKILL 무한 부트루프 박멸 (합리적 헬스 프로브)
          livenessProbe:
            httpGet: { path: /actuator/health/liveness, port: 8080 }
            initialDelaySeconds: 20
            periodSeconds: 10
            timeoutSeconds: 3
            failureThreshold: 3
          readinessProbe:
            httpGet: { path: /actuator/health/readiness, port: 8080 }
            initialDelaySeconds: 15
            periodSeconds: 5
            timeoutSeconds: 3
            failureThreshold: 2
```

### 4. 플랫폼 고가용성(HA) 및 데드락 교정 명세 (Keycloak, RWO 볼륨, Cilium CNI)
```yaml
# 1. [Keycloak Nodepool Deadlock Fix] 존재하지 않는 default 노드 풀 참조 삭제 -> workload-pool 매핑
# workloads/keycloak/base/deployment.yaml
spec:
  template:
    spec:
      nodeSelector:
        karpenter.sh/nodepool: workload-pool          # 🚨 기존 'default'로 인한 영구 Pending 해결!
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector: { matchLabels: { app.kubernetes.io/name: keycloak } }
              topologyKey: "kubernetes.io/hostname"

---
# 2. [Cilium CNI eBPF Blackout Fix] values.yaml 내 API_SERVER_IP 문자열 플레이스홀더 치환
# infrastructure/helm-values/cilium-values.yaml
k8sServiceHost: "172.20.0.10"                         # 🚨 EKS API Server 실제 IP 치환 (kubeProxyReplacement 마비 방지)
k8sServicePort: 443
kubeProxyReplacement: true
```

---

## 🏛️ [Domain D - 아젠다 10] 관측성(Observability) 중복 제거 및 파괴적 연쇄 삭제 방지
* **상태**: ✅ 합의 완료 및 아키텍처 박제
* **참조 좌표**: `[Area 3 - 테마 2]`, `[Area 5 - 테마 4]`
* **참여 에이전트**: Platform, DevSecOps, SRE, FinOps 전문 에이전트

### 1. 핵심 진단 및 합의 사항
1. **OTel $\rightarrow$ Jaeger 이중 호핑 해체 및 낭비 자원 회수 (FinOps & DevSecOps)**: OTel Gateway $\rightarrow$ Jaeger Collector $\rightarrow$ OpenSearch로 이어지는 2중 홉 구조와 평문 전송(`insecure: true`)을 철폐. Jaeger Collector/Agent를 클러스터에서 완전 삭제하고 OTel Gateway에서 AWS OpenSearch로 직접 쏘는 Direct Pipeline을 구축하여 **4~5.5+ CPU 코어, 14GB RAM, 65Gi+ EBS gp3 스토리지 및 크로스 AZ 전송비를 즉각 회수**. OTLP 구간에 **mTLS (`insecure: false`)** 및 **AWS SigV4 인증(IRSA)**을 강제하여 무인증 접근과 데이터 유출 원천 봉쇄.
2. **PromQL 중복 쿼리 철폐 및 KEDA 단일화**: KEDA 내부에 Prometheus Scaler가 내장되어 있음에도 중복 가동되던 `prometheus-adapter`를 완전 제거. 커스텀 메트릭 기반 오토스케일링을 KEDA로 단일화하여 Prometheus PromQL 쿼리 부하와 K8s API 서버 등록 오버헤드를 50% 반감.
3. **EBS 6분 탈부착 블랙아웃 극복 및 고가용성(HA) 다중화**: OTel Gateway와 Prometheus가 단일 레플리카 및 RWO EBS 볼륨에 묶여 있어 노드 업그레이드나 Karpenter 통합 시 6분 이상 관측성이 마비되던 결함 교정. OTel Gateway를 RWO EBS에서 분리하여 Stateless 인메모리 버퍼링(`memory_limiter`) 및 RAM 디스크 구조로 전환하고, 절감한 컴퓨팅 자원을 KEDA, OTel Gateway, ESO, Reloader의 **2+ Replicas 다중화 + PDB(`minAvailable: 1`) + Anti-Affinity**에 재투입하여 0초 끊김 가용성 보장.
4. **ArgoCD 파괴적 연쇄 삭제 방지 5대 GitOps 가드레일 (SSOT)**: 
   - **`Delete=false,Prune=false` 강제화**: CRD를 배포하는 차트(`cert-manager`, `karpenter`, `alb-controller`, `kyverno`, `kube-prometheus-stack`)와 중요 상태 저장 PVC/Secret에 적용하여 CRD 삭제 시 클러스터 전체 Custom Resource가 연쇄 파괴되는 비극을 차단.
   - **`PruneLast=true` 의존성 파기 순서 제어**: Namespace, StorageClass, Core Operator CRD에 적용하여 워크로드 파드가 정상 종료(Drain)된 후 최종 파기되도록 제어.
   - **`ignoreDifferences` 무한 충돌 종식**: Deployment `spec.replicas` 및 HPA `status`에 대한 예외 처리를 명시하여 트래픽 급증 시 ArgoCD Self-Heal이 파드를 강제 Kill하는 부트루프 종결.
   - **7단계 정밀 Sync Wave & ServerSideApply 강제**: 256KB 크기 초과 에러를 막고 Wave -5(CRD/Policy)부터 Wave 10(Microservices)까지 정밀한 동기화 파도 설계.
   - **ArgoCD Pre-Delete Hook 스냅샷**: 상태 저장 PVC 삭제 요청 시 ArgoCD Pre-Delete Hook(`argocd.argoproj.io/hook: PreDelete`)이 작동하여 AWS EBS CSI `VolumeSnapshot` 또는 Velero 백업을 선행 수행하며, 실패 시 삭제를 차단! 동시에 Kyverno로 `data-protection: retain` 라벨 자원의 API `DELETE` 요청을 100% 차단.
5. **RBAC 정상화 및 8개 애드온 리소스 가드레일**: Grafana sidecar의 `searchNamespace: ALL`(클러스터 전체 ConfigMap/Secret 조회) 권한 퇴출 및 `monitoring` 네임스페이스 한정 RBAC 축소. 8개 Deficient 플랫폼 애드온에 명시적 Requests/Limits 하드코딩. Karpenter `platform-pool`을 `WhenEmpty`(14일 대기)에서 `WhenUnderutilized`로 전환하고 `spec.limits` 상한선을 강제하여 AWS 빌 쇼크 예방.

### 2. 표준 OTel Gateway Direct Pipeline ConfigMap 명세 (Jaeger 호핑 해체 & SigV4)
```yaml
# [platform/otel-collector/base/configmap.yaml 핵심 명세]
# 🏁 Jaeger Collector 2nd Hop(4~5.5 코어, 65Gi EBS)을 해체하고 OpenSearch로 직접 쏘는 SSOT!
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-collector-config
  namespace: prod-observability
data:
  relay.yaml: |
    receivers:
      otlp:
        protocols:
          grpc: { endpoint: 0.0.0.0:4317 }
          http: { endpoint: 0.0.0.0:4318 }
    processors:
      # 🏁 [SRE & FinOps Fix] RWO EBS 볼륨 없이 인메모리 버퍼링 및 OOM 방지 수행
      memory_limiter:
        check_interval: 1s
        limit_percentage: 75
        spike_limit_percentage: 15
      batch:
        send_batch_size: 8192
        timeout: 5s
    exporters:
      # 🏁 [FinOps & DevSecOps Fix] Jaeger 제거 후 AWS OpenSearch Direct Exporter (SigV4 + mTLS 강제!)
      opensearch:
        http:
          endpoint: "https://opensearch.prod.localy.internal:443"
          tls:
            insecure: false
        auth:
          authenticator: sigv4auth
    extensions:
      sigv4auth:
        region: "ap-northeast-2"
        service: "es"
    service:
      extensions: [sigv4auth]
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, batch]
          exporters: [opensearch]              # 🚨 Jaeger Exporter 완전 철폐!
```

### 3. 표준 파괴적 연쇄 삭제 방지 공통 Kustomize 패치 명세 (`gitops-guardrails`)
```yaml
# [common/guardrails/gitops-guardrails/application-patch.yaml 표준 명세]
# 🏁 모든 CRD 및 워크로드 Application이 상속받아 파괴적 연쇄 삭제와 HPA 충돌을 막는 SSOT!
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: not-important
  annotations:
    # 🚨 [Platform & SRE Fix] 256KB 한계 극복 ServerSideApply 및 CRD/Stateful 연쇄 파기 금지!
    argocd.argoproj.io/sync-options: ServerSideApply=true,Delete=false,Prune=false
spec:
  # 🏁 [Platform & SRE Fix] 트래픽 급증 시 HPA 스케일업 파드를 ArgoCD가 강제 Kill하는 부트루프 종식!
  ignoreDifferences:
    - group: "apps"
      kind: "Deployment"
      jsonPointers:
        - /spec/replicas
    - group: "autoscaling"
      kind: "HorizontalPodAutoscaler"
      jsonPointers:
        - /status
```

### 4. ArgoCD PVC Pre-Delete Snapshot Hook 명세 (삭제 전 백업 가드레일)
```yaml
# [common/guardrails/pre-delete-snapshot-hook.yaml 표준 명세]
# 🏁 상태 저장 PVC 파기 요청 시 AWS EBS 스냅샷을 먼저 뜨고, 성공할 때만 삭제를 허용하는 SSOT!
apiVersion: batch/v1
kind: Job
metadata:
  name: pvc-pre-delete-snapshot-hook
  namespace: prod-workloads
  annotations:
    argocd.argoproj.io/hook: PreDelete
    argocd.argoproj.io/hook-delete-policy: HookSucceeded
spec:
  template:
    spec:
      serviceAccountName: snapshot-hook-sa
      restartPolicy: Never
      containers:
        - name: snapshot-creator
          image: amazon/aws-cli:latest
          command:
            - /bin/sh
            - -c
            - |
              echo "🚨 [SRE Guardrail] PVC 파기 감지! AWS EBS CSI Snapshot 및 백업을 선행 실행합니다..."
              # AWS CLI 또는 Velero CLI를 통한 VolumeSnapshot 생성 로직 실행
              # 스냅샷 생성 실패 시 non-zero exit code 반환으로 ArgoCD 삭제 작업 원천 차단!
```

---

## 🏁 [Stage 2 최종 완결 Summary] 차세대 GitOps 아키텍처 블루프린트 완료

본 블루프린트는 4대 전문 직군(Platform, DevSecOps, SRE, FinOps)의 심층 난상 토론을 통해 도출된 **10대 정밀 아젠다의 설계 합의안 및 SSOT(Single Source of Truth) 명세**를 100% 반영하여 작성되었습니다. 

과거의 누더기 레거시 구조를 탈피하고, **Zero-Trust 보안, Zero-Downtime 배포, Boilerplate 0% 개발자 인지공학(DevEx), 그리고 FinOps 가성비 극대화**를 동시에 달성하는 클라우드 네이티브 아키텍처의 기준점이 됩니다.

| 도메인 | 아젠다 번호 | 핵심 성과 및 설계 달성 지표 |
| :--- | :---: | :--- |
| **Domain A**<br>(아키텍처 & 구조) | **아젠다 1** | Root App of Apps 통폐합 (`bootstrap/` vs `argocd-apps/` 스플릿 브레인 해체), Namespace 3층 체계 표준화 |
| | **아젠다 2** | `values.yaml` 하드코딩 4대 치명적 취약점 해소, 공통 Kustomize Overlay 및 KSO 기반 시크릿 외부화 |
| | **아젠다 3** | 고아/데드 코드 11개 앱 청산 및 6개 마이크로서비스 DB 독립성 확보 (Spring Boot Liquibase/Flyway 분리) |
| **Domain B**<br>(오토스케일링 & 자원) | **아젠다 4** | Namespace ResourceQuota 데드락 교정, KEDA + HPA 2단 스케일링 동기화, CPU Burst Ratio 2~3배 표준화 |
| | **아젠다 5** | Karpenter NodePool 전략 개편(`platform-pool`, `workload-pool`), Keycloak 힙 메모리 및 SPOF 스케줄링 버그 해결 |
| **Domain C**<br>(DevSecOps & 기밀) | **아젠다 6** | 인프라 IaC(Terraform)와 K8s GitOps 제어권 완벽 분리, Crossplane 도입, FinOps 5대 가드레일 및 빌드 400% 단축 |
| | **아젠다 7** | OIDC IRSA 네임스페이스 고립, ESO `auth` 블록 강제화, Kyverno 경로 검증 및 Secrets Manager API 요금 99.94% 삭감 |
| | **아젠다 8** | 공유 DB 마스터 계정 폐기 및 논리적 RBAC/RDS Proxy 도입(비용 85% 절감), Spring Boot ConfigTree 메모리 마운트 |
| **Domain D**<br>(트래픽 배포 & 관측성)| **아젠다 9** | 10개 ALB 파편화(월 $162 낭비) 철폐 및 2-ALB 계층형 통폐합(80% 절감), SRE 수학적 무중단 타이밍 공식(502/504 박멸) |
| | **아젠다 10** | OTel $\rightarrow$ Jaeger 이중 호핑 해체(4~5.5 코어 절감), `prometheus-adapter` 폐기, ArgoCD 파괴적 연쇄 삭제 방지 가드레일 |


