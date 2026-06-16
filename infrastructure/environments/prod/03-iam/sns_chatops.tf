# ========================================================================
# ChatOps Alarm Pipeline ??SNS Ingress Topic
#   Alertmanager IRSA ??sns:Publish ??Dispatch Lambda (lambda_chatops_dispatch.tf)
#   Topic name MUST match iam_alarm_pipeline.tf local.alarm_pipeline_sns_topic_name
#   (Budgets Deny / IRSA Publish / AlertmanagerConfig ARN ?뺥빀)
# ========================================================================

resource "aws_sns_topic" "chatops_alarm_pipeline" {
  name              = local.alarm_pipeline_sns_topic_name
  kms_master_key_id = "alias/aws/sns"

  tags = {
    Name        = local.alarm_pipeline_sns_topic_name
    Environment = module.global.env_name
    ManagedBy   = "terraform"
    Purpose     = "chatops-alarm-pipeline-ingress"
  }
}

# -------------------------------------------------------------------------
# Outputs ??Phase 5+ wiring / 寃利?# -------------------------------------------------------------------------
output "chatops_alarm_pipeline_sns_topic_arn" {
  description = "ChatOps alarm pipeline SNS topic ARN (Alertmanager publish target)"
  value       = aws_sns_topic.chatops_alarm_pipeline.arn
}

output "chatops_alarm_pipeline_sns_topic_name" {
  description = "ChatOps alarm pipeline SNS topic name"
  value       = aws_sns_topic.chatops_alarm_pipeline.name
}
