# ========================================================================
# 📡 EKS CLUSTER SPECIFICATION (Control Plane & System Node Group)
# ========================================================================
# 본 파일은 우리 인프라의 심장부인 EKS 클러스터와, 
# 카펜터 및 애드온들이 가동될 On-Demand 기반의 System 노드 그룹을 정의합니다.
# ========================================================================

# ==========================================
# 1. EKS Cluster (Control Plane)
# ==========================================
resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = "1.30" # EKS 최신 1.30 버전 적용

  vpc_config {
    subnet_ids              = var.subnet_ids
    security_group_ids      = [aws_security_group.cluster.id]
    endpoint_private_access = true # VPC 내부 통신 활성화
    endpoint_public_access  = true # 관리자 접속을 위한 퍼블릭 엔드포인트 활성화
    public_access_cidrs     = [var.admin_ip] # 내 로컬 PC IP만 허용
  }

  # [🚨 NEW 핫픽스] EKS Access Entry API 정식 활성화
  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP" # API와 ConfigMap 혼용 지원
    bootstrap_cluster_creator_admin_permissions = true                 # 창조주(terraform-admin) 마스터 권한 영구 보장
  }

  # 쿠버네티스 Secret 리소스를 KMS 키로 Envelope Encryption 합니다.
  encryption_config {
    provider {
      key_arn = aws_kms_key.eks_secrets.arn
    }
    resources = ["secrets"]
  }

  depends_on = [
    aws_iam_role_policy_attachment.cluster_policy
  ]

  tags = {
    Name                     = var.cluster_name
    "karpenter.sh/discovery" = var.cluster_name
  }
}

# ==========================================
# 2. EKS Managed Node Group (System Nodes)
# ==========================================
resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.cluster_name}-system-nodes"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.subnet_ids

  version        = "1.30"
  ami_type       = "AL2_x86_64"
  instance_types = ["t3.medium"]
  capacity_type  = "ON_DEMAND" # 안정성을 위해 On-Demand 고정

  labels = {
    "role" = "system"
  }

  scaling_config {
    desired_size = 2 # Karpenter 및 애드온 가동 버퍼 확보를 위해 2대 HA 구성
    max_size     = 3
    min_size     = 2
  }

  update_config {
    max_unavailable = 1
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker_policy,
    aws_iam_role_policy_attachment.node_cni_policy,
    aws_iam_role_policy_attachment.node_ecr_policy,
  ]

  tags = {
    Name                     = "${var.cluster_name}-system-node"
    "karpenter.sh/discovery" = var.cluster_name
  }
}
