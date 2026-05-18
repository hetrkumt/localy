# ========================================================================
# Karpenter Spot Interruption Handling (SQS & EventBridge)
# ========================================================================

# 1. Karpenter가 이벤트를 읽어갈 SQS 대기열 (우체통) 생성
resource "aws_sqs_queue" "karpenter_interruption" {
  name                      = "${var.cluster_name}-karpenter-interruption-queue"
  message_retention_seconds = 300 # 이벤트 유효 시간 (5분). 스팟 중단은 즉각 대응해야 하므로 짧게 유지.
  sqs_managed_sse_enabled   = true

  tags = {
    Name = "${var.cluster_name}-karpenter-sqs"
  }
}

# 2. EventBridge가 SQS에 메시지를 보낼 수 있도록 허용하는 정책 (우체부 출입증)
data "aws_iam_policy_document" "karpenter_interruption_queue" {
  statement {
    sid    = "EventBridgeToSQS"
    effect = "Allow"
    actions = [
      "sqs:SendMessage"
    ]
    resources = [
      aws_sqs_queue.karpenter_interruption.arn
    ]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_sqs_queue_policy" "karpenter_interruption" {
  queue_url = aws_sqs_queue.karpenter_interruption.id
  policy    = data.aws_iam_policy_document.karpenter_interruption_queue.json
}

# ========================================================================
# 3. EventBridge 규칙 정의 (어떤 방송을 청취할 것인가?)
# ========================================================================

# Rule 1: 스팟 인스턴스 중단 2분 전 경고 (가장 중요)
resource "aws_cloudwatch_event_rule" "spot_interruption" {
  name        = "${var.cluster_name}-karpenter-spot-interruption"
  description = "EC2 Spot Instance Interruption Warning"
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Spot Instance Interruption Warning"]
  })
}

# Rule 2: EC2 인스턴스 리밸런스 권고 (스팟이 중단될 확률이 높아졌다는 사전 경고)
resource "aws_cloudwatch_event_rule" "rebalance_recommendation" {
  name        = "${var.cluster_name}-karpenter-rebalance"
  description = "EC2 Instance Rebalance Recommendation"
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance Rebalance Recommendation"]
  })
}

# Rule 3: EC2 인스턴스 상태 변경 (의도치 않게 Terminating / Stopping 상태로 갈 때)
resource "aws_cloudwatch_event_rule" "instance_state_change" {
  name        = "${var.cluster_name}-karpenter-state-change"
  description = "EC2 Instance State-change Notification"
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance State-change Notification"]
  })
}

# Rule 4: AWS Health 이벤트 (AWS 하드웨어 자체에 문제가 생겼을 때)
resource "aws_cloudwatch_event_rule" "aws_health_event" {
  name        = "${var.cluster_name}-karpenter-health-event"
  description = "AWS Health Event"
  event_pattern = jsonencode({
    source      = ["aws.health"]
    detail-type = ["AWS Health Event"]
  })
}

# ========================================================================
# 4. EventBridge 타겟 연결 (방송을 들으면 우체통(SQS)으로 전달)
# ========================================================================

resource "aws_cloudwatch_event_target" "spot_interruption" {
  rule      = aws_cloudwatch_event_rule.spot_interruption.name
  target_id = "KarpenterInterruptionQueueTarget"
  arn       = aws_sqs_queue.karpenter_interruption.arn
}

resource "aws_cloudwatch_event_target" "rebalance_recommendation" {
  rule      = aws_cloudwatch_event_rule.rebalance_recommendation.name
  target_id = "KarpenterInterruptionQueueTarget"
  arn       = aws_sqs_queue.karpenter_interruption.arn
}

resource "aws_cloudwatch_event_target" "instance_state_change" {
  rule      = aws_cloudwatch_event_rule.instance_state_change.name
  target_id = "KarpenterInterruptionQueueTarget"
  arn       = aws_sqs_queue.karpenter_interruption.arn
}

resource "aws_cloudwatch_event_target" "aws_health_event" {
  rule      = aws_cloudwatch_event_rule.aws_health_event.name
  target_id = "KarpenterInterruptionQueueTarget"
  arn       = aws_sqs_queue.karpenter_interruption.arn
}

