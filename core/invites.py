"""Single-use expiring role invite tokens and deep-link formatting.

Pure domain module (zero I/O, zero third-party deps):
- Tokens are 24-char URL-safe random strings (144 bits of entropy).
- Only the SHA-256 hex digest is stored in PostgreSQL (`role_invites.token_hash`).
- Deep link payload format: `inv_<token>` (28 chars, well under Telegram's 64-char limit).
"""
from __future__ import annotations

import hashlib
import re
import secrets
from html import escape
from typing import Any, Mapping

INVITE_PREFIX = "inv_"
_TOKEN_RE = re.compile(r"^[A-Za-z0-9_-]{16,48}$")

ROLE_LABELS_AR: dict[str, str] = {
    "developer": "مطوّر",
    "college_admin": "مشرف الكلية",
    "major_admin": "مشرف التخصص",
    "cohort_admin": "مشرف الدفعة",
    "group_rep": "مندوب مجموعة",
    "delegate": "مندوب",
    "deputy": "نائب مندوب",
    "committee": "لجنة علمية",
}


def generate_invite_token() -> str:
    """Return a fresh URL-safe random token (24 chars, 144-bit entropy)."""
    return secrets.token_urlsafe(18)


def hash_invite_token(token: str) -> str:
    """Return the SHA-256 hex digest of a raw invite token."""
    return hashlib.sha256(token.strip().encode("utf-8")).hexdigest()


def parse_invite_payload(payload: str | None) -> str | None:
    """Extract the raw token from a Telegram `/start` payload like `inv_<token>`."""
    raw = (payload or "").strip()
    if not raw.startswith(INVITE_PREFIX):
        return None
    token = raw[len(INVITE_PREFIX):]
    if not _TOKEN_RE.fullmatch(token):
        return None
    return token


def build_invite_link(bot_username: str | None, token: str) -> str | None:
    """Build `https://t.me/<bot>?start=inv_<token>` or None if bot_username is empty."""
    name = (bot_username or "").strip().lstrip("@")
    if not name or not _TOKEN_RE.fullmatch(token.strip()):
        return None
    return f"https://t.me/{name}?start={INVITE_PREFIX}{token.strip()}"


def format_claim_message(res: Mapping[str, Any]) -> str:
    """Format a user-facing Arabic HTML response for `claim_role_invite`."""
    status = str(res.get("status") or "invalid")
    if status == "ok":
        role = str(res.get("role") or "")
        role_ar = ROLE_LABELS_AR.get(role, role)
        scope_name = str(res.get("scope_name") or res.get("scope_code") or "").strip()
        scope_line = f"\nالنطاق: <b>{escape(scope_name)}</b>" if scope_name else "\nالنطاق: <b>النظام بالكامل</b>"
        return (
            f"🎉 تم تفعيل صلاحيتك بنجاح!\n"
            f"الدور: <b>{escape(role_ar)}</b>"
            f"{scope_line}\n\n"
            f"افتح التطبيق المصغّر من الزر أدناه للوصول إلى لوحة الإدارة."
        )
    if status == "used":
        return "⚠️ رابط الدعوة هذا تم استخدامه مسبقًا. اطلب رابطًا جديدًا من المشرف."
    if status == "expired":
        return "⌛ انتهت صلاحية رابط الدعوة هذا. اطلب رابطًا جديدًا من المشرف."
    if status == "revoked":
        return "🚫 تم إلغاء رابط الدعوة هذا من قبل المشرف."
    if status == "banned":
        return "🚫 هذا الحساب محظور ولا يمكنه تفعيل الدعوة."
    return "❌ رابط الدعوة غير صالح."
