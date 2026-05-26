# -------------------------------------------------------------------------
# EBS CSI KMS 인라인 정책 (prod 레이어)
# IAM Role·OIDC trust·AmazonEBSCSIDriverPolicy는 module.eks가 단일 소스로 관리합니다.
# -------------------------------------------------------------------------

data "aws_iam_policy_document" "ebs_csi_kms_policy" {
  statement {
    sid    = "AllowKMSDecryptForEBS"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKeyWithoutPlaintext",
      "kms:CreateGrant",
      "kms:DescribeKey",
      "kms:ReEncrypt*"
    ]
    resources = [module.eks.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "ebs_csi_kms_inline" {
  name   = "${module.eks.cluster_name}-ebs-csi-kms-policy"
  role   = module.eks.ebs_csi_role_name
  policy = data.aws_iam_policy_document.ebs_csi_kms_policy.json
}
