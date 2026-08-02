# Next-Gen CI/CD — 구현 설계도 & 세부 작업서

> **SSOT for execution.** `next_gen_cicd_agendas.md`의 토론 합의를 **의존성 순서의 구현 웨이브**로 재편한 문서.  
> 구현 세션마다 이 문서를 기준으로 방향을 유지하고, 완료 시 체크박스를 갱신한다.

| 항목 | 값 |
|---|---|
| 원천 안건 | [`../next_gen_cicd_agendas.md`](../next_gen_cicd_agendas.md) |
| 작성일 | 2026-08-03 |
| 범위 | Theme 1~3 (딜리버리 핵심) 우선 · Theme 4/5/6은 후속 트랙 |
| 관련 회고 | PM-12 (ECR pin/SSOT), PM-13 (arch 계약), PM-14 (`ignoreDifferences`) |

---

## 0. 한 줄 목표

```text
커밋 → (테스트·스캔·서명) → ECR(sha 불변) → GitOps PR 승격 → Argo Sync
  → 카나리 5→20→50→100% → SLI 이탈 시 자동 롤백 → Slack 통보
```

지금 끊긴 곳은 **CI와 GitOps 매니페스트가 서로 다른 태그를 보는 배포 단절**이다.  
카나리·자동 롤백·Zero-Trust는 이 배관이 살아난 뒤에야 의미가 있다.

---

## 1. 현재 실측 상태 (2026-08-03 코드 기준)

| 안건 | 아젠다상 주장 | 실제 레포 상태 | 구현 시 취급 |
|---|---|---|---|
| Area 2-1 OIDC `localy-*` ARN | AccessDenied로 CI 100% 실패 | `github_actions_oidc.tf`가 `aws_ecr_repository.services` ARN 배열 사용 — **이미 교정됨** | Wave 0에서 검증만 (재작업 금지) |
| Area 2-2 ECR MUTABLE | 태그 덮어쓰기 가능 | `ecr.tf` `image_tag_mutability = "MUTABLE"` — **미착수** | Wave 1 |
| Area 1-1 / 4-1 `latest` ↔ `e2e*` 단절 | 배포 단절 | PM-12로 `image-pins.yaml` + pin/`latest` 이중 푸시 응급 정렬 — **임시 SSOT, SHA 자동 승격 아님** | Wave 1~2에서 pin → SHA 승격으로 진화 |
| Area 3-1 Argo Rollouts | 플랫폼 미등록 | 매니페스트 저장소 별도 — Wave 3에서 확인·편입 | Wave 3 |
| Theme 4/6 (OPA/WAF/Cilium/Spot 등) | 합의 설계 완료 | 딜리버리 핵심 경로와 직교 | Wave 5+ (별도 트랙) |

---

## 2. 아키텍처 흐름 (구현 후 목표)

```text
[localy-backend]
  push main / path-filtered service
       │
       ▼
  GHA: test → buildx(cache) → trivy → push sha-XXXX → cosign sign
       │
       ▼
  GHA: open PR on localy-manifests
       workloads/<svc>/overlays/prod  images.newTag = sha-XXXX
       │
       ▼
  (optional review) merge → ArgoCD Sync
       │
       ▼
  Rollout canary 5% → AnalysisTemplate(SLI) → 20% → 50% → 100%
       │ 실패 시 Abort/Rollback
       ▼
  EventBridge/Argo Notifications → SNS → ChatOps Lambda → Slack
```

**저장소 경계**

| 저장소 / 경로 | 역할 |
|---|---|
| `localy` (본 워크스페이스) `infrastructure/` | ECR, OIDC, EventBridge, SNS, Lambda, S3 cache |
| `localy-backend` | Dockerfile, Gradle, GHA `build-push-ecr.yml` |
| `localy-manifests` | Kustomize workloads, Argo apps, Kyverno, Rollouts, Prometheus rules |

> 이 워크스페이스에 인프라 TF만 있을 수 있다. Wave별로 **어느 저장소를 열지** 명시한다.

---

## 3. 웨이브 의존성 (반드시 이 순서)

