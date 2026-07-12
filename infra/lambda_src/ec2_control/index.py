"""
API Gateway HTTP API (v2, AWS_PROXY) から EC2 を start/stop する。

ヘッダー x-api-secret を環境変数 SHARED_SECRET と定時間比較して認証する
（API Gateway HTTP API v2 はネイティブの API キー機能を持たないため）。
"""

import hmac
import json
import os

import boto3

ec2 = boto3.client("ec2")

INSTANCE_ID = os.environ["INSTANCE_ID"]
SHARED_SECRET = os.environ["SHARED_SECRET"]
SECRET_HEADER = "x-api-secret"  # API Gateway はヘッダー名を小文字化して渡す


def _response(status_code: int, body: dict):
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def handler(event, context):
    headers = event.get("headers") or {}
    provided = headers.get(SECRET_HEADER, "")

    if not hmac.compare_digest(provided, SHARED_SECRET):
        print("[AUTH] shared secret mismatch")
        return _response(401, {"error": "unauthorized"})

    route_key = event.get("routeKey", "")
    if route_key == "POST /ec2/start":
        action = "start"
    elif route_key == "POST /ec2/stop":
        action = "stop"
    else:
        return _response(404, {"error": "not found"})

    try:
        if action == "start":
            result = ec2.start_instances(InstanceIds=[INSTANCE_ID])
            state = result["StartingInstances"][0]["CurrentState"]["Name"]
        else:
            result = ec2.stop_instances(InstanceIds=[INSTANCE_ID])
            state = result["StoppingInstances"][0]["CurrentState"]["Name"]

        print(f"[OK] {action} -> {state}")
        return _response(200, {"action": action, "state": state})

    except Exception as e:
        print(f"[ERROR] {action} failed: {e}")
        return _response(500, {"error": str(e)})
