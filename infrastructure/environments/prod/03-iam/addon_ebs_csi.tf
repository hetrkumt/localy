resource "aws_eks_addon" "ebs_csi" {
  cluster_name = data.aws_ssm_parameter.cluster_name.value
  addon_name   = "aws-ebs-csi-driver"

  # [SRE ?쒕떇] EKS ?대윭?ㅽ꽣 踰꾩쟾??留욌뒗 怨듭떇 ?덉젙??踰꾩쟾???μ쟾?⑸땲??
  addon_version = "v1.31.0-eksbuild.1"

  # Task 1?먯꽌 ?앹꽦??KMS ?뷀샇???댁젣 沅뚰븳???ы븿??紐낇뭹 ?좊텇利?Role)??諛붿씤?⑺빀?덈떎.
  service_account_role_arn = data.aws_ssm_parameter.ebs_csi_role_arn.value

  # ---------------------------------------------------------------------
  # 1. ?뚭눼???숆린??(Single Source of Truth 媛뺤젣)
  # ---------------------------------------------------------------------
  # 湲곗〈 ?대윭?ㅽ꽣 ?앹꽦 ??源붾젮?덈뜕 援щ쾭??李뚭볼湲곕굹 肄섏넄 ?섎룞 蹂寃?Drift)??
  # IaC 肄붾뱶媛 臾댁옄鍮꾪븯寃???뼱?곕룄濡?OVERWRITE) 媛뺤젣?섏뿬 ?뺤긽 愿由щ? ?뺣젹?⑸땲??
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  # ---------------------------------------------------------------------
  # 2. SRE ?덉씠??而⑤뵒??Race Condition) 諛⑹? 議깆뇙
  # ---------------------------------------------------------------------
  # IAM 沅뚰븳(KMS ?몃씪???뺤콉)??AWS 湲濡쒕쾶 ?명봽?쇰쭩???꾩쟾???꾪뙆?섍린 ?꾩뿉 
  # ?쒕씪?대쾭 ?뚮뱶媛 癒쇱? 湲곕룞?섎㈃ AccessDenied瑜?諭됱쑝硫??щ옒?쒓? 諛쒖깮?⑸땲??
  # ?대? 臾쇰━?곸쑝濡??듭젣?섍린 ?꾪빐 IAM ?몃씪???뺤콉 ?앹꽦???꾨즺?????좊뱶?⑥씠 諛고룷?섎룄濡?泥댁씠?앺빀?덈떎.
  depends_on = [
    aws_iam_role_policy.ebs_csi_kms_inline
  ]

  tags = {
    Name        = "${data.aws_ssm_parameter.cluster_name.value}-ebs-csi-driver"
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
