data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:${var.namespace}:${var.serviceaccount_name}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "explicit_deny" {
  statement {
    effect    = "Deny"
    actions   = ["iam:*", "sts:AssumeRole", "organizations:*", "billing:*"]
    resources = ["*"]
  }
}

data "aws_iam_policy_document" "merged" {
  source_policy_documents   = [var.custom_policy_json]
  override_policy_documents = [data.aws_iam_policy_document.explicit_deny.json]
}

resource "aws_iam_role" "this" {
  name               = var.role_name
  assume_role_policy = data.aws_iam_policy_document.trust.json
}

resource "aws_iam_policy" "this" {
  name   = "${var.role_name}-policy"
  policy = data.aws_iam_policy_document.merged.json
}

resource "aws_iam_role_policy_attachment" "this" {
  role       = aws_iam_role.this.name
  policy_arn = aws_iam_policy.this.arn
}
