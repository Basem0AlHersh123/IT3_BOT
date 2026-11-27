-- =====================================================================
-- 0023_role_invites_and_user_search.sql
-- Zero-ID Role Onboarding (Option A + Option B):
--   A) search_users_for_role: search users by name, @username, academic_no,
--      or telegram_id so admins can pick users without asking for IDs.
--   B) role_invites table + create_role_invite / list_role_invites /
--      revoke_role_invite / claim_role_invite RPCs for single-use expiring
--      deep links (https://t.me/<bot>?start=inv_<token>), storing only
--      sha256 token hashes.
-- Append-only, idempotent. Safe to run after 0022_assignment_number_reuse.sql.
-- =====================================================================

-- 1) Role invites table (hashes only — never store raw invite tokens)
create table if not exists role_invites (
  id            bigint generated always as identity primary key,
  token_hash    text not null unique,
  role          text not null check (role in (
                  'deputy','delegate','committee','group_rep',
                  'cohort_admin','major_admin','college_admin','developer'
                )),
  scope_node_id bigint references scope_nodes(id),
  note          text,
  created_by    bigint not null,
  created_at    timestamptz not null default now(),
  expires_at    timestamptz not null,
  used_by       bigint,
  used_at       timestamptz,
  revoked_by    bigint,
  revoked_at    timestamptz,
  check ((role = 'developer' and scope_node_id is null)
      or (role <> 'developer' and scope_node_id is not null))
);

create index if not exists role_invites_active_idx
  on role_invites (expires_at desc)
  where used_at is null and revoked_at is null;

create index if not exists role_invites_scope_idx
  on role_invites (scope_node_id)
  where used_at is null and revoked_at is null;

alter table role_invites enable row level security;

-- 2) Register role_invites in backup_tables() in FK-safe order (after scope_nodes & role_grants)
create or replace function backup_tables() returns text[]
language sql immutable as $$
  select array[
    'app_settings', 'data_versions', 'scope_nodes', 'theory_groups', 'practical_groups', 'subjects', 'doctors', 'teaching',
    'tg_destinations', 'students', 'users', 'role_grants', 'role_invites', 'role_permissions', 'activity_log', 'link_attempts',
    'user_settings', 'notifications', 'drafts', 'files', 'assignments', 'assignment_files', 'submissions',
    'submission_files', 'submission_deliveries', 'reminders_sent', 'attendance_sessions', 'scanner_devices',
    'attendance_records', 'attendance_corrections', 'barcode_logs', 'grievance_cycles', 'grievances',
    'assistant_logs', 'support_tickets', 'report_templates', 'daily_reports', 'weekly_reports',
    'report_reminders_sent', 'sharek_campaigns', 'sharek_votes', 'sharek_items', 'sharek_sessions',
    'mcq_exams', 'mcq_questions', 'mcq_attempts'
  ];
$$;

-- 3) Option A: Search users by name, @username, academic_no, or telegram_id
create or replace function search_users_for_role(
  p_actor         bigint,
  p_query         text,
  p_scope_node_id bigint default null,
  p_limit         int default 15
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_q     text := trim(coalesce(p_query, ''));
  v_uname text := ltrim(v_q, '@');
  v_lim   int  := greatest(1, least(coalesce(p_limit, 15), 30));
  v_rows  jsonb;
begin
  perform require_perm_scoped(p_actor, 'roles.manage', p_scope_node_id);

  select coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb) into v_rows
    from (
      select
        u.telegram_id,
        coalesce(nullif(s.full_name, ''), nullif(u.display_name, ''), u.username, u.telegram_id::text) as name,
        u.display_name,
        u.username,
        u.kind,
        s.academic_no,
        s.theory_group_id,
        s.practical_group_id,
        s.cohort_node_id
      from users u
      left join students s on s.telegram_id = u.telegram_id and s.deleted_at is null
      where not u.is_banned
        and (
          v_q = ''
          or u.telegram_id::text like v_q || '%'
          or (v_uname <> '' and coalesce(u.username, '') ilike '%' || v_uname || '%')
          or coalesce(u.display_name, '') ilike '%' || v_q || '%'
          or coalesce(s.full_name, '') ilike '%' || v_q || '%'
          or coalesce(s.academic_no, '') ilike '%' || v_q || '%'
        )
      order by
        case
          when u.telegram_id::text = v_q then 0
          when v_uname <> '' and lower(coalesce(u.username, '')) = lower(v_uname) then 1
          when lower(coalesce(s.academic_no, '')) = lower(v_q) then 2
          else 3
        end,
        u.last_seen_at desc
      limit v_lim
    ) t;

  return v_rows;
