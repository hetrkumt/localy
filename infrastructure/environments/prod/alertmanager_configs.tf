# =============================================================================
# [Phase 3] Alarm Pipeline — AlertmanagerConfig (Thin TF / Fat YAML)
# [Phase 6] SNS Decoupling — __JIT_CTX__ payload → Dispatch Lambda
# SNS Topic ARN: aws_sns_topic.chatops_alarm_pipeline (sns_chatops.tf)
# IRSA: Alertmanager Pod SA → aws_iam_role.alarm_pipeline_sns (Helm 결속 완료)
# =============================================================================

resource "kubectl_manifest" "alertmanager_config_alarm_pipeline" {
  yaml_body = templatefile("${path.module}/alertmanager-configs/alarm-pipeline.yaml", {
    sns_topic_arn = aws_sns_topic.chatops_alarm_pipeline.arn
    aws_region    = data.aws_region.alarm_pipeline.name
  })

  depends_on = [
    helm_release.kube_prometheus_stack,
    aws_sns_topic.chatops_alarm_pipeline,
  ]
}