```text
Wave 0  실측·갭 확인
   │
   ▼
Wave 1  공급망 기반 (ECR IMMUTABLE + SHA 태그 + 이미지명 표준)
   │
   ▼
Wave 2  CI↔GitOps 자동 승격 + Dockerfile/캐시/기본 스캔
   │
   ├──────────────┐
   ▼              ▼
Wave 3          Wave 4
카나리 엔진      관측·ChatOps
(Rollouts/ALB)  (SLI/Analysis/Slack)
   │              │
   └──────┬───────┘
          ▼
Wave 5  Zero-Trust 가드레일 강화 (Kyverno Cosign 강제 등)
          │
          ▼
Wave 6+ Theme 4/5 잔여 / Theme 6 스케일·Spot (병렬 가능)
```

**왜 이 순서인가**

1. IMMUTABLE + SHA 없이 Cosign/Kyverno를 켜면 기존 `latest`/`e2e*` 워크플로가 즉시 깨진다.
2. 자동 승격 없이 Rollouts만 넣으면 여전히 수동 태그 지옥이다.
3. AnalysisTemplate은 Rollouts + Prometheus recording rule이 있어야 동작한다.
4. Kyverno Cosign enforce는 “서명된 SHA 이미지가 안정적으로 들어오는” 이후에만 enforce 모드로 올린다.

---

## 4. Wave별 세부 작업

### Wave 0 — 실측 스냅샷 (½일)

**목적:** 아젠다와 코드 drift를 문서화하고, 구현 착수 범위를 확정.

| ID | 작업 | 저장소 | 완료 조건 |
|---|---|---|---|
| W0-1 | OIDC 롤 Assume + `ecr:PutImage` dry-run(또는 기존 GHA 로그) 확인 | `localy` TF / GHA | AccessDenied 없음 증거 확보 |
| W0-2 | 6개 ECR 리포 `mutability` / lifecycle / 최근 태그 샘플 | `localy` / AWS | 표로 기록 |
| W0-3 | `localy-manifests` prod overlay `images[].name/newTag` vs `image-pins.yaml` | manifests | 서비스별 매트릭스 |
| W0-4 | GHA workflow 실제 단계(test/scan/tag) 인벤토리 | backend | Wave 2 gap list |
| W0-5 | 플랫폼 카탈로그에 rollouts/notifications 존재 여부 | manifests | Wave 3 착수 여부 |

- [ ] Wave 0 완료

---

### Wave 1 — 공급망 기반 고정 (1~2일)  ← **첫 구현 추천**

**테마 매핑:** Theme 1 Action 1~2 · Area 2-1(검증) · Area 2-2 · Area 4-1(명칭)

| ID | 작업 | 파일 / 대상 | 완료 조건 |
|---|---|---|---|
| W1-1 | ECR `IMMUTABLE` 전환 | `l3-app-integration/ecr.tf` | 6 repo 모두 IMMUTABLE. **주의:** 기존 동일 태그 재푸시 워크플로가 있으면 먼저 SHA 태그로 바꿔야 함 → W1-3과 같은 PR 또는 직전 커밋 |
| W1-2 | 4단 Lifecycle Policy | `ecr.tf` (+ `aws_ecr_lifecycle_policy`) | untagged 7일 / `release`·`v*` 최신 50 / `sha-`·`pr-` 30일 / (필요 시) `latest` 예외 또는 `latest` 폐기 |
| W1-3 | 태그 계약 SSOT 문서화 | docs 또는 ADR 짧은 절 | 운영 태그 = `sha-<7~12>` only. `latest`는 디버그용 금지 또는 별도 mutable 디버그 리포만 |
| W1-4 | 이미지명 표준화 매트릭스 | manifests overlays + backend CI | 전부 `533003975005.dkr.ecr.ap-northeast-2.amazonaws.com/<svc>` |
| W1-5 | `e2e*` / pin 전략 이행 계획 | manifests `image-pins.yaml` | pin을 “마지막 성공 SHA”로 재정의하거나 승격 파이프가 pin을 갱신 |

**수용 기준 (Definition of Done)**

