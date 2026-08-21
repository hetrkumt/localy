# Wave 4 — ECR push / image scan → ChatOps SNS (Zero-CI-Secret feedback loop)

data "aws_iam_role" "alarm_pipeline_sns" {
  name = "${var.env_name}-k8s-alarm-pipeline-sns-role"
}

resource "aws_sns_topic_policy" "chatops_alarm_pipeline" {
  arn = aws_sns_topic.chatops_alarm_pipeline.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowAlertmanagerIrsaPublish"
        Effect = "Allow"
        Principal = {
          AWS = data.aws_iam_role.alarm_pipeline_sns.arn
        }
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.chatops_alarm_pipeline.arn
      },
      {
        Sid    = "AllowEventBridgePublish"
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.chatops_alarm_pipeline.arn
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = [
              aws_cloudwatch_event_rule.ecr_image_push.arn,
              aws_cloudwatch_event_rule.ecr_image_scan.arn,
            ]
          }
        }
      }
    ]
  })
}

resource "aws_cloudwatch_event_rule" "ecr_image_push" {
  name        = "${var.env_name}-ecr-image-push-chatops"
  description = "Wave 4: ECR image push → ChatOps SNS"

  event_pattern = jsonencode({
    source      = ["aws.ecr"]
    detail-type = ["ECR Image Action"]
    detail = {
      action-type = ["PUSH"]
      result      = ["SUCCESS"]
      repository-name = [
        "edge-service",
        "store-service",
        "cart-service",
        "order-service",
        "payment-service",
        "user-service",
      ]
    }
  })

  tags = {
    Name        = "${var.env_name}-ecr-image-push-chatops"
    Environment = var.env_name
    ManagedBy   = "terraform"
    Purpose     = "wave4-chatops"
  }
}

resource "aws_cloudwatch_event_target" "ecr_image_push_sns" {
  rule      = aws_cloudwatch_event_rule.ecr_image_push.name
  target_id = "chatops-sns"
  arn       = aws_sns_topic.chatops_alarm_pipeline.arn
}

resource "aws_cloudwatch_event_rule" "ecr_image_scan" {
  name        = "${var.env_name}-ecr-image-scan-chatops"
  description = "Wave 4: ECR image scan complete → ChatOps SNS"

  event_pattern = jsonencode({
    source      = ["aws.ecr"]
    detail-type = ["ECR Image Scan"]
    detail = {
      scanning-status = ["COMPLETE"]
      repository-name = [
        "edge-service",
        "store-service",
        "cart-service",
        "order-service",
        "payment-service",
        "user-service",
      ]
    }
  })

  tags = {
    Name        = "${var.env_name}-ecr-image-scan-chatops"
    Environment = var.env_name
    ManagedBy   = "terraform"
    Purpose     = "wave4-chatops"
  }
}

resource "aws_cloudwatch_event_target" "ecr_image_scan_sns" {
  rule      = aws_cloudwatch_event_rule.ecr_image_scan.name
  target_id = "chatops-sns"
  arn       = aws_sns_topic.chatops_alarm_pipeline.arn
}
