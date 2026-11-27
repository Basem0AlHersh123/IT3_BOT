-- =====================================================================
-- 0019_scoped_role_grants.sql — Phase C (Ticket C3): Scoped Role Grants & Ancestry Permissions
-- Implements ADR-0003: Scoped Role Grants (telegram_id, role, scope_node_id)
-- with downward inheritance through scope_nodes.path and anti-escalation guards.
-- Append-only, idempotent (safe to re-run). ONE-WAY DOOR migration.
-- =====================================================================

-- ---------- 1. Extend role_grants & Backfill scope_node_id ----------
alter table role_grants
  add column if not exists scope_node_id bigint references scope_nodes(id);

-- Backfill existing single-cohort group grants to their theory_group scope node
update role_grants rg
   set scope_node_id = tg.scope_node_id
  from theory_groups tg
 where rg.role <> 'developer'
   and rg.theory_group_id = tg.id
   and rg.scope_node_id is null
   and tg.scope_node_id is not null;

-- Drop legacy unnamed/named check constraints on role_grants & role_permissions safely
do $$
declare
  r record;
begin
  for r in
    select conname
      from pg_constraint
     where conrelid = 'public.role_grants'::regclass
       and contype = 'c'
  loop
    execute format('alter table public.role_grants drop constraint if exists %I', r.conname);
  end loop;

  for r in
    select conname
      from pg_constraint
     where conrelid = 'public.role_permissions'::regclass
       and contype = 'c'
  loop
    execute format('alter table public.role_permissions drop constraint if exists %I', r.conname);
  end loop;
end $$;

alter table role_grants
  add constraint role_grants_role_chk
    check (role in ('deputy','delegate','committee','group_rep','cohort_admin','college_admin','developer')),
  add constraint role_grants_scope_chk
    check ((role = 'developer' and scope_node_id is null)
        or (role <> 'developer' and scope_node_id is not null));

alter table role_permissions
  add constraint role_permissions_role_chk
    check (role in ('guest','student','deputy','delegate','committee','group_rep','cohort_admin','college_admin','doctor','developer')),
  add constraint role_permissions_scope_chk
    check (scope in ('own','group','cohort','college','any'));

-- Replace legacy active uniqueness index with scope_node_id-based index
drop index if exists role_grants_active_uq;
create unique index if not exists role_grants_active_uq
  on role_grants (telegram_id, role, coalesce(scope_node_id, 0)) where revoked_at is null;

create index if not exists role_grants_scope_node_idx
  on role_grants (scope_node_id) where revoked_at is null;