- [ ] Terraform apply 후 ECR IMMUTABLE
- [ ] 동일 SHA 재푸시 시도 시 거부(또는 digest 동일 시 허용 동작 문서화)
- [ ] 서비스별 이미지 레포/태그 규칙 표가 docs에 존재
- [ ] PM-12 pin 점검 스크립트가 새 계약과 모순되지 않음(갱신 또는 deprecate 명시)

**위험**

- IMMUTABLE을 켠 뒤 CI가 여전히 `latest`만 푸시하면 파이프라인 전면 실패 → **W1과 W2의 태그 변경은 한 배치로 묶는 것을 권장.**

---

### Wave 2 — CI 품질 + GitOps 자동 승격 (3~5일)

**테마 매핑:** Theme 1 Action 3 · Theme 5-1/5-2 핵심 · Area 1-1~1-3

| ID | 작업 | 저장소 | 완료 조건 |
|---|---|---|---|
| W2-1 | `dorny/paths-filter` + matrix (변경 서비스만 빌드) | backend GHA | 단일 서비스 변경 시 1개만 빌드 |
| W2-2 | `concurrency: cancel-in-progress` | backend GHA | 동일 ref 중복 런 취소 |
| W2-3 | Dockerfile: deps 레이어 분리 + `USER 1001` | 6× Dockerfile | 소스만 바꿔도 gradle deps 캐시 히트 |
| W2-4 | Buildx cache (`type=gha` 우선, 여유 시 S3/ECR registry cache) | GHA (+ 선택 TF S3) | 캐시 히트 로그 확인 |
| W2-5 | `gradle test` (또는 서비스별 최소 테스트) Fail-Fast | GHA | 테스트 실패 시 이미지 미푸시 |
| W2-6 | Trivy High/Critical Fail-Fast | GHA | 임계 CVE 시 job fail |
| W2-7 | Cosign keyless (OIDC) sign | GHA | 서명된 digest 확인 |
| W2-8 | 태그 = `sha-${{ github.sha }}` (short) 푸시 | GHA | ECR에 sha 태그 존재 |
| W2-9 | GitOps promotion: manifests PR로 `newTag` 갱신 | GHA → manifests | PR 본문에 서비스·SHA·ECR 링크 |
| W2-10 | Docker Hub/`build_and_push.sh` 폐기 또는 ECR-only로 리다이렉트 | backend scripts | Hub 푸시 경로 제거 |
| W2-11 | (선택) JaCoCo 80% / Sonar — Soft gate로 시작 | backend | PR에 리포트; Hard fail은 후속 |

**수용 기준**

- [ ] main 머지 → 변경 서비스만 빌드 → sha 태그 ECR → manifests PR 자동 생성
- [ ] PR 머지 후 Argo가 새 이미지로 Sync (1개 서비스 E2E)
- [ ] Trivy Critical 주입 테스트(또는 mock)로 파이프 중단 확인

**의도적 후순위 (Wave 2에서 빼는 것)**

- Sonar self-hosted 전체 구축, SBOM attestation 전부, Multi-arch ARM — Wave 6 / Theme 5·6에서.

---

### Wave 3 — Progressive Delivery 엔진 (4~6일)

**테마 매핑:** Theme 2 · Area 3-1~3-3 · Area 4-3 · Area 5-3

| ID | 작업 | 저장소 | 완료 조건 |
|---|---|---|---|
| W3-1 | Argo Rollouts HA (Sync Wave -5) 플랫폼 편입 | manifests | CRD + controller Ready |
| W3-2 | App `ignoreDifferences`에 `Rollout` `/spec/replicas` 선제 추가 | manifests | PM-14 원칙 유지(좁은 pointer) |
| W3-3 | `startupProbe` + readiness `periodSeconds ≤ 5` | workloads base | 카나리 파드 Ready 지연 측정 |
| W3-4 | Pilot: **order-service**만 `Deployment` → `Rollout` | manifests | canary steps 5→20→50→100 |
| W3-5 | ALB 카나리 라우팅 공통 컴포넌트 | `common/components/alb-canary-routing` | 개발자가 TGB를 직접 안 만짐 |
| W3-6 | Kyverno: probe / traffic-routing 가드레일 (Audit → Enforce) | kyverno policies | 위반 시 Audit 로그 먼저 |
| W3-7 | 나머지 5 서비스 Rollout 전환 (1서비스/PR) | manifests | 전부 Rollout |

