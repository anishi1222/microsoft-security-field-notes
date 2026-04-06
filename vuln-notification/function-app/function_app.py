"""HTTP trigger that accepts one or more Entra UPNs and posts an Adaptive Card to a Teams group chat."""

import json
import logging
import os
import base64
from datetime import datetime, timezone

import azure.functions as func
import msal
import requests

app = func.FunctionApp(http_auth_level=func.AuthLevel.ANONYMOUS)

GRAPH_BASE = "https://graph.microsoft.com/v1.0"
AUTHORITY_TEMPLATE = "https://login.microsoftonline.com/{tenant_id}"
GRAPH_SCOPES = [
    "https://graph.microsoft.com/Chat.Create",
    "https://graph.microsoft.com/ChatMessage.Send",
    "https://graph.microsoft.com/Tasks.ReadWrite",
    "https://graph.microsoft.com/User.ReadBasic.All",
]


def _extract_bearer_token(req: func.HttpRequest) -> str:
    authz = req.headers.get("Authorization", "")
    if not authz.lower().startswith("bearer "):
        raise ValueError("Authorization: Bearer <token> ヘッダーが必要です")
    token = authz.split(" ", 1)[1].strip()
    if not token:
        raise ValueError("Bearer トークンが空です")
    return token


def _decode_jwt_payload_unverified(token: str) -> dict:
    parts = token.split(".")
    if len(parts) < 2:
        return {}
    payload = parts[1]
    payload += "=" * (-len(payload) % 4)
    try:
        raw = base64.urlsafe_b64decode(payload.encode("utf-8"))
        return json.loads(raw.decode("utf-8"))
    except Exception:
        return {}


def _is_graph_audience_token(token: str) -> bool:
    claims = _decode_jwt_payload_unverified(token)
    aud = str(claims.get("aud", "")).lower()
    return aud in {
        "00000003-0000-0000-c000-000000000000",
        "https://graph.microsoft.com",
        "https://graph.microsoft.com/",
    }


def _get_graph_token_on_behalf_of(user_token: str) -> str:
    tenant_id = os.environ["TENANT_ID"]
    client_id = os.environ["CLIENT_ID"]
    client_secret = os.environ["CLIENT_SECRET"]

    if _is_graph_audience_token(user_token):
        return user_token

    cca = msal.ConfidentialClientApplication(
        client_id=client_id,
        authority=AUTHORITY_TEMPLATE.format(tenant_id=tenant_id),
        client_credential=client_secret,
    )
    result = cca.acquire_token_on_behalf_of(
        user_assertion=user_token,
        scopes=GRAPH_SCOPES,
    )
    access_token = result.get("access_token")
    if not access_token:
        detail = result.get("error_description") or result.get("error") or "unknown_error"
        raise RuntimeError(f"OBO token acquisition failed: {detail}")
    return access_token


def _graph_headers(token: str) -> dict:
    return {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}


def _parse_upns(body: dict) -> list[str]:
    values = []

    if isinstance(body.get("upns"), list):
        values.extend(body["upns"])

    if isinstance(body.get("upns"), str):
        values.extend(body["upns"].split(","))

    if isinstance(body.get("upn"), str):
        values.append(body["upn"])

    normalized = []
    for raw in values:
        upn = str(raw).strip().lower()
        if upn and upn not in normalized:
            normalized.append(upn)
    return normalized


def _resolve_user_by_upn(token: str, upn: str) -> dict:
    url = f"{GRAPH_BASE}/users/{upn}?$select=id,displayName,userPrincipalName"
    resp = requests.get(url, headers={"Authorization": f"Bearer {token}"}, timeout=30)
    resp.raise_for_status()
    return resp.json()


def _create_group_chat(token: str, user_ids: list[str]) -> str:
    members = [
        {
            "@odata.type": "#microsoft.graph.aadUserConversationMember",
            "roles": ["owner"],
            "user@odata.bind": f"https://graph.microsoft.com/v1.0/users('{user_id}')",
        }
        for user_id in user_ids
    ]

    payload = {"chatType": "group", "members": members}
    resp = requests.post(
        f"{GRAPH_BASE}/chats",
        headers=_graph_headers(token),
        json=payload,
        timeout=30,
    )
    if not resp.ok:
        raise RuntimeError(f"{resp.status_code} {resp.text}")
    return resp.json()["id"]


