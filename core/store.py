"""طبقة الوصول للقاعدة: PostgREST (Supabase) عبر HTTP مع اتصال مُعاد استخدامه.
اختيار HTTP بدل اتصال Postgres مباشر لأنه يعمل على Vercel دون حدّ اتصالات، ويُعاد استخدامه في البوت.
كل عملية متعددة الخطوات تُنفَّذ كدالة SQL واحدة (RPC) لتكون ذرّية وبرحلة واحدة."""
from __future__ import annotations

import asyncio
from typing import Any

import httpx


class StoreError(Exception):
    def __init__(self, message: str, status: int | None = None, code: str | None = None) -> None:
        super().__init__(message)
        self.status = status
        self.code = code

    @property
    def forbidden(self) -> bool:
        return self.status == 403 or self.code == "42501"


class Store:
    def __init__(self, url: str, service_key: str, timeout: float = 8.0, retries: int = 2) -> None:
        self._url = url.rstrip("/")
        self._service_key = service_key
        self._timeout = timeout
        self._retries = retries
        self._loop: asyncio.AbstractEventLoop | None = None
        self._client = self._make_client()

    def _make_client(self) -> httpx.AsyncClient:
        try:
            self._loop = asyncio.get_running_loop()
        except RuntimeError:
            self._loop = None
        return httpx.AsyncClient(
            base_url=f"{self._url}/rest/v1",
            headers={"apikey": self._service_key, "Authorization": f"Bearer {self._service_key}",
                     "Content-Type": "application/json"},
            timeout=httpx.Timeout(self._timeout, connect=4.0),
            limits=httpx.Limits(max_keepalive_connections=10, keepalive_expiry=25),
        )

    def _get_client(self) -> httpx.AsyncClient:
        try:
            cur_loop = asyncio.get_running_loop()
        except RuntimeError:
            cur_loop = None
        if self._client.is_closed or (cur_loop is not None and self._loop is not None and cur_loop is not self._loop):
            self._client = self._make_client()
        elif self._loop is None and cur_loop is not None:
            self._loop = cur_loop
        return self._client

    async def aclose(self) -> None:
        if not self._client.is_closed:
            await self._client.aclose()

    async def _request(self, method: str, path: str, **kwargs: Any) -> Any:
        last: Exception | None = None
        for attempt in range(self._retries + 1):
            client = self._get_client()
            try:
                resp = await client.request(method, path, **kwargs)
            except (httpx.TimeoutException, httpx.TransportError, RuntimeError) as exc:
                last = exc
                # في بيئة Vercel Serverless قد يُغلق الـ Event Loop أو الـ Socket بين الطلبات؛ نعيد إنشاء العميل فوراً
                self._client = self._make_client()
                if method.upper() != "GET" and not isinstance(exc, (httpx.ConnectError, httpx.ConnectTimeout, RuntimeError)):
                    break
            else:
                if resp.status_code < 400:
                    return resp.json() if resp.content else None
                if resp.status_code < 500:  # خطأ منّا لا يُعاد
                    try:
                        body = resp.json()
                    except ValueError:
                        body = {}
                    raise StoreError(body.get("message", resp.text[:200]), resp.status_code, body.get("code"))
                last = StoreError(f"خطأ خادم {resp.status_code}", resp.status_code)
                if method.upper() != "GET" and resp.status_code in (502, 504):
                    break   # مهلة بوابة: قد تكون العملية نُفِّذت
            if attempt < self._retries:
                await asyncio.sleep(0.15 * (2 ** attempt))
        raise StoreError(f"تعذّر الاتصال بالقاعدة: {last}") from last

    async def rpc(self, name: str, params: dict[str, Any] | None = None) -> Any:
        return await self._request("POST", f"/rpc/{name}", json=params or {})

    async def select(self, table: str, params: dict[str, str] | None = None) -> list[dict[str, Any]]:
        return await self._request("GET", f"/{table}", params=params or {})

    # ---- اختصارات للمرحلة 1 ----
    async def bootstrap(
        self,
        tg_id: int,
        name: str | None,
        username: str | None,
        cohort_node_id: int | None = None,
    ) -> dict[str, Any]:
        params: dict[str, Any] = {"p_tg": tg_id, "p_name": name, "p_username": username}
        if cohort_node_id is not None:
            params["p_cohort_node_id"] = cohort_node_id
        return await self.rpc("app_bootstrap", params)

    async def versions(self) -> dict[str, int]:
        rows = await self.select("data_versions", {"select": "scope,version"})
        return {r["scope"]: r["version"] for r in rows}

    async def lookup_student(self, tg_id: int, academic_no: str) -> dict[str, Any]:
        return await self.rpc("lookup_student", {"p_tg": tg_id, "p_no": academic_no})

    async def link_student(self, tg_id: int, academic_no: str, username: str | None) -> dict[str, Any]:
        return await self.rpc("link_student", {"p_tg": tg_id, "p_no": academic_no, "p_username": username})

    async def register_guest(self, tg_id: int, name: str, username: str | None) -> dict[str, Any]:
        return await self.rpc("register_guest", {"p_tg": tg_id, "p_name": name, "p_username": username})

    # ---- شجرة النطاق ومنح الأدوار بنطاق (Phase C) ----
    async def list_scope_nodes(self) -> list[dict[str, Any]]:
        return await self.select(
            "scope_nodes",
            {
                "select": "id,kind,parent_id,code,name_ar,path,meta,sort,is_active",
                "deleted_at": "is.null",
                "order": "sort,id",
            },
        )

    async def list_scope_tree(self, actor_id: int, root_id: int | None = None) -> list[dict[str, Any]]:
        return await self.rpc("list_scope_tree", {"p_actor": actor_id, "p_root_id": root_id})

    async def create_scope_node(
        self,
        actor_id: int,
        parent_id: int | None,
        kind: str,
        code: str,
        name_ar: str,
        meta: dict[str, Any] | None = None,
        sort: int = 0,
    ) -> dict[str, Any]:
        return await self.rpc(
            "create_scope_node",
            {
                "p_actor": actor_id,
                "p_parent_id": parent_id,
                "p_kind": kind,
                "p_code": code,
                "p_name_ar": name_ar,
                "p_meta": meta or {},
                "p_sort": sort,
            },
        )

    async def update_scope_node(
        self,
        actor_id: int,
        node_id: int,
        *,
        name_ar: str | None = None,
        meta: dict[str, Any] | None = None,
        sort: int | None = None,
        is_active: bool | None = None,
    ) -> dict[str, Any]:
        return await self.rpc(
            "update_scope_node",
            {
                "p_actor": actor_id,
                "p_node_id": node_id,
                "p_name_ar": name_ar,
                "p_meta": meta,
                "p_sort": sort,
                "p_is_active": is_active,
            },
        )

    async def set_active_cohort(self, tg_id: int, cohort_node_id: int) -> dict[str, Any]:
        return await self.rpc("set_active_cohort", {"p_tg": tg_id, "p_cohort_node_id": cohort_node_id})

    async def grant_role_scoped(
        self,
        actor_id: int,
        target_id: int,
        role: str,
        scope_node_id: int | None = None,
    ) -> dict[str, Any]:
        return await self.rpc(
            "grant_role_scoped",
            {
                "p_actor": actor_id,
                "p_target": target_id,
                "p_role": role,
                "p_scope_node_id": scope_node_id,
            },
        )
