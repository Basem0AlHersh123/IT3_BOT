"""API على Vercel (FastAPI). كل طلب شخصي يتحقق من توقيع initData، والصلاحيات تُفحص في قاعدة البيانات."""
from __future__ import annotations

import logging

import json
import os
import sys

_ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _ROOT_DIR not in sys.path:
    sys.path.insert(0, _ROOT_DIR)

from fastapi import Depends, FastAPI, HTTPException, Request, Response
from fastapi.middleware.gzip import GZipMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from api.deps import current_user, etag_response, settings, store
from api.phase2 import router as phase2_router
from api.phase3 import router as phase3_router
from api.phase4 import router as phase4_router
from core.invites import build_invite_link, generate_invite_token, hash_invite_token
from core.store import StoreError
from core.text import clean_name, normalize_academic_no
from core.tg_auth import TgUser

log = logging.getLogger("api")

app = FastAPI(title="Student Bot API", docs_url=None, redoc_url=None, openapi_url=None)
app.add_middleware(GZipMiddleware, minimum_size=400)
app.include_router(phase2_router)
app.include_router(phase3_router)
app.include_router(phase4_router)


@app.exception_handler(StoreError)
async def store_error_handler(request: Request, exc: StoreError) -> JSONResponse:
    if exc.forbidden:
        return JSONResponse({"error": "forbidden"}, status_code=403)
    log.error("store error on %s: %s", request.url.path, exc)    # التفاصيل في سجلاتك فقط، لا للعميل
    return JSONResponse({"error": "upstream"}, status_code=502)


@app.exception_handler(RuntimeError)
async def runtime_error_handler(request: Request, exc: RuntimeError) -> JSONResponse:
    log.error("runtime error on %s: %s", request.url.path, exc)
    return JSONResponse({"error": "server_error"}, status_code=500)


@app.get("/api/health")
async def health() -> dict[str, object]:
    missing = [
        name for name in ("BOT_TOKEN", "SUPABASE_URL", "SUPABASE_SERVICE_KEY")
        if not os.getenv(name, "").strip()
    ]
    return {"ok": True, "env_ready": len(missing) == 0, "missing_env": missing}


@app.get("/api/bootstrap")
async def bootstrap(
    request: Request,
    cohort_node_id: int | None = None,
    user: TgUser = Depends(current_user),
) -> Response:
    data = await store().bootstrap(user.id, user.full_name, user.username, cohort_node_id=cohort_node_id)
    if isinstance(data, dict) and "cohort" not in data and isinstance(data.get("active_cohort"), dict):
        data = {**data, "cohort": data["active_cohort"]}
    return etag_response(request, data)


@app.get("/api/versions")
async def versions(request: Request, _: TgUser = Depends(current_user)) -> Response:
    return etag_response(request, await store().versions())


@app.get("/api/public/catalog")
async def public_catalog(cohort_node_id: int | None = None) -> Response:
    """بيانات عامة غير شخصية فقط، فتُخزَّن على حافة Vercel."""
    subj_params: dict[str, str] = {
        "select": "id,name_ar,hashtag,cohort_node_id",
        "is_active": "eq.true",
        "deleted_at": "is.null",
        "order": "sort,id",
    }
    if cohort_node_id is not None:
        subj_params["cohort_node_id"] = f"eq.{int(cohort_node_id)}"
    subjects = await store().select("subjects", subj_params)
    grp_params: dict[str, str] = {"select": "code,theory_group_id,scope_node_id,cohort_node_id", "order": "sort"}
    if cohort_node_id is not None:
        grp_params["cohort_node_id"] = f"eq.{int(cohort_node_id)}"
    groups = await store().select("practical_groups", grp_params)
    body = json.dumps({"subjects": subjects, "practical_groups": groups}, ensure_ascii=False, separators=(",", ":"))
    return Response(body, media_type="application/json",
                    headers={"Cache-Control": "public, s-maxage=300, stale-while-revalidate=3600"})


class LookupIn(BaseModel):
    academic_no: str = Field(max_length=40)


class GuestIn(BaseModel):
    name: str = Field(max_length=80)


def _no_store(data) -> JSONResponse:
    return JSONResponse(data, headers={"Cache-Control": "no-store"})


@app.post("/api/link/lookup")
async def link_lookup(body: LookupIn, user: TgUser = Depends(current_user)) -> Response:
    no = normalize_academic_no(body.academic_no)
    if not no:
        raise HTTPException(422, "invalid_academic_no")
    return _no_store(await store().lookup_student(user.id, no))


@app.post("/api/link/confirm")
async def link_confirm(body: LookupIn, user: TgUser = Depends(current_user)) -> Response:
    no = normalize_academic_no(body.academic_no)
    if not no:
        raise HTTPException(422, "invalid_academic_no")
    return _no_store(await store().link_student(user.id, no, user.username))


@app.post("/api/guest")
async def guest(body: GuestIn, user: TgUser = Depends(current_user)) -> Response:
    name = clean_name(body.name)
    if not name:
        raise HTTPException(422, "invalid_name")
    return _no_store(await store().register_guest(user.id, name, user.username))


class ActiveCohortIn(BaseModel):
    cohort_node_id: int