def _build_adaptive_card(body: dict, resolved_users: list[dict]) -> dict:
    title = str(body.get("title", "Entra 通知"))
    message = str(body.get("message", "HTTP トリガーからの通知です。"))
    requested_at = datetime.now(timezone.utc).isoformat(timespec="seconds")

    target_lines = []
    for user in resolved_users:
        display = user.get("displayName", "")
        upn = user.get("userPrincipalName", "")
        target_lines.append(f"- {display} ({upn})")

    facts = [{"title": "受信時刻 (UTC)", "value": requested_at}]
    extra_facts = body.get("facts", {})
    if isinstance(extra_facts, dict):
        for key, value in extra_facts.items():
            facts.append({"title": str(key), "value": str(value)})

    return {
        "$schema": "http://adaptivecards.io/schemas/adaptive-card.json",
        "type": "AdaptiveCard",
        "version": "1.5",
        "body": [
            {"type": "TextBlock", "size": "Large", "weight": "Bolder", "text": title},
            {"type": "TextBlock", "wrap": True, "text": message},
            {"type": "TextBlock", "weight": "Bolder", "spacing": "Medium", "text": "対象ユーザー"},
            {"type": "TextBlock", "wrap": True, "text": "\n".join(target_lines)},
            {"type": "FactSet", "facts": facts},
        ],
    }


def _post_card_to_chat(token: str, chat_id: str, card: dict, fallback_text: str) -> dict:
    payload = {
        "body": {"contentType": "html", "content": fallback_text + "<attachment id=\"msg-card\"></attachment>"},
        "attachments": [
            {
                "id": "msg-card",
                "contentType": "application/vnd.microsoft.card.adaptive",
                "content": json.dumps(card, ensure_ascii=False),
            }
        ],
    }
    resp = requests.post(
        f"{GRAPH_BASE}/chats/{chat_id}/messages",
        headers=_graph_headers(token),
        json=payload,
        timeout=30,
    )
    resp.raise_for_status()
    return resp.json()


def _resolve_due_datetime(body: dict) -> str:
    planner = body.get("planner", {})
    if isinstance(planner, dict):
        due_datetime = str(planner.get("due_datetime", "")).strip()
        if due_datetime:
            return due_datetime

    facts = body.get("facts", {})
    if isinstance(facts, dict):
        due_date = str(facts.get("due_date", "")).strip()
        if due_date:
            return f"{due_date}T23:59:59Z"
    return ""


def _create_planner_task(token: str, body: dict, resolved_users: list[dict]) -> str:
    planner = body.get("planner", {})
    if not isinstance(planner, dict):
        planner = {}

    plan_id = str(planner.get("plan_id") or body.get("planner_plan_id") or "").strip()
    bucket_id = str(planner.get("bucket_id") or body.get("planner_bucket_id") or "").strip()
    if not plan_id or not bucket_id:
        raise ValueError("Planner を有効化する場合、planner.plan_id と planner.bucket_id は必須です")

    facts = body.get("facts", {}) if isinstance(body.get("facts", {}), dict) else {}
    cve_id = str(facts.get("cve_id", "")).strip()
    severity = str(facts.get("severity", "")).strip()
    component = str(facts.get("component", "")).strip()

    default_title = f"[脆弱性対応] {cve_id} {component}".strip()
    title = str(planner.get("title") or default_title or body.get("title") or "脆弱性対応").strip()

    payload: dict = {
        "planId": plan_id,
        "bucketId": bucket_id,
        "title": title,
    }

    due_datetime = _resolve_due_datetime(body)
    if due_datetime:
        payload["dueDateTime"] = due_datetime

    requested_assignees = []
    raw_assignee_upns = planner.get("assignee_upns", [])
    if isinstance(raw_assignee_upns, list):
        requested_assignees.extend([str(v).strip().lower() for v in raw_assignee_upns if str(v).strip()])
    elif isinstance(raw_assignee_upns, str):
        requested_assignees.extend([v.strip().lower() for v in raw_assignee_upns.split(",") if v.strip()])

    assignee_upn = str(planner.get("assignee_upn", "")).strip().lower()
    if assignee_upn:
        requested_assignees = [assignee_upn]

    if len(requested_assignees) == 0:
        # Default behavior: assign all target users when assignee isn't explicitly specified.
        requested_assignees = [
            str(user.get("userPrincipalName", "")).strip().lower()
            for user in resolved_users
            if str(user.get("userPrincipalName", "")).strip()
        ]

    requested_assignees = list(dict.fromkeys(requested_assignees))

    assignments = {}
    for user in resolved_users:
        upn = str(user.get("userPrincipalName", "")).strip().lower()
        if upn in requested_assignees:
            user_id = user.get("id")
            if user_id:
                assignments[user_id] = {
                    "@odata.type": "#microsoft.graph.plannerAssignment",
                    "orderHint": " !",
                }

    if assignments:
        payload["assignments"] = assignments

    resp = requests.post(
        f"{GRAPH_BASE}/planner/tasks",
        headers=_graph_headers(token),
        json=payload,
        timeout=30,
    )
    if not resp.ok:
        raise RuntimeError(f"{resp.status_code} {resp.text}")

    task_id = str(resp.json().get("id", "")).strip()
    if not task_id:
        raise RuntimeError("Planner task id not returned")

    description_lines = [
        f"CVE: {cve_id or 'N/A'}",
        f"Severity: {severity or 'N/A'}",
        f"Component: {component or 'N/A'}",
        "",
        str(body.get("message", "")),
    ]

    etag = resp.headers.get("ETag", "")
    if etag:
        detail_payload = {"description": "\n".join(description_lines)}
        patch_resp = requests.patch(
            f"{GRAPH_BASE}/planner/tasks/{task_id}/details",
            headers={
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
                "If-Match": etag,
            },
            json=detail_payload,
            timeout=30,
        )
        if not patch_resp.ok:
            logging.warning(
                "Planner task details update skipped: %s %s",
                patch_resp.status_code,
                patch_resp.text,
            )

    return task_id


