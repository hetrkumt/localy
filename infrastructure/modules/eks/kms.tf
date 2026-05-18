# modules/eks/kms.tf

# 현재 테라폼을 실행하는 AWS 계정 정보를 동적으로 가져오기 위한 data 블록
data "aws_caller_identity" "current" {}

# ==========================================
# 1. AWS KMS Key 생성 (EKS Secret 암호화용)
# ==========================================
resource "aws_kms_key" "eks_secrets" {
  description             = "EKS Secret Encryption Key for ${var.cluster_name}"
  deletion_window_in_days = 7    # 실수로 키 삭제 시 복구 가능한 유예 기간 (7일)
  enable_key_rotation     = true # [엔터프라이즈 필수] 1년마다 자동으로 키의 알맹이(Backing key)를 교체

  # 리드 아키텍트의 지시: 유연하고 확장 가능한 Key Policy
  policy = jsonencode({
    Version = "2012-10-17"
    Id      = "eks-secret-encryption-policy"
    Statement = [
      {
        # 1. 계정 전체 권한 위임: 이 구문이 있어야 나중에 IAM Policy를 통해 RDS나 다른 서비스에도 이 키의 사용 권한을 나눠줄 수 있습니다.
        Sid    = "Enable IAM User Permissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        # 2. EKS Control Plane 전용 권한: EKS 머리(Cluster Role)가 이 키를 가지고 암호화/복호화를 할 수 있도록 허용합니다.
        Sid    = "Allow EKS Control Plane to use the key"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.cluster.arn
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
      }
    ]
  })

  tags = {
    Name = "${var.cluster_name}-kms-secrets"
  }
}

# ==========================================
# 2. KMS Alias (별칭) 부여
# ==========================================
# 복잡한 Key ID 대신 사람이 읽기 편한 가명을 붙여줍니다.
resource "aws_kms_alias" "eks_secrets" {
  name          = "alias/${var.cluster_name}-secrets"
  target_key_id = aws_kms_key.eks_secrets.key_id
}