-- ---------- 2. Seed Permissions for Scoped Roles ----------
insert into role_permissions (role, permission, scope, condition) values
  -- Scope Tree management
  ('developer',     'scopes.view',   'any',     null),
  ('developer',     'scopes.manage', 'any',     null),
  ('college_admin', 'scopes.view',   'college', null),
  ('college_admin', 'scopes.manage', 'college', null),
  ('cohort_admin',  'scopes.view',   'cohort',  null),
  ('cohort_admin',  'scopes.manage', 'cohort',  null),

  -- College Admin (full management inside their College)
  ('college_admin', 'files.view',           'college', null),
  ('college_admin', 'files.upload',         'college', null),
  ('college_admin', 'files.delete',         'college', null),
  ('college_admin', 'mcq.take',             'college', null),
  ('college_admin', 'mcq.upload',           'college', null),
  ('college_admin', 'assistant.use',        'own',     null),
  ('college_admin', 'assignments.create',   'college', null),
  ('college_admin', 'assignments.manage',   'college', null),
  ('college_admin', 'grievances.open',      'college', null),
  ('college_admin', 'notify.send',          'college', null),
  ('college_admin', 'reports.write',        'college', null),
  ('college_admin', 'sharek.publish',       'college', null),
  ('college_admin', 'attendance.session',   'college', null),
  ('college_admin', 'attendance.scan',      'college', null),
  ('college_admin', 'attendance.admin',     'college', null),
  ('college_admin', 'students.view',        'college', null),
  ('college_admin', 'students.manage',      'college', null),
  ('college_admin', 'guests.manage',        'college', null),
  ('college_admin', 'roles.manage',         'college', null),
  ('college_admin', 'activity.view',        'college', null),
  ('college_admin', 'communities.manage',   'college', null),
  ('college_admin', 'tickets.reply',        'college', null),

  -- Cohort Admin (full management inside their Cohort and descendant groups)
  ('cohort_admin',  'files.view',           'cohort',  null),
  ('cohort_admin',  'files.upload',         'cohort',  null),
  ('cohort_admin',  'files.delete',         'cohort',  null),
  ('cohort_admin',  'mcq.take',             'cohort',  null),
  ('cohort_admin',  'mcq.upload',           'cohort',  null),
  ('cohort_admin',  'assistant.use',        'own',     null),
  ('cohort_admin',  'assignments.create',   'cohort',  null),
  ('cohort_admin',  'assignments.manage',   'cohort',  null),
  ('cohort_admin',  'grievances.open',      'cohort',  null),
  ('cohort_admin',  'notify.send',          'cohort',  null),
  ('cohort_admin',  'reports.write',        'cohort',  null),
  ('cohort_admin',  'sharek.publish',       'cohort',  null),
  ('cohort_admin',  'attendance.session',   'cohort',  null),
  ('cohort_admin',  'attendance.scan',      'cohort',  null),
  ('cohort_admin',  'attendance.admin',     'cohort',  null),
  ('cohort_admin',  'students.view',        'cohort',  null),
  ('cohort_admin',  'students.manage',      'cohort',  null),
  ('cohort_admin',  'roles.manage',         'cohort',  null),
  ('cohort_admin',  'activity.view',        'cohort',  null),
  ('cohort_admin',  'communities.manage',   'cohort',  null),
  ('cohort_admin',  'tickets.reply',        'cohort',  null),

  -- Group Rep (canonical group-level role for Theory Group or Practical Group)
  ('group_rep',     'files.view',           'any',     null),
  ('group_rep',     'mcq.take',             'any',     null),
  ('group_rep',     'assistant.use',        'own',     null),
  ('group_rep',     'assignments.submit',   'own',     null),
  ('group_rep',     'sharek.participate',   'own',     null),
  ('group_rep',     'attendance.view_mine', 'own',     null),
  ('group_rep',     'affairs.use',          'own',     null),
  ('group_rep',     'assignments.create',   'group',   null),
  ('group_rep',     'assignments.manage',   'group',   null),
  ('group_rep',     'grievances.open',      'group',   null),
  ('group_rep',     'notify.send',          'group',   null),
  ('group_rep',     'sharek.publish',       'group',   null),
  ('group_rep',     'attendance.session',   'group',   null),
  ('group_rep',     'attendance.scan',      'group',   null),
  ('group_rep',     'attendance.admin',     'group',   null)
on conflict (role, permission) do update
   set scope = excluded.scope, condition = excluded.condition;

-- ---------- 3. Role Hierarchy & Node-Kind Helpers ----------
create or replace function role_rank(p_role text) returns smallint
language sql immutable as $$
  select case p_role
    when 'developer'     then 100
    when 'college_admin' then 80
    when 'cohort_admin'  then 60
    when 'delegate'      then 40
    when 'committee'     then 40
    when 'group_rep'     then 40
    when 'deputy'        then 20
    else 0
  end::smallint;
$$;

create or replace function role_allowed_on_kind(p_role text, p_kind text) returns boolean
language sql immutable as $$
  select case p_role
    when 'developer'     then p_kind is null
    when 'college_admin' then p_kind = 'college'
    when 'cohort_admin'  then p_kind = 'cohort'
    when 'delegate'      then p_kind in ('cohort', 'theory_group')
    when 'committee'     then p_kind in ('cohort', 'theory_group')
    when 'deputy'        then p_kind in ('theory_group', 'practical_group')
    when 'group_rep'     then p_kind in ('theory_group', 'practical_group')
    else false
  end;
$$;

create or replace function actor_max_role_rank(p_actor bigint, p_scope_node_id bigint default null) returns smallint
language sql stable security definer set search_path = public as $$
  select coalesce(max(role_rank(gr.role)), 0)::smallint
    from role_grants gr
   where gr.telegram_id = p_actor
     and gr.revoked_at is null
     and (
       gr.role = 'developer'
       or p_scope_node_id is null
       or scope_is_ancestor(gr.scope_node_id, p_scope_node_id)
     );
$$;