@app.route(route="notify", methods=["POST"])
def notify(req: func.HttpRequest) -> func.HttpResponse:
    api_key = os.environ.get("API_KEY", "")
    req_key = req.headers.get("x-api-key", "")
    if not api_key or req_key != api_key:
        return func.HttpResponse("Unauthorized", status_code=401)

    try:
        body = req.get_json()
    except Exception:
        return func.HttpResponse("Invalid JSON", status_code=400)

    upns = _parse_upns(body)
    chat_id = str(body.get("chat_id", "")).strip()

    if len(upns) == 0:
        return func.HttpResponse("upn または upns は必須です", status_code=400)

    if not chat_id and len(upns) < 2:
        return func.HttpResponse(
            "chat_id 未指定時は upns に 2 件以上の UPN が必要です",
            status_code=400,
        )

    try:
        user_token = _extract_bearer_token(req)
        token = _get_graph_token_on_behalf_of(user_token)
    except Exception as ex:
        logging.exception("Graph OBO トークン取得失敗")
        return func.HttpResponse(f"Delegated token acquisition failed: {ex}", status_code=401)

    resolved_users = []
    for upn in upns:
        try:
            resolved_users.append(_resolve_user_by_upn(token, upn))
        except Exception as ex:
            return func.HttpResponse(f"UPN 解決失敗: {upn}: {ex}", status_code=400)

    if not chat_id:
        try:
            user_ids = [user["id"] for user in resolved_users]
            chat_id = _create_group_chat(token, user_ids)
        except Exception as ex:
            logging.exception("グループチャット作成失敗")
            return func.HttpResponse(f"Chat creation failed: {ex}", status_code=500)

    card = _build_adaptive_card(body, resolved_users)
    fallback_text = str(body.get("message", "Notification")) + "\n"

    try:
        message = _post_card_to_chat(token, chat_id, card, fallback_text)
    except Exception as ex:
        logging.exception("チャット投稿失敗")
        return func.HttpResponse(f"Chat post failed: {ex}", status_code=500)

    response = {
        "status": "sent",
        "chat_id": chat_id,
        "message_id": message.get("id"),
        "target_upns": [u.get("userPrincipalName") for u in resolved_users],
    }

    planner_enabled = False
    planner_obj = body.get("planner", {})
    if isinstance(planner_obj, dict):
        planner_enabled = bool(planner_obj.get("enabled"))
    planner_enabled = planner_enabled or bool(body.get("planner_plan_id"))

    if planner_enabled:
        try:
            planner_task_id = _create_planner_task(token, body, resolved_users)
            response["planner_task_id"] = planner_task_id
        except Exception as ex:
            logging.exception("Planner タスク作成失敗")
            response["planner_error"] = str(ex)
            return func.HttpResponse(
                json.dumps(response, ensure_ascii=False),
                status_code=207,
                mimetype="application/json",
            )

    return func.HttpResponse(
        json.dumps(response, ensure_ascii=False),
        status_code=200,
        mimetype="application/json",
    )
