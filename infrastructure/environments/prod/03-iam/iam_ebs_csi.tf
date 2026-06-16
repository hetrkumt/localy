# -------------------------------------------------------------------------
# EBS CSI KMS ?몃씪???뺤콉 (prod ?덉씠??
# IAM Role쨌OIDC trust쨌AmazonEBSCSIDriverPolicy??module.eks媛 ?⑥씪 ?뚯뒪濡?愿由ы빀?덈떎.
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
    resources = [data.aws_ssm_parameter.kms_key_arn.value]
  }
}

resource "aws_iam_role_policy" "ebs_csi_kms_inline" {
  name   = "${data.aws_ssm_parameter.cluster_name.value}-ebs-csi-kms-policy"
  role   = data.aws_ssm_parameter.ebs_csi_role_name.value
  policy = data.aws_iam_policy_document.ebs_csi_kms_policy.json
}
