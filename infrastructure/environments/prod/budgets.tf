# ========================================================================
# AWS Budgets — FinOps Circuit Breakers
#   Phase 1: Loki 쿼리 비용 — 100% 시 S3 GetObject Deny
#   Phase 2: 알람 파이프라인 — 90% 시 sns:Publish Deny (MANUAL approval)
# ========================================================================

# ========================================================================
# Phase 1 — Loki IRSA S3 Read Circuit Breaker
# ========================================================================

data "aws_iam_policy_document" "loki_budget_circuit_breaker_deny" {
  statement {
    sid    = "CircuitBreakerDenyLokiS3GetObject"
    effect = "Deny"
    actions = [
      "s3:GetObject",
    ]
    resources = [
      "${aws_s3_bucket.loki_logs.arn}/*",
    ]
  }
}

resource "aws_iam_policy" "loki_budget_circuit_breaker_deny" {
  name        = "${var.env_name}-loki-budget-circuit-breaker-deny"
  description = "Budgets circuit breaker: deny Loki S3 GetObject when daily cost budget is exceeded"
  policy      = data.aws_iam_policy_document.loki_budget_circuit_breaker_deny.json

  tags = {
    Name        = "${var.env_name}-loki-budget-circuit-breaker-deny"
    Environment = var.env_name
    ManagedBy   = "terraform"
    Purpose     = "loki-budget-circuit-breaker"
  }
}

# ========================================================================
# Phase 2 — K8s Alarm Pipeline Hard Circuit Breaker (EDoS / Alarm Loop Guard)
# ========================================================================

data "aws_iam_policy_document" "alarm_pipeline_budget_circuit_breaker_deny" {
  statement {
    sid    = "CircuitBreakerDenyAlarmPipelineSnsPublish"
    effect = "Deny"
    actions = [
      "sns:Publish",
    ]
    resources = [
      local.alarm_pipeline_sns_topic_arn,
    ]
  }
}

resource "aws_iam_policy" "alarm_pipeline_budget_circuit_breaker_deny" {
  name        = "${var.env_name}-alarm-pipeline-budget-circuit-breaker-deny"
  description = "Budgets circuit breaker: deny SNS publish on alarm pipeline SNS role at 90% daily budget"
  policy      = data.aws_iam_policy_document.alarm_pipeline_budget_circuit_breaker_deny.json

  tags = {
    Name        = "${var.env_name}-alarm-pipeline-budget-circuit-breaker-deny"
    Environment = var.env_name
    ManagedBy   = "terraform"
    Purpose     = "alarm-pipeline-budget-circuit-breaker"
  }
}

# -------------------------------------------------------------------------
# Budgets Action Execution Role (Trust + IAM attach 권한 — Phase 1 + Phase 2 공용)
# -------------------------------------------------------------------------
data "aws_iam_policy_document" "budgets_action_execution_assume" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

data "aws_iam_policy_document" "budgets_action_execution_permissions" {
  statement {
    sid    = "AllowBudgetsApplyIamPolicyToTargetRoles"
    effect = "Allow"
    actions = [
      "iam:GetRole",
      "iam:ListAttachedRolePolicies",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:ListRolePolicies",
      "iam:GetRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
    ]
    resources = concat(
      [
        aws_iam_role.loki.arn,
        aws_iam_policy.loki_budget_circuit_breaker_deny.arn,
        aws_iam_policy.alarm_pipeline_budget_circuit_breaker_deny.arn,
      ],
      [
        aws_iam_role.alarm_pipeline_sns.arn,
      ],
    )
  }
}

resource "aws_iam_role" "budgets_action_execution" {
  name               = "${var.env_name}-budgets-action-execution-role"
  assume_role_policy = data.aws_iam_policy_document.budgets_action_execution_assume.json

  tags = {
    Name        = "${var.env_name}-budgets-action-execution-role"
    Environment = var.env_name
    ManagedBy   = "terraform"
    Purpose     = "aws-budgets-action-execution"
  }
}

