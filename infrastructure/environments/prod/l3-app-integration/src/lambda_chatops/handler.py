"""Wave 4 ChatOps dispatch — SNS (Alertmanager / EventBridge ECR) → Slack Block Kit."""

from __future__ import annotations

import json
import logging
import os
import urllib.error
import urllib.request
from typing import Any

import boto3

LOG = logging.getLogger()
LOG.setLevel(logging.INFO)

_sm = boto3.client("secretsmanager")
_s3 = boto3.client("s3")


def _slack_webhook_url() -> str:
    arn = os.environ["SLACK_WEBHOOK_SECRET_ARN"]
    resp = _sm.get_secret_value(SecretId=arn)
    secret = resp.get("SecretString") or ""
    # Support raw URL string or JSON {"webhook_url": "..."}
    try:
        parsed = json.loads(secret)
        if isinstance(parsed, dict):
            return parsed.get("webhook_url") or parsed.get("url") or secret
    except json.JSONDecodeError:
        pass
    return secret.strip()


def _post_slack(payload: dict[str, Any]) -> None:
    url = _slack_webhook_url()
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            LOG.info("slack status=%s", resp.status)
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        LOG.error("slack HTTPError %s: %s", exc.code, body)
        raise


def _maybe_forensic_dump(message: dict[str, Any]) -> None:
    bucket = os.environ.get("ALARM_DUMP_BUCKET_NAME")
    if not bucket:
        return
    key = f"forensic/chatops/{message.get('source', 'sns')}-{message.get('id', 'unknown')}.json"
    try:
        _s3.put_object(
            Bucket=bucket,
            Key=key,
            Body=json.dumps(message).encode("utf-8"),
            ContentType="application/json",
        )
    except Exception:  # noqa: BLE001 — dump must not fail the notify path
        LOG.exception("forensic dump failed")


def _from_alertmanager(body: dict[str, Any]) -> dict[str, Any]:
    alerts = body.get("alerts") or []
    status = body.get("status", "unknown")
    titles = []
    for a in alerts[:5]:
        labels = a.get("labels") or {}
        titles.append(
            f"*{labels.get('alertname', 'alert')}* "
            f"`{labels.get('severity', '')}` "
            f"{labels.get('namespace', '')}/{labels.get('pod', '')}"
        )
    text = "\n".join(titles) or json.dumps(body)[:1500]
    return {
        "text": f"Alertmanager ({status})",
        "blocks": [
            {
                "type": "header",
                "text": {"type": "plain_text", "text": f"Alertmanager — {status}"},
            },
            {"type": "section", "text": {"type": "mrkdwn", "text": text}},
        ],
    }


def _from_eventbridge_ecr(detail_type: str, detail: dict[str, Any]) -> dict[str, Any]:
    repo = detail.get("repository-name") or detail.get("repositoryName") or "?"
    tag = detail.get("image-tag") or detail.get("imageTag") or "untagged"
    if "Scan" in detail_type:
        findings = detail.get("finding-severity-counts") or detail.get("findingSeverityCounts") or {}
        high = findings.get("HIGH", findings.get("high", 0))
        critical = findings.get("CRITICAL", findings.get("critical", 0))
        return {
            "text": f"ECR scan {repo}:{tag}",
            "blocks": [
                {
                    "type": "header",
                    "text": {"type": "plain_text", "text": "ECR Image Scan"},
                },
                {
                    "type": "section",
                    "text": {
                        "type": "mrkdwn",
                        "text": (
                            f"*Repo:* `{repo}`\n*Tag:* `{tag}`\n"
                            f"*CRITICAL:* {critical}  *HIGH:* {high}"
                        ),
                    },
                },
            ],
        }
    return {
        "text": f"ECR push {repo}:{tag}",
        "blocks": [
            {
                "type": "header",
                "text": {"type": "plain_text", "text": "ECR Image Push"},
            },
            {
                "type": "section",
                "text": {
                    "type": "mrkdwn",
                    "text": f"*Repo:* `{repo}`\n*Tag:* `{tag}`\n*Action:* PUSH SUCCESS",
                },
            },
        ],
    }


def _build_payload(raw: str) -> dict[str, Any]:
    try:
        body = json.loads(raw)
    except json.JSONDecodeError:
        return {"text": raw[:2000]}

    # EventBridge → SNS envelope sometimes nests Message as JSON string already parsed
    if "detail-type" in body or "detail-type" in body.get("detail", {}):
        return _from_eventbridge_ecr(body.get("detail-type", ""), body.get("detail") or {})

    if "alerts" in body:
        return _from_alertmanager(body)

    # SNS may wrap EventBridge: {"Message": "{...}"}
    if isinstance(body.get("Message"), str):
        return _build_payload(body["Message"])

    return {
        "text": "ChatOps event",
        "blocks": [
            {
                "type": "section",
                "text": {"type": "mrkdwn", "text": f"```{json.dumps(body)[:1800]}```"},
            }
        ],
    }


def handler(event, context):  # noqa: ANN001, ANN201
    LOG.info("event keys=%s", list(event.keys()) if isinstance(event, dict) else type(event))
    records = event.get("Records") or []
    for rec in records:
        sns = rec.get("Sns") or {}
        message = sns.get("Message") or "{}"
        _maybe_forensic_dump({"id": sns.get("MessageId"), "source": "sns", "message": message})
        payload = _build_payload(message)
        _post_slack(payload)
    return {"statusCode": 200, "body": "ok"}
