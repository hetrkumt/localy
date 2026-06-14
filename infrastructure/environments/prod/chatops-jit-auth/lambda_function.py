import base64
import hashlib
import hmac
import json
import logging
import os
import time
import urllib.parse
import urllib.request  # 🚀 내장 통신 모듈 추가
from typing import Any

import boto3
from botocore.exceptions import ClientError

# 로그 기록용 객체 활성화
logger = logging.getLogger()
logger.setLevel(logging.INFO)

ACTION_ID = "request_jit_log_access"
DENY_MESSAGE = "접근 권한이 없습니다."
MAX_PRESIGN_EXPIRY_SECONDS = 900
MIN_PRESIGN_EXPIRY_SECONDS = 60

_signing_secret_cache: str | None = None
_secrets_client = None
_s3_client = None


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


def _get_signing_secret() -> str | None:
    global _signing_secret_cache
    arn = os.environ.get("SLACK_SIGNING_SECRET_ARN", "").strip()
    if not arn:
        return None
    if _signing_secret_cache is None:
        _signing_secret_cache = _get_secrets_client().get_secret_value(SecretId=arn)["SecretString"]
    return _signing_secret_cache


def _get_whitelist() -> set[str]:
    raw = os.environ.get("SRE_SLACK_USER_IDS", "").strip()
    if not raw:
        return set()
    return {uid.strip() for uid in raw.split(",") if uid.strip()}


def _presign_expiry_seconds() -> int:
    raw = int(os.environ.get("PRESIGNED_URL_EXPIRY_SECONDS", str(MAX_PRESIGN_EXPIRY_SECONDS)))
    return min(max(raw, MIN_PRESIGN_EXPIRY_SECONDS), MAX_PRESIGN_EXPIRY_SECONDS)


def _slack_response(text: str, *, status_code: int = 200) -> dict[str, Any]:
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(
            {
                "response_type": "ephemeral",
                "replace_original": False,
                "text": text,
            },
            ensure_ascii=False,
        ),
    }


def _post_to_slack_url(response_url: str, text: str) -> None:
    """슬랙이 허용한 비밀 통로(response_url)로 진짜 링크 알맹이를 쏘아 보내는 무전기 함수"""
    if not response_url:
        return
        
    payload = {
        "response_type": "ephemeral",
        "replace_original": False,
        "text": text
    }
    
    data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(
        response_url,
        data=data,
        headers={"Content-Type": "application/json; charset=utf-8"},
        method="POST"
    )
    with urllib.request.urlopen(req, timeout=5) as response:
        response.read()


def _verify_slack_signature(headers: dict[str, str], body: str) -> bool:
    secret = _get_signing_secret()
    if not secret:
        return os.environ.get("REQUIRE_SLACK_SIGNATURE", "true").lower() != "true"

    timestamp = headers.get("x-slack-request-timestamp", "")
    signature = headers.get("x-slack-signature", "")
    if not timestamp or not signature:
        return False

    if abs(time.time() - int(timestamp)) > 60 * 5:
        return False

    basestring = f"v0:{timestamp}:{body}"
    digest = hmac.new(
        secret.encode("utf-8"),
        basestring.encode("utf-8"),
        hashlib.sha256,
    ).hexdigest()
    expected = f"v0={digest}"
    return hmac.compare_digest(expected, signature)


def _parse_body(event: dict[str, Any]) -> tuple[dict[str, str], str]:
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    body = event.get("body") or ""
    if event.get("isBase64Encoded"):
        body = base64.b64decode(body).decode("utf-8")
    return headers, body


def _parse_slack_payload(body: str) -> dict[str, Any]:
    params = urllib.parse.parse_qs(body, keep_blank_values=True)
    payload_list = params.get("payload")
    if not payload_list or not payload_list[0]:
        raise ValueError("missing Slack payload field")
    return json.loads(payload_list[0])


def _parse_jit_context(action: dict[str, Any]) -> dict[str, str]:
    value = (action.get("value") or "").strip()
    if not value:
        raise ValueError("missing action value")

    try:
        parsed = json.loads(value)
        if not isinstance(parsed, dict):
            raise ValueError("action value must be a JSON object")
        return {
            "fp": str(parsed.get("fp") or parsed.get("fingerprint") or ""),
            "an": str(parsed.get("an") or parsed.get("alertname") or ""),
            "ns": str(parsed.get("ns") or parsed.get("namespace") or ""),
            "pod": str(parsed.get("pod") or ""),
            "tier": str(parsed.get("tier") or ""),
            "sev": str(parsed.get("sev") or parsed.get("severity") or ""),
            "ts": str(parsed.get("ts") or ""),
        }
    except json.JSONDecodeError:
        parts: dict[str, str] = {}
        for segment in value.split("|"):
            if "=" in segment:
                key, val = segment.split("=", 1)
                parts[key.strip()] = val.strip()
        return {
            "fp": parts.get("fp", ""),
            "an": parts.get("an", ""),
            "ns": parts.get("ns", ""),
            "pod": parts.get("pod", ""),
            "tier": parts.get("tier", ""),
            "sev": parts.get("sev", ""),
            "ts": parts.get("ts", ""),
        }


