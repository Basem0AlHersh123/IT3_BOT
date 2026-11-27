"""Tests for Option A (user search) + Option B (one-time expiring role invites)."""
from __future__ import annotations

import asyncio
import unittest
from pathlib import Path
from types import SimpleNamespace as NS

from tests import stubs

stubs.install()

from bot import main as bot_main  # noqa: E402
from core.invites import (  # noqa: E402
    INVITE_PREFIX,
    build_invite_link,
    format_claim_message,
    generate_invite_token,
    hash_invite_token,
    parse_invite_payload,
)
from tests.test_bot_flows import FakeBot, FakeStore  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent


class InviteCoreTests(unittest.TestCase):
    def test_token_generation_and_hashing(self) -> None:
        t1 = generate_invite_token()
        t2 = generate_invite_token()
        self.assertNotEqual(t1, t2)
        self.assertLessEqual(len(INVITE_PREFIX + t1), 64)
        h1 = hash_invite_token(t1)
        self.assertEqual(len(h1), 64)
        self.assertEqual(h1, hash_invite_token(f"  {t1}  "))
        self.assertNotEqual(h1, t1)

    def test_parse_invite_payload(self) -> None:
        tok = generate_invite_token()
        self.assertEqual(parse_invite_payload(f"inv_{tok}"), tok)
        for bad in (None, "", "up_12", "inv_short", "inv_has space here!!", "other_" + tok):
            self.assertIsNone(parse_invite_payload(bad), f"should reject {bad!r}")

    def test_build_invite_link(self) -> None:
        tok = generate_invite_token()
        self.assertEqual(
            build_invite_link("@Nirvana_service_bot", tok),
            f"https://t.me/Nirvana_service_bot?start=inv_{tok}",
        )
        self.assertIsNone(build_invite_link("", tok))
        self.assertIsNone(build_invite_link("bot", "bad"))

    def test_format_claim_messages(self) -> None:
        ok_scoped = format_claim_message({"status": "ok", "role": "cohort_admin", "scope_name": "IT3 <Level 3>"})
        self.assertIn("مشرف الدفعة", ok_scoped)
        self.assertIn("IT3 &lt;Level 3&gt;", ok_scoped)
        ok_dev = format_claim_message({"status": "ok", "role": "developer"})
        self.assertIn("مطوّر", ok_dev)
        self.assertIn("النظام بالكامل", ok_dev)
        self.assertIn("مسبقًا", format_claim_message({"status": "used"}))
        self.assertIn("انتهت", format_claim_message({"status": "expired"}))
        self.assertIn("إلغاء", format_claim_message({"status": "revoked"}))
        self.assertIn("محظور", format_claim_message({"status": "banned"}))
        self.assertIn("غير صالح", format_claim_message({"status": "invalid"}))


class BotInviteClaimTests(unittest.TestCase):
    def _make_ctx(self, store: FakeStore, profiles: list[dict], args: list[str]):
        bot = FakeBot()
        idx = {"i": 0}

        class _Svc:
            def __init__(self) -> None:
                self.store = store
                self.settings = NS(web_app_url="https://example.vercel.app")

            async def profile(self, tg, force: bool = False):
                p = profiles[min(idx["i"], len(profiles) - 1)]
                idx["i"] += 1
                return p

        return NS(
            bot=bot,
            args=args,
            user_data={},
            application=NS(bot_data={"svc": _Svc()}),
        )

    def _upd(self, uid: int = 777):
        return NS(
            effective_chat=NS(id=uid),
            effective_user=NS(id=uid, full_name="Ali Admin", first_name="Ali", username="ali_it3"),
        )

    def test_brand_new_user_claims_invite_and_gets_menu(self) -> None:
        tok = generate_invite_token()
        store = FakeStore({
            "unblock_user": None,
            "claim_role_invite": {"status": "ok", "role": "cohort_admin", "scope_name": "IT3"},
        })
        profiles = [
            {"user": {"kind": "new", "name": "Ali Admin"}, "roles": [], "perms": []},
            {"user": {"kind": "guest", "name": "Ali Admin"}, "roles": [{"role": "cohort_admin"}], "perms": [{"k": "roles.manage"}]},
        ]
        ctx = self._make_ctx(store, profiles, [f"inv_{tok}"])
        asyncio.run(bot_main.on_start(self._upd(), ctx))

        claims = store.called("claim_role_invite")
        self.assertEqual(len(claims), 1)
        self.assertEqual(claims[0]["p_token_hash"], hash_invite_token(tok))
        self.assertEqual(claims[0]["p_tg"], 777)
        # First message = claim confirmation; second message = main menu (not new-user entry)
        self.assertGreaterEqual(len(ctx.bot.sent), 2)
        self.assertIn("مشرف الدفعة", ctx.bot.sent[0][1]["text"])

    def test_expired_invite_shows_error_without_menu(self) -> None:
        tok = generate_invite_token()
        store = FakeStore({"unblock_user": None, "claim_role_invite": {"status": "expired"}})
        profiles = [{"user": {"kind": "new", "name": "Ali"}, "roles": [], "perms": []}]
        ctx = self._make_ctx(store, profiles, [f"inv_{tok}"])
        asyncio.run(bot_main.on_start(self._upd(), ctx))
        self.assertEqual(len(ctx.bot.sent), 1)
        self.assertIn("انتهت صلاحية", ctx.bot.sent[0][1]["text"])

    def test_banned_user_cannot_claim_invite(self) -> None:
        tok = generate_invite_token()
        store = FakeStore({"unblock_user": None})
        profiles = [{"user": {"kind": "banned", "name": "Bad"}, "roles": [], "perms": []}]
        ctx = self._make_ctx(store, profiles, [f"inv_{tok}"])
        asyncio.run(bot_main.on_start(self._upd(), ctx))
        self.assertEqual(store.called("claim_role_invite"), [])


class Migration0023RoleInvitesTests(unittest.TestCase):
    def setUp(self) -> None:
        self.sql = (ROOT / "supabase" / "migrations" / "0023_role_invites_and_user_search.sql").read_text("utf-8")

    def test_schema_rpcs_and_security(self) -> None:
        for needle in (
            "create table if not exists role_invites",
            "token_hash    text not null unique",
            "alter table role_invites enable row level security",
            "create or replace function search_users_for_role(",
            "create or replace function create_role_invite(",
            "create or replace function list_role_invites(",
            "create or replace function revoke_role_invite(",
            "create or replace function claim_role_invite(",
            "actor_max_role_rank(p_actor, p_scope_node_id)",
            "grant execute on function claim_role_invite(",
        ):
            self.assertIn(needle, self.sql)


if __name__ == "__main__":
    unittest.main()