-- ---------- 4. Ancestry-Aware Permission Evaluation ----------
create or replace function has_perm_scoped(
  p_tg              bigint,
  p_key             text,
  p_scope_node_id   bigint  default null,
  p_delegate_absent boolean default false
) returns boolean
language sql stable security definer set search_path = public as $$
  select not exists (select 1 from users where telegram_id = p_tg and is_banned)
     and exists (
    select 1 from (
      -- Base role (student / guest / doctor)
      select rp.scope,
             null::bigint as grant_node_id,
             rp.condition,
             false as is_dev,
             true  as is_base
        from role_permissions rp
       where rp.permission = p_key
         and rp.role = base_role(p_tg)
      union all
      -- Scoped Role Grants
      select rp.scope,
             gr.scope_node_id as grant_node_id,
             rp.condition,
             (gr.role = 'developer') as is_dev,
             false as is_base
        from role_grants gr
        join role_permissions rp on rp.role = gr.role
       where gr.telegram_id = p_tg
         and gr.revoked_at is null
         and rp.permission = p_key
    ) e
    where (e.condition is null or (e.condition = 'delegate_absent' and p_delegate_absent))
      and (
        e.is_dev
        or e.scope = 'own'
        or (e.is_base and e.scope = 'any')
        or p_scope_node_id is null
        or (e.grant_node_id is not null and scope_is_ancestor(e.grant_node_id, p_scope_node_id))
      )
  );
$$;

create or replace function require_perm_scoped(
  p_tg              bigint,
  p_key             text,
  p_scope_node_id   bigint  default null,
  p_delegate_absent boolean default false
) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not has_perm_scoped(p_tg, p_key, p_scope_node_id, p_delegate_absent) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
end $$;

-- Backward-compatible overload: resolves legacy text group code to scope_node_id
-- and delegates to has_perm_scoped so College/Cohort Admins inherit powers immediately.
create or replace function has_perm(
  p_tg              bigint,
  p_key             text,
  p_group           text    default null,
  p_delegate_absent boolean default false
) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare
  v_node bigint;
begin
  if p_group is not null then
    select coalesce(
      (select scope_node_id from practical_groups where code = p_group limit 1),
      (select scope_node_id from theory_groups where id = p_group limit 1)
    ) into v_node;
    if v_node is null then
      return false;
    end if;
  end if;
  return has_perm_scoped(p_tg, p_key, v_node, p_delegate_absent);
end $$;

create or replace function perm_scope(p_tg bigint, p_key text) returns text
language sql stable security definer set search_path = public as $$
  select (array_agg(s order by case s
    when 'any'     then 1
    when 'college' then 2
    when 'cohort'  then 3
    when 'group'   then 4
    else 5
  end))[1] from (
    select rp.scope as s from role_permissions rp
     where rp.permission = p_key and rp.role = base_role(p_tg) and rp.condition is null
    union all
    select rp.scope from role_grants gr join role_permissions rp on rp.role = gr.role
     where gr.telegram_id = p_tg and gr.revoked_at is null and rp.permission = p_key and rp.condition is null
  ) x;
$$;

