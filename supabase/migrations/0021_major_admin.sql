-- =====================================================================
-- 0021_major_admin.sql — Phase D (Ticket D1): Add Major Admin Role & Scoped Roles Listing
-- Adds `major_admin` (head of a Major across all its Cohorts/levels, e.g. IT1–IT4)
-- between `college_admin` (80) and `cohort_admin` (60):
--   developer (100) > college_admin (80) > major_admin (70) > cohort_admin (60) > group roles (40/20)
-- Append-only, idempotent (safe to re-run). ONE-WAY DOOR migration.
-- =====================================================================

-- ---------- 1. Extend Role & Scope Check Constraints ----------
alter table role_grants drop constraint if exists role_grants_role_chk;
alter table role_grants
  add constraint role_grants_role_chk
    check (role in ('deputy','delegate','committee','group_rep','cohort_admin','major_admin','college_admin','developer'));

alter table role_permissions drop constraint if exists role_permissions_role_chk;
alter table role_permissions drop constraint if exists role_permissions_scope_chk;
alter table role_permissions
  add constraint role_permissions_role_chk
    check (role in ('guest','student','deputy','delegate','committee','group_rep','cohort_admin','major_admin','college_admin','doctor','developer')),
  add constraint role_permissions_scope_chk
    check (scope in ('own','group','cohort','major','college','any'));

-- ---------- 2. Seed Permissions for major_admin ----------
insert into role_permissions (role, permission, scope, condition) values
  ('major_admin', 'scopes.view',          'major', null),
  ('major_admin', 'scopes.manage',        'major', null),
  ('major_admin', 'files.view',           'major', null),
  ('major_admin', 'files.upload',         'major', null),
  ('major_admin', 'files.delete',         'major', null),
  ('major_admin', 'mcq.take',             'major', null),
  ('major_admin', 'mcq.upload',           'major', null),
  ('major_admin', 'assistant.use',        'own',   null),
  ('major_admin', 'assignments.create',   'major', null),
  ('major_admin', 'assignments.manage',   'major', null),
  ('major_admin', 'grievances.open',      'major', null),
  ('major_admin', 'notify.send',          'major', null),
  ('major_admin', 'reports.write',        'major', null),
  ('major_admin', 'sharek.publish',       'major', null),
  ('major_admin', 'attendance.session',   'major', null),
  ('major_admin', 'attendance.scan',      'major', null),
  ('major_admin', 'attendance.admin',     'major', null),
  ('major_admin', 'students.view',        'major', null),
  ('major_admin', 'students.manage',      'major', null),
  ('major_admin', 'guests.manage',        'major', null),
  ('major_admin', 'roles.manage',         'major', null),
  ('major_admin', 'activity.view',        'major', null),
  ('major_admin', 'communities.manage',   'major', null),
  ('major_admin', 'tickets.reply',        'major', null)
on conflict (role, permission) do update
   set scope = excluded.scope, condition = excluded.condition;

-- ---------- 3. Update Role Rank, Node-Kind Mapping, and Permission Scope Ordering ----------
create or replace function role_rank(p_role text) returns smallint
language sql immutable as $$
  select case p_role
    when 'developer'     then 100
    when 'college_admin' then 80
    when 'major_admin'   then 70
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
    when 'major_admin'   then p_kind = 'major'
    when 'cohort_admin'  then p_kind = 'cohort'
    when 'delegate'      then p_kind in ('cohort', 'theory_group')
    when 'committee'     then p_kind in ('cohort', 'theory_group')
    when 'deputy'        then p_kind in ('theory_group', 'practical_group')
    when 'group_rep'     then p_kind in ('theory_group', 'practical_group')
    else false
  end;
$$;

create or replace function perm_scope(p_tg bigint, p_key text) returns text
language sql stable security definer set search_path = public as $$
  select (array_agg(s order by case s
    when 'any'     then 1
    when 'college' then 2
    when 'major'   then 3
    when 'cohort'  then 4
    when 'group'   then 5
    else 6
  end))[1] from (
    select rp.scope as s from role_permissions rp
     where rp.permission = p_key and rp.role = base_role(p_tg) and rp.condition is null
    union all
    select rp.scope from role_grants gr join role_permissions rp on rp.role = gr.role
     where gr.telegram_id = p_tg and gr.revoked_at is null and rp.permission = p_key and rp.condition is null
  ) x;
$$;

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
  if p_role not in ('deputy','delegate','committee','group_rep','cohort_admin','major_admin','college_admin','developer') then
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

-- ---------- 4. Scoped Roles Listing RPC (for Developer & Sub-Admin Dashboard) ----------
create or replace function list_scoped_roles(p_actor bigint, p_root_id bigint default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform require_perm_scoped(p_actor, 'roles.manage', p_root_id);

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', g.id,
      'telegram_id', g.telegram_id,
      'name', coalesce(s.full_name, u.display_name, g.telegram_id::text),
      'username', u.username,
      'role', g.role,
      'group', g.theory_group_id,
      'scope_node_id', g.scope_node_id,
      'scope_kind', n.kind,
      'scope_code', n.code,
      'scope_name_ar', n.name_ar,
      'granted_at', g.granted_at
    ) order by role_rank(g.role) desc, g.id desc)
    from role_grants g
    left join scope_nodes n on n.id = g.scope_node_id
    left join users u on u.telegram_id = g.telegram_id
    left join students s on s.telegram_id = g.telegram_id and s.deleted_at is null
    where g.revoked_at is null
      and (p_root_id is null or (n.id is not null and n.path @> array[p_root_id]))
      and (
        is_developer(p_actor)
        or (g.scope_node_id is not null and has_perm_scoped(p_actor, 'roles.manage', g.scope_node_id))
      )
  ), '[]'::jsonb);
end $$;

-- ---------- 5. Security: Restrict Function Execution to service_role ----------
revoke execute on function public.role_rank(text) from public, anon, authenticated;
revoke execute on function public.role_allowed_on_kind(text, text) from public, anon, authenticated;
revoke execute on function public.perm_scope(bigint, text) from public, anon, authenticated;
revoke execute on function public.grant_role_scoped(bigint, bigint, text, bigint) from public, anon, authenticated;
revoke execute on function public.list_scoped_roles(bigint, bigint) from public, anon, authenticated;

grant execute on function public.role_rank(text) to service_role;
grant execute on function public.role_allowed_on_kind(text, text) to service_role;
grant execute on function public.perm_scope(bigint, text) to service_role;
grant execute on function public.grant_role_scoped(bigint, bigint, text, bigint) to service_role;
grant execute on function public.list_scoped_roles(bigint, bigint) to service_role;