end $$;

-- 4) Option B: Create a single-use expiring role invite (same anti-escalation as grant_role_scoped)
create or replace function create_role_invite(
  p_actor         bigint,
  p_token_hash    text,
  p_role          text,
  p_scope_node_id bigint default null,
  p_ttl_hours     int default 24,
  p_note          text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_node        scope_nodes%rowtype;
  v_actor_rank  smallint;
  v_target_rank smallint := role_rank(p_role);
  v_ttl         int := greatest(1, least(coalesce(p_ttl_hours, 24), 168));
  v_expires     timestamptz := now() + make_interval(hours => v_ttl);
  v_id          bigint;
begin
  if coalesce(length(trim(p_token_hash)), 0) < 32 then
    return jsonb_build_object('status', 'invalid_token');
  end if;

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
  end if;

  insert into role_invites (token_hash, role, scope_node_id, note, created_by, expires_at)
  values (trim(p_token_hash), p_role, p_scope_node_id, nullif(left(trim(coalesce(p_note, '')), 120), ''), p_actor, v_expires)
  returning id into v_id;

  perform log_activity(p_actor, 'role_invite.create', 'role_invite', v_id::text,
                       jsonb_build_object('role', p_role, 'scope_node_id', p_scope_node_id, 'expires_at', v_expires));
  return jsonb_build_object('status', 'ok', 'id', v_id, 'role', p_role, 'scope_node_id', p_scope_node_id, 'expires_at', v_expires);
end $$;

-- 5) List pending (unused, unrevoked, unexpired) invites within the actor's managed subtree
create or replace function list_role_invites(
  p_actor   bigint,
  p_root_id bigint default null
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_is_dev boolean := is_developer(p_actor);
  v_rows   jsonb;
begin
  perform require_perm_scoped(p_actor, 'roles.manage', p_root_id);

  select coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb) into v_rows
    from (
      select
        ri.id,
        ri.role,
        ri.scope_node_id,
        sn.kind    as scope_kind,
        sn.code    as scope_code,
        sn.name_ar as scope_name,
        ri.note,
        ri.created_by,
        ri.created_at,
        ri.expires_at
      from role_invites ri
      left join scope_nodes sn on sn.id = ri.scope_node_id
      where ri.used_at is null
        and ri.revoked_at is null
        and ri.expires_at > now()
        and (
          v_is_dev
          or (ri.scope_node_id is not null and has_perm_scoped(p_actor, 'roles.manage', ri.scope_node_id))
        )
        and (
          p_root_id is null
          or (ri.scope_node_id is not null and scope_is_ancestor(p_root_id, ri.scope_node_id))
        )
      order by ri.created_at desc
      limit 50
    ) t;

  return v_rows;
end $$;