-- ---------- 5. Scoped Role Grant & Revoke RPCs (Anti-Escalation) ----------
create or replace function grant_role_scoped(
  p_actor         bigint,
  p_target        bigint,
  p_role          text,
  p_scope_node_id bigint default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_node        scope_nodes%rowtype;
  v_actor_rank  smallint;
  v_target_rank smallint := role_rank(p_role);
  v_legacy_tg   text;
begin
  if p_role not in ('deputy','delegate','committee','group_rep','cohort_admin','college_admin','developer') then
    return jsonb_build_object('status', 'invalid_role');
  end if;

  if p_role = 'developer' then
    if not is_developer(p_actor) then
      raise exception 'forbidden' using errcode = '42501';
    end if;
    if p_scope_node_id is not null then
      return jsonb_build_object('status', 'invalid_scope');
    end if;
  else
    if p_scope_node_id is null then
      return jsonb_build_object('status', 'invalid_scope');
    end if;
    select * into v_node from scope_nodes where id = p_scope_node_id and deleted_at is null;
    if not found then
      return jsonb_build_object('status', 'invalid_scope');
    end if;
    if not role_allowed_on_kind(p_role, v_node.kind) then
      return jsonb_build_object('status', 'invalid_scope');
    end if;

    perform require_perm_scoped(p_actor, 'roles.manage', p_scope_node_id);

    v_actor_rank := actor_max_role_rank(p_actor, p_scope_node_id);
    if v_actor_rank <= v_target_rank then
      raise exception 'forbidden' using errcode = '42501';
    end if;

    if v_node.kind = 'theory_group' then
      select id into v_legacy_tg from theory_groups where scope_node_id = p_scope_node_id limit 1;
    end if;
  end if;

  if exists (
    select 1 from role_grants
     where telegram_id = p_target
       and role = p_role
       and coalesce(scope_node_id, 0) = coalesce(p_scope_node_id, 0)
       and revoked_at is null
  ) then
    return jsonb_build_object('status', 'exists');
  end if;

  insert into role_grants (telegram_id, role, theory_group_id, scope_node_id, granted_by)
  values (p_target, p_role, v_legacy_tg, p_scope_node_id, p_actor);

  insert into activity_log (actor_id, action, entity, entity_id, scope_node_id, meta)
  values (
    p_actor, 'role.grant', 'user', p_target::text, p_scope_node_id,
    jsonb_build_object('role', p_role, 'scope_node_id', p_scope_node_id)
  );

  return jsonb_build_object('status', 'ok');
end $$;

-- Update legacy grant_role to delegate cleanly to grant_role_scoped
create or replace function grant_role(p_actor bigint, p_target bigint, p_role text, p_group text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_node bigint;
begin
  if p_group is not null then
    select scope_node_id into v_node from theory_groups where id = p_group limit 1;
    if v_node is null then
      return jsonb_build_object('status', 'invalid_group');
    end if;
  end if;
  return grant_role_scoped(p_actor, p_target, p_role, v_node);
end $$;

create or replace function revoke_role(p_actor bigint, p_grant_id bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  g            role_grants%rowtype;
  v_actor_rank smallint;
begin
  select * into g from role_grants where id = p_grant_id and revoked_at is null;
  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;

  if g.role = 'developer' then
    perform require_developer(p_actor);
    if (select count(*) from role_grants where role = 'developer' and revoked_at is null) <= 1 then
      return jsonb_build_object('status', 'last_developer');
    end if;
  else
    perform require_perm_scoped(p_actor, 'roles.manage', g.scope_node_id);
    v_actor_rank := actor_max_role_rank(p_actor, g.scope_node_id);
    if v_actor_rank <= role_rank(g.role) then
      raise exception 'forbidden' using errcode = '42501';
    end if;
  end if;

  update role_grants set revoked_at = now(), revoked_by = p_actor where id = p_grant_id;

  insert into activity_log (actor_id, action, entity, entity_id, scope_node_id, meta)
  values (
    p_actor, 'role.revoke', 'user', g.telegram_id::text, g.scope_node_id,
    jsonb_build_object('role', g.role, 'scope_node_id', g.scope_node_id)
  );

  return jsonb_build_object('status', 'ok');
end $$;

-- ---------- 6. Scope Tree Management RPCs ----------
create or replace function create_scope_node(
  p_actor     bigint,
  p_parent_id bigint,
  p_kind      text,
  p_code      text,
  p_name_ar   text,
  p_meta      jsonb    default '{}',
  p_sort      smallint default 0
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_row scope_nodes%rowtype;
begin
  if p_parent_id is null then
    perform require_developer(p_actor);
  else
    perform require_perm_scoped(p_actor, 'scopes.manage', p_parent_id);
  end if;

  insert into scope_nodes (kind, parent_id, code, name_ar, meta, sort)
  values (p_kind, p_parent_id, p_code, p_name_ar, coalesce(p_meta, '{}'::jsonb), coalesce(p_sort, 0))
  returning * into v_row;

  insert into activity_log (actor_id, action, entity, entity_id, scope_node_id, meta)
  values (
    p_actor, 'scope.create', 'scope_node', v_row.id::text, v_row.id,
    jsonb_build_object('kind', v_row.kind, 'code', v_row.code, 'parent_id', v_row.parent_id)
  );

  return jsonb_build_object(
    'status', 'ok',
    'node', jsonb_build_object(
      'id', v_row.id, 'kind', v_row.kind, 'parent_id', v_row.parent_id,
      'code', v_row.code, 'name_ar', v_row.name_ar, 'path', to_jsonb(v_row.path),
      'meta', v_row.meta, 'sort', v_row.sort
    )
  );
end $$;

create or replace function update_scope_node(
  p_actor     bigint,
  p_node_id   bigint,
  p_name_ar   text     default null,
  p_meta      jsonb    default null,
  p_sort      smallint default null,
  p_is_active boolean  default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_row scope_nodes%rowtype;
begin
  perform require_perm_scoped(p_actor, 'scopes.manage', p_node_id);

  update scope_nodes
     set name_ar   = coalesce(nullif(trim(p_name_ar), ''), name_ar),
         meta      = coalesce(p_meta, meta),
         sort      = coalesce(p_sort, sort),
         is_active = coalesce(p_is_active, is_active)
   where id = p_node_id and deleted_at is null
  returning * into v_row;

  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;

  insert into activity_log (actor_id, action, entity, entity_id, scope_node_id, meta)
  values (
    p_actor, 'scope.update', 'scope_node', v_row.id::text, v_row.id,
    jsonb_build_object('name_ar', v_row.name_ar, 'is_active', v_row.is_active)
  );

  return jsonb_build_object(
    'status', 'ok',
    'node', jsonb_build_object(
      'id', v_row.id, 'kind', v_row.kind, 'parent_id', v_row.parent_id,
      'code', v_row.code, 'name_ar', v_row.name_ar, 'path', to_jsonb(v_row.path),
      'meta', v_row.meta, 'sort', v_row.sort, 'is_active', v_row.is_active
    )
  );
end $$;

create or replace function list_scope_tree(p_actor bigint, p_root_id bigint default null) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', n.id,
    'kind', n.kind,
    'parent_id', n.parent_id,
    'code', n.code,
    'name_ar', n.name_ar,
    'path', to_jsonb(n.path),
    'meta', n.meta,
    'sort', n.sort,
    'is_active', n.is_active
  ) order by array_length(n.path, 1), n.sort, n.id), '[]'::jsonb)
  from scope_nodes n
  where n.deleted_at is null
    and (p_root_id is null or n.path @> array[p_root_id])
    and (
      is_developer(p_actor)
      or n.kind in ('college', 'major', 'cohort')
      or exists (
        select 1 from role_grants gr
         where gr.telegram_id = p_actor
           and gr.revoked_at is null
           and gr.scope_node_id is not null
           and n.path @> array[gr.scope_node_id]
      )
      or exists (
        select 1 from students s
         where s.telegram_id = p_actor
           and s.deleted_at is null
           and s.cohort_node_id is not null
           and n.path @> array[s.cohort_node_id]
      )
    );
$$;

-- ---------- 7. Security: Restrict Function Execution to service_role ----------
revoke execute on function public.role_rank(text) from public, anon, authenticated;
revoke execute on function public.role_allowed_on_kind(text, text) from public, anon, authenticated;
revoke execute on function public.actor_max_role_rank(bigint, bigint) from public, anon, authenticated;
revoke execute on function public.has_perm_scoped(bigint, text, bigint, boolean) from public, anon, authenticated;
revoke execute on function public.require_perm_scoped(bigint, text, bigint, boolean) from public, anon, authenticated;
revoke execute on function public.has_perm(bigint, text, text, boolean) from public, anon, authenticated;
revoke execute on function public.perm_scope(bigint, text) from public, anon, authenticated;
revoke execute on function public.grant_role_scoped(bigint, bigint, text, bigint) from public, anon, authenticated;
revoke execute on function public.grant_role(bigint, bigint, text, text) from public, anon, authenticated;
revoke execute on function public.revoke_role(bigint, bigint) from public, anon, authenticated;
revoke execute on function public.create_scope_node(bigint, bigint, text, text, text, jsonb, smallint) from public, anon, authenticated;
revoke execute on function public.update_scope_node(bigint, bigint, text, jsonb, smallint, boolean) from public, anon, authenticated;
revoke execute on function public.list_scope_tree(bigint, bigint) from public, anon, authenticated;

grant execute on function public.role_rank(text) to service_role;
grant execute on function public.role_allowed_on_kind(text, text) to service_role;
grant execute on function public.actor_max_role_rank(bigint, bigint) to service_role;
grant execute on function public.has_perm_scoped(bigint, text, bigint, boolean) to service_role;
grant execute on function public.require_perm_scoped(bigint, text, bigint, boolean) to service_role;
grant execute on function public.has_perm(bigint, text, text, boolean) to service_role;
grant execute on function public.perm_scope(bigint, text) to service_role;
grant execute on function public.grant_role_scoped(bigint, bigint, text, bigint) to service_role;
grant execute on function public.grant_role(bigint, bigint, text, text) to service_role;
grant execute on function public.revoke_role(bigint, bigint) to service_role;
grant execute on function public.create_scope_node(bigint, bigint, text, text, text, jsonb, smallint) to service_role;
grant execute on function public.update_scope_node(bigint, bigint, text, jsonb, smallint, boolean) to service_role;
grant execute on function public.list_scope_tree(bigint, bigint) to service_role;