**수용 기준**

- [ ] order-service 카나리 수동 검증(가중치 단계 관찰)
- [ ] KEDA(또는 HPA)와 replicas thrashing 없음
- [ ] pause 하드캡·scaleDownDelay 문서/정책 반영

**위험**

- Ingress가 단일 Service backend면 ALB 가중치가 안 먹음 → W3-5를 pilot과 같은 배치로.

---

### Wave 4 — SLI 자동 롤백 + ChatOps (3~5일)

**테마 매핑:** Theme 3 · Area 5-1~5-2 · Area 2-3 · Area 3-2

| ID | 작업 | 저장소 | 완료 조건 |
|---|---|---|---|
| W4-1 | Prometheus Recording Rules (`localy:http_error_rate…` 등) | manifests kps | 5s 주기 사전 집계 |
| W4-2 | HTTP 5xx / P95 알람 규칙 | `alarm-pipeline.yaml` | Blind release 해소 |
| W4-3 | `AnalysisTemplate` SSOT (success-rate + latency, count>50 가드) | `common/guardrails/` | Rollout analysis 참조 |
| W4-4 | Pilot Rollout에 analysis 연결 | order-service | 인위적 5xx로 자동 Abort |
| W4-5 | EventBridge → SNS → 기존 ChatOps Lambda (ECR push / scan) | `localy` TF | Slack 메시지 수신 |
| W4-6 | ArgoCD Notifications + ESO secret | manifests | Sync/Degraded/Rollout 이벤트 |
| W4-7 | Lambda concurrency=5, SNS topic policy 최소 권한 | TF | 스톰·과금 가드 |

**수용 기준**

- [ ] 카나리 중 에러율 임계 초과 → 자동 롤백 + Slack
- [ ] 저트래픽(요청 <50)에서 오탐 롤백 없음

---

### Wave 5 — Zero-Trust 가드레일 강화 (2~3일)

**테마 매핑:** Theme 1 Action 4 · Area 4-2

| ID | 작업 | 완료 조건 |
|---|---|---|
| W5-1 | Kyverno `restrict-image-registries` (ECR only) | Hub/`asfas244` 배포 거부 |
| W5-2 | `verify-cosign-signature` Audit 모드 배포 | 미서명 이미지 Audit |
| W5-3 | 전 서비스 서명 이미지 안정화 확인 후 Enforce | 미서명 배포 API 거부 |
| W5-4 | 레거시 `apply-phase1.ps1` 등 잔재 스크립트 제거/아카이브 | 문서에 대체 경로만 남김 |

---

### Wave 6+ — 후속 트랙 (딜리버리 안정화 이후)

병렬 가능. **딜리버리 핵심이 깨지면 즉시 중단하고 Wave 1~4 회귀.**

| 트랙 | 내용 | 원천 |
|---|---|---|
| 6A App/Edge 보안 | 중앙 OPA, WAF(L7 only)+Redis RL, JWT 다중검증+JWKS cache, Keycloak Operator | Theme 4-1 |
| 6B Infra 보안 | ESO EventBridge push, Reloader+HikariCP TTL, Cilium mTLS, cert-manager | Theme 4-2 |
| 6C CI 심화 | S3 remote cache, Sonar hard gate, CycloneDX SBOM on main, multi-arch | Theme 5-1/5-2 잔여 |
| 6D Scale/Cost | Warm pool pause, PDB/anti-affinity, Spot 80/20, Drift budget, AZ spread | Theme 6-1/6-2 |

각 트랙은 **별도 mini-plan**을 이 문서 하단에 링크하거나 섹션을 추가한다. 지금은 범위만 고정.

---

## 5. 세션 운영 규칙 (에이전트 + 사람)