def _object_exists(bucket: str, key: str) -> bool:
    try:
        _get_s3_client().head_object(Bucket=bucket, Key=key)
        return True
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code", "")
        if code in {"404", "NoSuchKey", "NotFound"}:
            return False
        raise


def _resolve_forensic_object_key(ctx: dict[str, str]) -> str:
    fingerprint = ctx.get("fp", "").strip()
    if not fingerprint:
        raise ValueError("missing fingerprint (fp)")

    bucket = os.environ.get("CHATOPS_DUMP_BUCKET_NAME", "").strip()
    if not bucket:
        raise ValueError("CHATOPS_DUMP_BUCKET_NAME is not configured")

    alertname = ctx.get("an", "").strip()
    namespace = ctx.get("ns", "").strip()
    pod = ctx.get("pod", "").strip()
    prefix = f"forensic/{fingerprint}/"

    candidates = [
        f"{prefix}dump.tar.gz",
        f"{prefix}forensic-dump.tar.gz",
    ]
    if alertname and namespace and pod:
        candidates.append(f"{prefix}{alertname}/{namespace}/{pod}/dump.tar.gz")

    for key in candidates:
        if _object_exists(bucket, key):
            return key

    response = _get_s3_client().list_objects_v2(Bucket=bucket, Prefix=prefix, MaxKeys=20)
    contents = response.get("Contents") or []
    if not contents:
        raise ValueError(f"no forensic object found under {prefix}")

    latest = max(contents, key=lambda item: item["LastModified"])
    return latest["Key"]


def _generate_presigned_url(object_key: str) -> str:
    bucket = os.environ["CHATOPS_DUMP_BUCKET_NAME"]
    expiry = _presign_expiry_seconds()
    return _get_s3_client().generate_presigned_url(
        ClientMethod="get_object",
        Params={"Bucket": bucket, "Key": object_key},
        ExpiresIn=expiry,
    )


def _build_success_message(presigned_url: str, object_key: str) -> str:
    expiry_minutes = _presign_expiry_seconds() // 60
    return (
        "포렌식 로그 접근이 승인되었습니다.\n"
        f"<{presigned_url}|포렌식 로그 다운로드>\n"
        f"_객체:_ `{object_key}` · _유효 시간:_ {expiry_minutes}분 (본인에게만 표시됩니다)"
    )


def handler(event, context):
    try:
        headers, body = _parse_body(event)

        if not _verify_slack_signature(headers, body):
            return _slack_response("요청 서명 검증에 실패했습니다.", status_code=401)

        payload = _parse_slack_payload(body)

        if payload.get("type") != "block_actions":
            return _slack_response("지원하지 않는 상호작용 유형입니다.", status_code=400)

        user = payload.get("user") or {}
        slack_user_id = user.get("id", "")
        if not slack_user_id:
            return _slack_response(DENY_MESSAGE, status_code=403)

        actions = payload.get("actions") or []
        if not actions:
            return _slack_response("액션 정보가 없습니다.", status_code=400)

        action = actions[0]
        if action.get("action_id") != ACTION_ID:
            return _slack_response("알 수 없는 액션입니다.", status_code=400)

        whitelist = _get_whitelist()
        if slack_user_id not in whitelist:
            return _slack_response(DENY_MESSAGE, status_code=403)

        jit_ctx = _parse_jit_context(action)
        object_key = _resolve_forensic_object_key(jit_ctx)
        presigned_url = _generate_presigned_url(object_key)

        # 1. 비밀 주소 파싱
        response_url = payload.get("response_url")

        # 2. 실물 함수 작동하여 슬랙 화면에 진짜 링크 노출
        _post_to_slack_url(response_url, _build_success_message(presigned_url, object_key))

        # 3. 슬랙 본사 채널에 즉시 빈 영수증 던지고 정상 퇴근
        return {"statusCode": 200, "body": ""}

    except ValueError as exc:
        logger.warning("ValueError: %s", exc)
        return _slack_response(f"요청을 처리할 수 없습니다: {exc}", status_code=400)
    except ClientError as exc:
        logger.exception("S3 ClientError occurred: %s", exc)
        return _slack_response("포렌식 저장소 접근에 실패했습니다. SRE에 문의하세요.", status_code=500)
    except Exception as exc:
        logger.exception("Unexpected internal error: %s", exc)  # 🚀 블랙박스 예외 로깅 추가
        return _slack_response("내부 오류가 발생했습니다. SRE에 문의하세요.", status_code=500)