# AGENTS.md — Bring-up & Validation Phase

이 프로젝트는 현재 **인프라 bring-up + Next-Gen CI/CD 검증** 단계입니다.
(이전 아키텍처 설계 전용 Read-Only / No-Execution 제약은 해제됨.)

## 운영 규칙

1. **실행 허용:** `terraform plan|apply`, `kubectl`, `aws`, `gh` 등 검증에 필요한 명령을 실행할 수 있다.
2. **파괴적 작업:** `terraform destroy`, `kubectl delete` 대규모 삭제, force-push는 **사용자 명시 승인 후**에만.
3. **변경 범위:** bring-up blocker 수정(예: Cosign Audit `mutateDigest`, IRSA, parser)은 허용. 무관 대규모 리팩터는 하지 않는다.
4. **검증 순서:** Phase 0 → Batch A → B → C. 앞 배치 실패 시 다음으로 진행하지 않는다.
5. **학습 모드:** 오류 발생 시 원인 → 증거 → 수정 → 재검증을 짧게 설명하며 진행한다.
6. **문서:** ADR/계획 문서는 필요 시 갱신. Notion용 덤프 의무는 없다.

## 현재 목표

- Terraform 계층 복구: `l1-network` → `l2-eks` → `l3-app-integration` → `l4-bootstrap`
- Wave 1~5 code-ready 산출물 실측 (이미지 사슬 → Rollout/SLI → Guard)
- Tier 1 마감 후 Tier 2 (`topologySpread` + 기존 PDB 체감)

## 참고 역할 (설계 토론용, 현재는 보조)

플랫폼 / DevSecOps / SRE / FinOps 관점은 트레이드오프 설명에만 참고한다.
주 작업은 **배포·검증·blocker 수정**이다.