resource "aws_iam_role_policy" "budgets_action_execution" {
  name   = "${var.env_name}-budgets-action-execution-policy"
  role   = aws_iam_role.budgets_action_execution.id
  policy = data.aws_iam_policy_document.budgets_action_execution_permissions.json
}

# -------------------------------------------------------------------------
# Phase 1 — Loki 태그 기반 월간 예산 + 100% Kill Switch
# -------------------------------------------------------------------------
resource "aws_budgets_budget" "loki_daily_cost" {
  name         = "${var.env_name}-loki-daily-cost-circuit-breaker"
  budget_type  = "COST"
  limit_amount = "1500"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = ["user:Purpose$loki-cold-storage"]
  }

  tags = {
    Name        = "${var.env_name}-loki-daily-cost-circuit-breaker"
    Environment = var.env_name
    ManagedBy   = "terraform"
    Purpose     = "loki-query-cost-circuit-breaker"
  }
}

resource "aws_budgets_budget_action" "loki_daily_cost_kill_switch" {
  budget_name        = aws_budgets_budget.loki_daily_cost.name
  action_type        = "APPLY_IAM_POLICY"
  approval_model     = "AUTOMATIC"
  notification_type  = "ACTUAL"
  execution_role_arn = aws_iam_role.budgets_action_execution.arn

  action_threshold {
    action_threshold_type  = "PERCENTAGE"
    action_threshold_value = 100
  }

  definition {
    iam_action_definition {
      policy_arn = aws_iam_policy.loki_budget_circuit_breaker_deny.arn
      roles      = [aws_iam_role.loki.name]
    }
  }

  subscriber {
    address           = "sre-alerts@company.com"
    subscription_type = "EMAIL"
  }

  depends_on = [
    aws_iam_role_policy.budgets_action_execution,
    aws_iam_role_policy.loki_s3,
  ]
}

# -------------------------------------------------------------------------
# Phase 2 — 일 $5 알람 파이프라인 태그 기반 예산 + 90% Kill Switch (MANUAL)
# -------------------------------------------------------------------------
resource "aws_budgets_budget" "alarm_pipeline_daily_cost" {
  name         = "${var.env_name}-alarm-pipeline-daily-cost-circuit-breaker"
  budget_type  = "COST"
  limit_amount = "5"
  limit_unit   = "USD"
  time_unit    = "DAILY"

  cost_filter {
    name = "TagKeyValue"
    values = [
      "user:Purpose$chatops-alarm-pipeline-ingress",
      "user:Purpose$chatops-alarm-pipeline",
      "user:Purpose$chatops-dispatch",
      "user:Purpose$chatops-jit-auth",
      "user:Purpose$chatops-alarm-forensic-vault",
      "user:Purpose$chatops-s3-encryption",
      "user:Purpose$chatops-alarm-lambda",
    ]
  }

  tags = {
    Name        = "${var.env_name}-alarm-pipeline-daily-cost-circuit-breaker"
    Environment = var.env_name
    ManagedBy   = "terraform"
    Purpose     = "alarm-pipeline-edos-circuit-breaker"
  }
}

resource "aws_budgets_budget_action" "alarm_pipeline_daily_cost_kill_switch" {
  budget_name        = aws_budgets_budget.alarm_pipeline_daily_cost.name
  action_type        = "APPLY_IAM_POLICY"
  approval_model     = "MANUAL"
  notification_type  = "ACTUAL"
  execution_role_arn = aws_iam_role.budgets_action_execution.arn

  action_threshold {
    action_threshold_type  = "PERCENTAGE"
    action_threshold_value = 90
  }

  definition {
    iam_action_definition {
      policy_arn = aws_iam_policy.alarm_pipeline_budget_circuit_breaker_deny.arn
      roles = [
        aws_iam_role.alarm_pipeline_sns.name,
      ]
    }
  }

  subscriber {
    address           = "sre-alerts@company.com"
    subscription_type = "EMAIL"
  }

  depends_on = [
    aws_iam_role_policy.budgets_action_execution,
    aws_iam_policy.alarm_pipeline_budget_circuit_breaker_deny,
    aws_iam_role_policy.alarm_pipeline_sns_publish,
  ]
}