-- 6) Revoke a pending role invite
create or replace function revoke_role_invite(
  p_actor     bigint,
  p_invite_id bigint
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  ri role_invites%rowtype;
begin
  select * into ri from role_invites where id = p_invite_id and used_at is null and revoked_at is null for update;
  if not found then
    return jsonb_build_object('status', 'not_found');
  end if;

  if ri.role = 'developer' then
    if not is_developer(p_actor) then
      raise exception 'forbidden' using errcode = '42501';
    end if;
  else
    perform require_perm_scoped(p_actor, 'roles.manage', ri.scope_node_id);
  end if;

  update role_invites set revoked_at = now(), revoked_by = p_actor where id = p_invite_id;
  perform log_activity(p_actor, 'role_invite.revoke', 'role_invite', p_invite_id::text,
                       jsonb_build_object('role', ri.role, 'scope_node_id', ri.scope_node_id));
  return jsonb_build_object('status', 'ok');
end $$;

-- 7) Atomic single-use claim when recipient taps https://t.me/<bot>?start=inv_<token>
create or replace function claim_role_invite(
  p_tg           bigint,
  p_token_hash   text,
  p_display_name text default null,
  p_username     text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  ri          role_invites%rowtype;
  v_node      scope_nodes%rowtype;
  v_banned    boolean;
  v_legacy_tg text;
begin
  select is_banned into v_banned from users where telegram_id = p_tg;
  if coalesce(v_banned, false) then
    return jsonb_build_object('status', 'banned');
  end if;

  select * into ri from role_invites where token_hash = trim(coalesce(p_token_hash, '')) for update;
  if not found then
    return jsonb_build_object('status', 'invalid');
  end if;
  if ri.revoked_at is not null then
    return jsonb_build_object('status', 'revoked');
  end if;
  if ri.used_at is not null then
    return jsonb_build_object('status', 'used');
  end if;
  if ri.expires_at <= now() then
    return jsonb_build_object('status', 'expired');
  end if;

  if ri.scope_node_id is not null then
    select * into v_node from scope_nodes where id = ri.scope_node_id and deleted_at is null;
    if not found then
      return jsonb_build_object('status', 'invalid');
    end if;
    if v_node.kind = 'theory_group' and exists (select 1 from theory_groups where id = v_node.code) then
      v_legacy_tg := v_node.code;
    end if;
  end if;

  -- Ensure recipient exists in users (promote 'new' -> 'guest' so they can immediately open the Mini App)
  insert into users (telegram_id, kind, display_name, username)
  values (p_tg, 'guest', nullif(trim(coalesce(p_display_name, '')), ''), nullif(trim(coalesce(p_username, '')), ''))
  on conflict (telegram_id) do update
    set kind = case when users.kind = 'new' then 'guest' else users.kind end,
        display_name = coalesce(nullif(trim(coalesce(p_display_name, '')), ''), users.display_name),
        username = coalesce(nullif(trim(coalesce(p_username, '')), ''), users.username),
        last_seen_at = now();

  -- Grant the role (idempotent if already held)
  insert into role_grants (telegram_id, role, theory_group_id, scope_node_id, granted_by)
  values (p_tg, ri.role, v_legacy_tg, ri.scope_node_id, ri.created_by)
  on conflict do nothing;

  update role_invites set used_by = p_tg, used_at = now() where id = ri.id;

  perform log_activity(p_tg, 'role_invite.claim', 'role_invite', ri.id::text,
                       jsonb_build_object('role', ri.role, 'scope_node_id', ri.scope_node_id, 'created_by', ri.created_by));

  return jsonb_build_object(
    'status', 'ok',
    'role', ri.role,
    'scope_node_id', ri.scope_node_id,
    'scope_kind', v_node.kind,
    'scope_code', v_node.code,
    'scope_name', v_node.name_ar
  );
end $$;

revoke execute on function search_users_for_role(bigint, text, bigint, int) from public, anon, authenticated;
grant execute on function search_users_for_role(bigint, text, bigint, int) to service_role;
revoke execute on function create_role_invite(bigint, text, text, bigint, int, text) from public, anon, authenticated;
grant execute on function create_role_invite(bigint, text, text, bigint, int, text) to service_role;
revoke execute on function list_role_invites(bigint, bigint) from public, anon, authenticated;
grant execute on function list_role_invites(bigint, bigint) to service_role;
revoke execute on function revoke_role_invite(bigint, bigint) from public, anon, authenticated;
grant execute on function revoke_role_invite(bigint, bigint) to service_role;
revoke execute on function claim_role_invite(bigint, text, text, text) from public, anon, authenticated;
grant execute on function claim_role_invite(bigint, text, text, text) to service_role;
revoke all on sequence role_invites_id_seq from anon, authenticated;
