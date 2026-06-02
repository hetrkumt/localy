# ========================================================================
# AWS Budgets — Loki 쿼리 비용 서킷 브레이커 (일 $50 / 100% 시 S3 GetObject Deny)
# ========================================================================

# -------------------------------------------------------------------------
# 1) 서킷 브레이커 Deny 정책 — Loki IRSA Role에 Budgets가 부착
# -------------------------------------------------------------------------
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

# -------------------------------------------------------------------------
# 2) Budgets Action Execution Role (Trust + IAM attach 권한)
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
    sid    = "AllowBudgetsApplyIamPolicyToLokiRole"
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
    resources = [
      aws_iam_role.loki.arn,
      aws_iam_policy.loki_budget_circuit_breaker_deny.arn,
    ]
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
# 3) 일일 예산 ($50) — Loki Vault 태그 기반 비용 격리
# -------------------------------------------------------------------------
resource "aws_budgets_budget" "loki_daily_cost" {
  name         = "${var.env_name}-loki-daily-cost-circuit-breaker"
  budget_type  = "COST"
  limit_amount = "50"
  limit_unit   = "USD"
  time_unit    = "DAILY"

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

# -------------------------------------------------------------------------
# 4) 100% 도달 시 IAM 서킷 브레이커 (Fail-closed for reads)
# -------------------------------------------------------------------------
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