class ScopeNodeCreateIn(BaseModel):
    parent_id: int | None = None
    kind: str = Field(max_length=24)
    code: str = Field(min_length=1, max_length=32)
    name_ar: str = Field(min_length=1, max_length=80)
    meta: dict[str, object] = Field(default_factory=dict)
    sort: int = 0


class ScopeNodeUpdateIn(BaseModel):
    name_ar: str | None = Field(default=None, max_length=80)
    meta: dict[str, object] | None = None
    sort: int | None = None
    is_active: bool | None = None


class ScopedRoleGrantIn(BaseModel):
    telegram_id: int
    role: str = Field(max_length=24)
    scope_node_id: int | None = None


class ScopedRoleRevokeIn(BaseModel):
    grant_id: int


@app.get("/api/scopes/tree")
async def scopes_tree(
    request: Request,
    root_id: int | None = None,
    user: TgUser = Depends(current_user),
) -> Response:
    nodes = await store().list_scope_tree(user.id, root_id)
    return etag_response(request, {"nodes": nodes})


@app.post("/api/scopes/nodes")
async def scopes_create_node(body: ScopeNodeCreateIn, user: TgUser = Depends(current_user)) -> Response:
    res = await store().create_scope_node(
        user.id,
        body.parent_id,
        body.kind,
        body.code,
        body.name_ar,
        meta=dict(body.meta),
        sort=body.sort,
    )
    return _no_store(res)


@app.patch("/api/scopes/nodes/{node_id}")
async def scopes_update_node(
    node_id: int,
    body: ScopeNodeUpdateIn,
    user: TgUser = Depends(current_user),
) -> Response:
    res = await store().update_scope_node(
        user.id,
        node_id,
        name_ar=body.name_ar,
        meta=dict(body.meta) if body.meta is not None else None,
        sort=body.sort,
        is_active=body.is_active,
    )
    return _no_store(res)


@app.post("/api/user/active-cohort")
async def user_active_cohort(body: ActiveCohortIn, user: TgUser = Depends(current_user)) -> Response:
    return _no_store(await store().set_active_cohort(user.id, body.cohort_node_id))


@app.get("/api/admin/roles")
async def admin_list_roles(
    request: Request,
    root_id: int | None = None,
    user: TgUser = Depends(current_user),
) -> Response:
    roles = await store().rpc("list_scoped_roles", {"p_actor": user.id, "p_root_id": root_id})
    return etag_response(request, {"roles": roles})


@app.post("/api/admin/roles/grant")
async def admin_grant_role(body: ScopedRoleGrantIn, user: TgUser = Depends(current_user)) -> Response:
    return _no_store(await store().grant_role_scoped(user.id, body.telegram_id, body.role, body.scope_node_id))


class RoleInviteCreateIn(BaseModel):
    role: str = Field(max_length=32)
    scope_node_id: int | None = None
    ttl_hours: int = Field(default=24, ge=1, le=168)
    note: str | None = Field(default=None, max_length=120)


class RoleInviteRevokeIn(BaseModel):
    invite_id: int


@app.post("/api/admin/roles/revoke")
async def admin_revoke_role(body: ScopedRoleRevokeIn, user: TgUser = Depends(current_user)) -> Response:
    return _no_store(await store().rpc("revoke_role", {"p_actor": user.id, "p_grant_id": body.grant_id}))


@app.get("/api/admin/users/search")
async def admin_search_users(
    q: str = "",
    scope_node_id: int | None = None,
    limit: int = 15,
    user: TgUser = Depends(current_user),
) -> Response:
    rows = await store().rpc("search_users_for_role", {
        "p_actor": user.id,
        "p_query": q[:80],
        "p_scope_node_id": scope_node_id,
        "p_limit": max(1, min(limit, 30)),
    })
    return _no_store({"users": rows or []})


@app.get("/api/admin/roles/invites")
async def admin_list_role_invites(
    root_id: int | None = None,
    user: TgUser = Depends(current_user),
) -> Response:
    invites = await store().rpc("list_role_invites", {"p_actor": user.id, "p_root_id": root_id})
    return _no_store({"invites": invites or []})


@app.post("/api/admin/roles/invites")
async def admin_create_role_invite(
    body: RoleInviteCreateIn,
    user: TgUser = Depends(current_user),
) -> Response:
    token = generate_invite_token()
    token_hash = hash_invite_token(token)
    res = await store().rpc("create_role_invite", {
        "p_actor": user.id,
        "p_token_hash": token_hash,
        "p_role": body.role,
        "p_scope_node_id": body.scope_node_id,
        "p_ttl_hours": body.ttl_hours,
        "p_note": body.note,
    })
    if isinstance(res, dict) and res.get("status") == "ok":
        res = {**res, "url": build_invite_link(settings().bot_username, token), "token": token}
    return _no_store(res)


@app.post("/api/admin/roles/invites/revoke")
async def admin_revoke_role_invite(
    body: RoleInviteRevokeIn,
    user: TgUser = Depends(current_user),
) -> Response:
    return _no_store(await store().rpc("revoke_role_invite", {"p_actor": user.id, "p_invite_id": body.invite_id}))