1. **한 세션 = 한 Wave의 한 묶음(PR 단위).** 예: `W1-1+W1-2+W2-8`처럼 IMMUTABLE과 태그 계약을 같이.
2. **착수 전** 이 문서에서 해당 Wave 체크리스트를 읽고, 완료 후 체크.
3. **아젠다 문구와 코드가 다르면** 실측(Wave 0 표)을 우선하고, 아젠다 파일을 고치지 말고 이 계획의 “실측 상태”를 갱신.
4. **매니페스트/백엔드 저장소가 워크스페이스에 없으면** 사용자에게 해당 루트를 열거나 클론을 요청한 뒤 진행.
5. **프로덕션 적용(TF apply, Argo Sync, Kyverno Enforce)** 은 명시적 승인 후에만.

---

## 6. 추천 첫 구현 배치 (다음 대화에서 바로 착수)

**Batch A — “배포가 실제로 흐르게” (Wave 1 + Wave 2 최소)**

1. ECR IMMUTABLE + lifecycle (`localy` TF)
2. GHA: sha 태그 푸시 + paths-filter + concurrency
3. Dockerfile 캐시 분리 + Non-Root (서비스 1개 pilot → 6개)
4. manifests: newTag를 해당 sha로 갱신하는 promotion PR 스텝
5. order-service 한 번 E2E: commit → ECR → PR merge → Pod 이미지 확인

이 배치가 통과하면 Wave 3(카나리)로 넘어간다.

---

## 7. 진행 보드

| Wave | 상태 | 비고 |
|---|---|---|
| 0 실측 | ✅ done | 2026-08-03 · OIDC 기교정 확인 |
| 1 공급망 기반 | 🟡 code ready | `ecr.tf` IMMUTABLE+lifecycle 작성 · **TF apply 대기** |
| 2 CI+승격 | 🟡 code ready | GHA/Dockerfile/scripts/pins 문서 갱신 · **시크릿·머지·E2E 대기** |
| 3 카나리 | 🟡 code ready | order Rollout pilot · ALB template for edge · **클러스터 기동 후 검증** |
| 4 SLI+ChatOps | 🟡 code ready | Analysis+ECR EventBridge+Notifications · **클러스터/TF apply 후 검증** |
| 5 Kyverno enforce | 🟡 code ready | registry Enforce · Cosign Audit→Enforce cutover · legacy script retired |
| 6+ 후속 | ⬜ deferred | |

### Wave 1+2 코드 변경 요약 (2026-08-03)

| 저장소 | 변경 |
|---|---|
| `localy` | `ecr.tf` IMMUTABLE + lifecycle; `rebuild-ecr-image-pins.ps1` `-NewTag` / no `latest` |
| `localy-backend` | `build-push-ecr.yml` (paths-filter, concurrency, sha tag, Trivy, Cosign, promote PR); 6× Dockerfile cache+Non-Root; Hub 스크립트 폐기 |
| `localy-manifests` | `image-pins.yaml` 계약 문서만 갱신 (live pin 값은 승격 PR 전까지 `e2e*` 유지) |

### 게이트 (사람 승인 필요)

1. **`terraform apply`** on `l3-app-integration` (ECR IMMUTABLE) — 운영 레지스트리 속성 변경
2. **GitHub secret `LOCALY_MANIFESTS_TOKEN`** on `localy-backend` — manifests write + PR
3. 세 저장소 변경 커밋/푸시 후 `workflow_dispatch` 또는 main 푸시로 E2E 검증

### 의도적 완화

- `gradle test`: `@SpringBootTest`가 인프라 없이 실패 → **soft-gate** (`continue-on-error: true`). Hard-fail는 testcontainers/profile 이후.
- Lifecycle: 아젠다의 sha 30일 삭제 대신 **sha-* 최신 50개 유지** (롤백 창 보호).

---

## 8. 용어 빠른 참조

| 용어 | 의미 |
|---|---|
| Promotion | CI가 manifests의 이미지 태그를 올리는 PR/커밋 |
| Pin | PM-12의 응급 고정 태그; 최종적으로 SHA promotion으로 대체 |
| AnalysisTemplate | Rollouts가 Prometheus를 보고 진행/중단 결정 |
| IMMUTABLE | 같은 태그로 다른 digest 덮어쓰기 금지 |
