"""
ChatOps Dispatch Lambda — SNS __JIT_CTX__ → Slack Block Kit + JIT Interactivity Button
Downstream: chatops-jit-auth (action_id=request_jit_log_access)
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
import re
import time
import urllib.error
import urllib.request
from typing import Any

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

JIT_CTX_PREFIX = "__JIT_CTX__"
JIT_ACTION_ID = "request_jit_log_access"
JIT_BUTTON_LABEL = "권한 확인 및 포렌식 로그 열람"

SLACK_POST_MAX_ATTEMPTS = 3
SLACK_POST_BACKOFF_BASE_SECONDS = 1.0

# C0 controls (0x00-0x1F), DEL (0x7F), NBSP (U+00A0) — single-pass flatten before json.loads
_JIT_CTX_CONTROL_CHAR_RE = re.compile(r"[\x00-\x1f\x7f\u00a0]")

_secrets_client = None
_s3_client = None
_webhook_url_cache: str | None = None


def _get_secrets_client():
    global _secrets_client
    if _secrets_client is None:
        _secrets_client = boto3.client("secretsmanager")
    return _secrets_client


def _get_s3_client():
    global _s3_client
    if _s3_client is None:
        _s3_client = boto3.client("s3")
    return _s3_client


def _parse_webhook_secret(raw: str) -> str:
    raw = raw.strip()
    if not raw:
        raise ValueError("empty Slack webhook secret")
    if raw.startswith("{"):
        parsed = json.loads(raw)
        for key in ("url", "webhook_url", "incoming_webhook_url"):
            value = parsed.get(key)
            if isinstance(value, str) and value.strip():
                return value.strip()
        raise ValueError("webhook secret JSON missing url field")
    return raw


def _get_slack_webhook_url() -> str:
    global _webhook_url_cache
    if _webhook_url_cache is not None:
        return _webhook_url_cache

    arn = os.environ.get("SLACK_WEBHOOK_SECRET_ARN", "").strip()
    if not arn:
        raise ValueError("SLACK_WEBHOOK_SECRET_ARN is not configured")

    secret_string = _get_secrets_client().get_secret_value(SecretId=arn)["SecretString"]
    _webhook_url_cache = _parse_webhook_secret(secret_string)
    return _webhook_url_cache


def _extract_sns_message(event: dict[str, Any]) -> str:
    records = event.get("Records")
    if isinstance(records, list) and records:
        sns = records[0].get("Sns") or {}
        message = sns.get("Message")
        if isinstance(message, str):
            return message
    if isinstance(event.get("Message"), str):
        return event["Message"]
    return json.dumps(event, ensure_ascii=False)


def _sanitize_jit_ctx_json_body(body: str) -> str:
    """Flatten control chars and NBSP that invalidate JSON before json.loads."""
    if not body:
        return body
    return _JIT_CTX_CONTROL_CHAR_RE.sub(" ", body)


def _parse_jit_ctx(message: str) -> tuple[dict[str, Any] | None, str]:
    body = message.strip()
    if body.startswith(JIT_CTX_PREFIX):
        body = body[len(JIT_CTX_PREFIX) :].strip()

    if not body:
        return None, message

    body = _sanitize_jit_ctx_json_body(body)

    try:
        parsed = json.loads(body)
        if isinstance(parsed, dict):
            return parsed, message
    except json.JSONDecodeError as exc:
        logger.warning("JIT_CTX JSON parse failed: %s", exc)

    return None, message


def _safe_get(mapping: Any, key: str, default: str = "") -> str:
    if not isinstance(mapping, dict):
        return default
    value = mapping.get(key)
    if value is None:
        return default
    return str(value)


def _status_emoji(status: str) -> str:
    normalized = status.strip().lower()
    if normalized == "resolved":
        return ":white_check_mark:"
    if normalized == "firing":
        return ":rotating_light:"
    return ":warning:"


def _build_jit_button_value(ctx: dict[str, Any]) -> str:
    group_key = _safe_get(ctx, "groupKey")
    common_labels = ctx.get("commonLabels") if isinstance(ctx.get("commonLabels"), dict) else {}
    group_labels = ctx.get("groupLabels") if isinstance(ctx.get("groupLabels"), dict) else {}

    payload = {
        "groupKey": group_key,
        "fp": _forensic_fingerprint(ctx) if group_key else "",
        "an": _safe_get(common_labels, "alertname"),
        "ns": _safe_get(common_labels, "namespace") or _safe_get(group_labels, "namespace"),
        "pod": _safe_get(common_labels, "pod") or _safe_get(group_labels, "pod"),
        "tier": _safe_get(common_labels, "tier") or _safe_get(group_labels, "tier"),
        "sev": _safe_get(common_labels, "severity"),
        "ts": str(int(time.time())),
    }

    value = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    if len(value) > 2000:
        payload.pop("groupKey", None)
        value = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    return value[:2000]


def _forensic_fingerprint(ctx: dict[str, Any]) -> str:
    """Derive JIT-compatible fingerprint from groupKey (matches button value fp)."""
    group_key = _safe_get(ctx, "groupKey").strip()
    if group_key:
        return hashlib.sha256(group_key.encode("utf-8")).hexdigest()[:32]
    return f"dispatch-{int(time.time())}"


def _build_forensic_s3_key(ctx: dict[str, Any]) -> str:
    group_key = _safe_get(ctx, "groupKey").strip()
    if group_key:
        # groupKey-derived fp — JIT Auth resolves under forensic/{fp}/
        fp = _forensic_fingerprint(ctx)
        return f"forensic/{fp}/jit-ctx.json"
    return f"forensic/dispatch-{int(time.time())}.json"


def _dump_alarm_to_s3(ctx: dict[str, Any]) -> None:
    try:
        bucket = os.environ.get("ALARM_DUMP_BUCKET_NAME", "").strip()
        if not bucket:
            logger.warning("ALARM_DUMP_BUCKET_NAME not configured; skipping S3 dump")
            return

        object_key = _build_forensic_s3_key(ctx)
        body = json.dumps(ctx, ensure_ascii=False, separators=(",", ":")).encode("utf-8")

        _get_s3_client().put_object(
            Bucket=bucket,
            Key=object_key,
            Body=body,
            ContentType="application/json",
        )
        logger.info("S3 forensic dump stored: s3://%s/%s", bucket, object_key)
    except Exception as s3_err:
        logger.error("S3 dump failed but bypassing: %s", s3_err)


def _build_block_kit(ctx: dict[str, Any]) -> dict[str, Any]:
    status = _safe_get(ctx, "status", "unknown")
    common_labels = ctx.get("commonLabels") if isinstance(ctx.get("commonLabels"), dict) else {}
    common_annotations = (
        ctx.get("commonAnnotations") if isinstance(ctx.get("commonAnnotations"), dict) else {}
    )
    group_labels = ctx.get("groupLabels") if isinstance(ctx.get("groupLabels"), dict) else {}

    alertname = _safe_get(common_labels, "alertname", "unknown")
    severity = _safe_get(common_labels, "severity", "n/a")
    tier = _safe_get(common_labels, "tier", "n/a")
    namespace = _safe_get(common_labels, "namespace") or _safe_get(group_labels, "namespace", "n/a")
    cluster = _safe_get(common_labels, "cluster") or _safe_get(group_labels, "cluster", "n/a")
    summary = _safe_get(common_annotations, "summary", "—")
    description = _safe_get(common_annotations, "description", "—")
    alert_count = ctx.get("alertCount", "—")

    header_text = f"{_status_emoji(status)} [{status.upper()}] {alertname}"

    blocks: list[dict[str, Any]] = [
        {
            "type": "header",
            "text": {"type": "plain_text", "text": header_text[:150], "emoji": True},
        },
        {
            "type": "section",
            "fields": [
                {"type": "mrkdwn", "text": f"*Severity:*\n{severity}"},
                {"type": "mrkdwn", "text": f"*Tier:*\n{tier}"},
                {"type": "mrkdwn", "text": f"*Namespace:*\n`{namespace}`"},
                {"type": "mrkdwn", "text": f"*Cluster:*\n`{cluster}`"},
                {"type": "mrkdwn", "text": f"*Alert Count:*\n{alert_count}"},
                {"type": "mrkdwn", "text": f"*Pipeline:*\nalarm-pipeline-jit-v1"},
            ],
        },
        {
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": f"*Summary:*\n{summary}\n\n*Description:*\n{description}",
            },
        },
        {"type": "divider"},
        {
            "type": "actions",
            "block_id": "jit_forensic_access",
            "elements": [
                {
                    "type": "button",
                    "action_id": JIT_ACTION_ID,
                    "text": {
                        "type": "plain_text",
                        "text": JIT_BUTTON_LABEL,
                        "emoji": True,
                    },
                    "style": "primary",
                    "value": _build_jit_button_value(ctx),
                }
            ],
        },
        {
            "type": "context",
            "elements": [
                {
                    "type": "mrkdwn",
                    "text": f"`groupKey` {_safe_get(ctx, 'groupKey', 'n/a')[:180]}",
                }
            ],
        },
    ]

    return {
        "text": f"[{status.upper()}] {alertname} — ChatOps Alarm",
        "blocks": blocks,
    }


def _build_fallback_payload(raw_message: str) -> dict[str, Any]:
    preview = raw_message[:2800]
    return {
        "text": "ChatOps Alarm (JIT_CTX parse fallback)",
        "blocks": [
            {
                "type": "header",
                "text": {
                    "type": "plain_text",
                    "text": ":warning: ChatOps Alarm — Parse Fallback",
                    "emoji": True,
                },
            },
            {
                "type": "section",
                "text": {
                    "type": "mrkdwn",
                    "text": (
                        "*__JIT_CTX__ JSON 파싱에 실패하여 원문을 그대로 전송합니다.*\n"
                        f"```\n{preview}\n```"
                    ),
                },
            },
        ],
    }


def _post_slack_payload(payload: dict[str, Any]) -> None:
    webhook_url = _get_slack_webhook_url()
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")

    for attempt in range(1, SLACK_POST_MAX_ATTEMPTS + 1):
        request = urllib.request.Request(
            webhook_url,
            data=body,
            headers={"Content-Type": "application/json; charset=utf-8"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                if response.status >= 400:
                    raise urllib.error.HTTPError(
                        webhook_url,
                        response.status,
                        f"unexpected Slack response status {response.status}",
                        response.headers,
                        None,
                    )
            return
        except urllib.error.HTTPError as exc:
            retriable = exc.code in {429, 500, 502, 503, 504}
            logger.warning(
                "Slack POST failed (attempt %s/%s): HTTP %s",
                attempt,
                SLACK_POST_MAX_ATTEMPTS,
                exc.code,
            )
            if not retriable or attempt == SLACK_POST_MAX_ATTEMPTS:
                raise
            retry_after = exc.headers.get("Retry-After")
            sleep_seconds = (
                float(retry_after)
                if retry_after and retry_after.isdigit()
                else SLACK_POST_BACKOFF_BASE_SECONDS * (2 ** (attempt - 1))
            )
            time.sleep(sleep_seconds)
        except urllib.error.URLError as exc:
            logger.warning(
                "Slack POST network error (attempt %s/%s): %s",
                attempt,
                SLACK_POST_MAX_ATTEMPTS,
                exc,
            )
            if attempt == SLACK_POST_MAX_ATTEMPTS:
                raise
            time.sleep(SLACK_POST_BACKOFF_BASE_SECONDS * (2 ** (attempt - 1)))


def handler(event, context):
    try:
        raw_message = _extract_sns_message(event)
        ctx, original_message = _parse_jit_ctx(raw_message)

        if ctx is not None:
            _dump_alarm_to_s3(ctx)
            slack_payload = _build_block_kit(ctx)
        else:
            slack_payload = _build_fallback_payload(original_message)

        _post_slack_payload(slack_payload)
        return {"statusCode": 200, "body": json.dumps({"ok": True})}

    except (ClientError, ValueError, urllib.error.URLError, urllib.error.HTTPError) as exc:
        logger.exception("Dispatch failed: %s", exc)
        raise
