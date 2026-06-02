resource "aws_eks_addon" "ebs_csi" {
  cluster_name = module.eks.cluster_name
  addon_name   = "aws-ebs-csi-driver"
  
  # [SRE 튜닝] EKS 클러스터 버전에 맞는 공식 안정화 버전을 장전합니다.
  addon_version = "v1.31.0-eksbuild.1" 

  # Task 1에서 생성한 KMS 암호화 해제 권한이 포함된 명품 신분증(Role)을 바인딩합니다.
  service_account_role_arn = module.eks.ebs_csi_role_arn

  # ---------------------------------------------------------------------
  # 1. 파괴적 동기화 (Single Source of Truth 강제)
  # ---------------------------------------------------------------------
  # 기존 클러스터 생성 시 깔려있던 구버전 찌꺼기나 콘솔 수동 변경(Drift)을 
  # IaC 코드가 무자비하게 덮어쓰도록(OVERWRITE) 강제하여 형상 관리를 정렬합니다.
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  # ---------------------------------------------------------------------
  # 2. SRE 레이스 컨디션(Race Condition) 방지 족쇄
  # ---------------------------------------------------------------------
  # IAM 권한(KMS 인라인 정책)이 AWS 글로벌 인프라망에 완전히 전파되기 전에 
  # 드라이버 파드가 먼저 기동되면 AccessDenied를 뱉으며 크래시가 발생합니다.
  # 이를 물리적으로 통제하기 위해 IAM 인라인 정책 생성이 완료된 후 애드온이 배포되도록 체이닝합니다.
  depends_on = [
    aws_iam_role_policy.ebs_csi_kms_inline
  ]

  tags = {
    Name        = "${module.eks.cluster_name}-ebs-csi-driver"
    Environment = "prod"
    Component   = "observability-infrastructure"
  }
}

resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"
  }
  
  storage_provisioner = "ebs.csi.aws.com"
  volume_binding_mode = "WaitForFirstConsumer"
  
  parameters = {
    type = "gp3"
  }
}