-- =====================================================================
-- 0024_practical_attendance.sql
-- Practical-Group Attendance with Strict Group Isolation:
--   1. Adds `part` ('theory'|'practical'), `practical_group_id`, and
--      `scope_node_id` to `attendance_sessions` (backfilled for existing
--      theory sessions).
--   2. Replaces theory-only unique indexes so each theory group AND each
--      practical group can run independent attendance sessions concurrently.
--   3. Upgrades `open_attendance_session_scoped`, `scan_attendance`, and
--      `attendance_matrix` so a practical `group_rep` (e.g. G1) can ONLY
--      open, scan, and view students in their own practical group, while a
--      theory `delegate` only sees their theory group.
-- Append-only, idempotent. Safe to run after 0023_role_invites_and_user_search.sql.
-- =====================================================================

alter table attendance_sessions
  add column if not exists part text not null default 'theory' check (part in ('theory','practical')),
  add column if not exists practical_group_id text references practical_groups(code),
  add column if not exists scope_node_id bigint references scope_nodes(id);

update attendance_sessions
   set scope_node_id = theory_node_id
 where scope_node_id is null and theory_node_id is not null;

-- Drop old theory-only unique constraints (0003 & 0018) so practical groups can hold parallel sessions
alter table attendance_sessions
  drop constraint if exists attendance_sessions_subject_id_theory_group_id_lecture_no_key;

drop index if exists attendance_one_open_per_group_uq;
drop index if exists attendance_sessions_scope_lecture_uq;
drop index if exists attendance_one_open_per_theory_node_uq;

create unique index if not exists attendance_sessions_scoped_lecture_uq
  on attendance_sessions (
    subject_id,
    part,
    coalesce(scope_node_id, 0),
    theory_group_id,
    coalesce(practical_group_id, ''),
    lecture_no
  );

create unique index if not exists attendance_one_open_per_scope_uq
  on attendance_sessions (
    part,
    coalesce(scope_node_id, 0),
    theory_group_id,
    coalesce(practical_group_id, '')
  )
  where status = 'open';

create index if not exists attendance_sessions_scope_node_idx
  on attendance_sessions (scope_node_id, subject_id, lecture_no);

-- 0) Auto-sync dynamically created theory_group / practical_group scope_nodes into legacy
--    theory_groups / practical_groups tables so admins managing groups from the Mini App UI
--    never need to edit .env / COHORT_CONFIG_JSON or run manual SQL.
create or replace function trg_scope_nodes_sync_legacy_groups() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_parent_code text;
begin
  if new.deleted_at is not null then
    return new;
  end if;
  if new.kind = 'theory_group' then
    insert into theory_groups (id, sort, scope_node_id)
    values (new.code, new.sort, new.id)
    on conflict (id) do update
      set scope_node_id = coalesce(theory_groups.scope_node_id, excluded.scope_node_id);
  elsif new.kind = 'practical_group' and new.parent_id is not null then
    select code into v_parent_code from scope_nodes where id = new.parent_id and kind = 'theory_group';
    if v_parent_code is not null then
      insert into theory_groups (id, sort, scope_node_id)
      values (v_parent_code, 0, new.parent_id)
      on conflict (id) do nothing;

      insert into practical_groups (code, theory_group_id, sort, scope_node_id)
      values (new.code, v_parent_code, new.sort, new.id)
      on conflict (code) do nothing;
    end if;
  end if;
  return new;
end $$;

drop trigger if exists scope_nodes_sync_legacy_groups on scope_nodes;
create trigger scope_nodes_sync_legacy_groups
  after insert or update of code, parent_id, sort on scope_nodes
  for each row execute function trg_scope_nodes_sync_legacy_groups();

-- 1) Open attendance session for EITHER a theory_group OR a practical_group scope node
create or replace function open_attendance_session_scoped(
  p_actor           bigint,
  p_subject_id      smallint,
  p_theory_node_id  bigint,   -- accepts theory_group OR practical_group scope_node_id
  p_lecture_no      smallint,
  p_delegate_absent boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_node       scope_nodes%rowtype;
  v_parent     scope_nodes%rowtype;
  v_cohort     bigint := scope_cohort_of(p_theory_node_id);
  v_part       text;
  v_theory_cd  text;
  v_theory_nid bigint;
  v_prac_cd    text;
  v_session    attendance_sessions%rowtype;
begin
  perform require_perm_scoped(p_actor, 'attendance.session', p_theory_node_id, p_delegate_absent);

  select * into v_node
    from scope_nodes
   where id = p_theory_node_id
     and kind in ('theory_group', 'practical_group')
     and is_active
     and deleted_at is null;
  if not found then
    return jsonb_build_object('status', 'invalid_scope');
  end if;

  if v_node.kind = 'theory_group' then
    v_part := 'theory';
    v_theory_cd := v_node.code;
    v_theory_nid := v_node.id;
    v_prac_cd := null;
  else
    v_part := 'practical';
    v_prac_cd := v_node.code;
    select * into v_parent from scope_nodes where id = v_node.parent_id and kind = 'theory_group' and deleted_at is null;
    if not found then
      return jsonb_build_object('status', 'invalid_scope');
    end if;
    v_theory_cd := v_parent.code;
    v_theory_nid := v_parent.id;
  end if;

  if not exists (
    select 1 from subjects
     where id = p_subject_id and cohort_node_id = v_cohort and is_active and deleted_at is null
  ) then
    return jsonb_build_object('status', 'invalid_subject');
  end if;

  if exists (
    select 1 from attendance_sessions
     where part = v_part
       and coalesce(scope_node_id, 0) = v_node.id
       and status = 'open'
  ) then
    return jsonb_build_object('status', 'already_open');
  end if;

  insert into attendance_sessions (
    subject_id, part, theory_group_id, practical_group_id,
    cohort_node_id, theory_node_id, scope_node_id,
    lecture_no, delegate_absent, opened_by
  )
  values (
    p_subject_id, v_part, v_theory_cd, v_prac_cd,
    v_cohort, v_theory_nid, v_node.id,
    p_lecture_no, coalesce(p_delegate_absent, false), p_actor
  )
  on conflict do nothing
  returning * into v_session;

  if v_session.id is null then
    return jsonb_build_object('status', 'lecture_exists');
  end if;

  perform log_activity(
    p_actor, 'attendance.open', 'attendance_session', v_session.id::text,
    jsonb_build_object('part', v_part, 'group', coalesce(v_prac_cd, v_theory_cd), 'scope_node_id', v_node.id, 'lecture_no', p_lecture_no)
  );
  return jsonb_build_object(
    'status', 'ok',
    'session_id', v_session.id,
    'part', v_part,
    'group', coalesce(v_prac_cd, v_theory_cd),
    'scope_node_id', v_node.id
  );
end $$;

-- 2) Scan attendance: strictly enforces theory OR practical group membership
create or replace function scan_attendance(
  p_actor       bigint,
  p_session     bigint,
  p_academic_no text
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  sess      attendance_sessions%rowtype;
  st        students%rowtype;
  rec       attendance_records%rowtype;
  v_present int;
  v_scope   bigint;
begin
  select * into sess from attendance_sessions where id = p_session;
  if not found then return jsonb_build_object('status', 'not_found'); end if;

  v_scope := coalesce(sess.scope_node_id, sess.theory_node_id);
  if v_scope is not null then
    perform require_perm_scoped(p_actor, 'attendance.scan', v_scope);
  else
    perform require_perm(p_actor, 'attendance.scan', sess.theory_group_id);
  end if;

  if sess.status <> 'open' then
    return jsonb_build_object('status', 'session_closed');
  end if;

  select * into st from students where academic_no = trim(p_academic_no) and deleted_at is null;
  if not found then
    return jsonb_build_object('status', 'student_not_found');
  end if;

  if sess.cohort_node_id is not null and st.cohort_node_id is not null and st.cohort_node_id <> sess.cohort_node_id then
    return jsonb_build_object('status', 'wrong_group', 'student_group', coalesce(st.practical_group_id, st.theory_group_id));
  end if;

  if sess.part = 'practical' then
    if st.practical_group_id <> sess.practical_group_id or st.theory_group_id <> sess.theory_group_id then
      return jsonb_build_object(
        'status', 'wrong_group',
        'student_group', st.practical_group_id,
        'expected_group', sess.practical_group_id
      );
    end if;
  else
    if st.theory_group_id <> sess.theory_group_id then
      return jsonb_build_object(
        'status', 'wrong_group',
        'student_group', st.theory_group_id,
        'expected_group', sess.theory_group_id
      );
    end if;
  end if;

  select * into rec from attendance_records where session_id = p_session and student_no = st.academic_no;
  if found then
    select count(*) into v_present from attendance_records where session_id = p_session and status = 'present';
    return jsonb_build_object('status', 'already_present', 'student', st.full_name, 'present_count', v_present);
  end if;

  insert into attendance_records (session_id, student_no, status, scanned_by)
  values (p_session, st.academic_no, 'present', p_actor);

  select count(*) into v_present from attendance_records where session_id = p_session and status = 'present';
  return jsonb_build_object('status', 'ok', 'student', st.full_name, 'present_count', v_present);
end $$;

-- 3) Scoped attendance matrix: returns ONLY students in the target theory OR practical group
create or replace function attendance_matrix_scoped(
  p_actor         bigint,
  p_subject       int,
  p_scope_node_id bigint
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_node   scope_nodes%rowtype;
  v_parent scope_nodes%rowtype;
  v_subj   subjects%rowtype;
  v_part   text;
  v_cohort bigint := scope_cohort_of(p_scope_node_id);
begin
  perform require_perm_scoped(p_actor, 'attendance.admin', p_scope_node_id);

  select * into v_node
    from scope_nodes
   where id = p_scope_node_id and kind in ('theory_group', 'practical_group') and deleted_at is null;
  if not found then return jsonb_build_object('status', 'invalid_scope'); end if;

  select * into v_subj from subjects where id = p_subject and deleted_at is null;
  if not found then return jsonb_build_object('status', 'not_found'); end if;

  v_part := case when v_node.kind = 'practical_group' then 'practical' else 'theory' end;
  if v_part = 'practical' then
    select * into v_parent from scope_nodes where id = v_node.parent_id;
  end if;

  return jsonb_build_object(
    'status', 'ok',
    'part', v_part,
    'scope_node_id', v_node.id,
    'subject', jsonb_build_object('id', v_subj.id, 'name', v_subj.name_ar),
    'group', v_node.code,
    'held_lectures', coalesce((
      select jsonb_agg(lecture_no order by lecture_no)
        from attendance_sessions
       where subject_id = p_subject
         and part = v_part
         and (scope_node_id = v_node.id or (v_part = 'theory' and scope_node_id is null and theory_group_id = v_node.code))
    ), '[]'::jsonb),
    'students', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'academic_no', st.academic_no,
          'full_name', st.full_name,
          'theory', st.theory_group_id,
          'practical', st.practical_group_id,
          'lectures', (
            select jsonb_agg(
              case
                when s.id is null then null
                when r.status = 'present' then 1
                else 0
              end order by n
            )
            from generate_series(1, 12) as n
            left join attendance_sessions s
              on s.subject_id = p_subject
             and s.part = v_part
             and s.lecture_no = n
             and (s.scope_node_id = v_node.id or (v_part = 'theory' and s.scope_node_id is null and s.theory_group_id = v_node.code))
            left join attendance_records r
              on r.session_id = s.id and r.student_no = st.academic_no
          )
        ) order by st.full_name
      )
      from students st
      where st.deleted_at is null
        and (v_cohort is null or st.cohort_node_id is null or st.cohort_node_id = v_cohort)
        and (
          (v_part = 'practical' and (st.practical_node_id = v_node.id or (st.practical_group_id = v_node.code and st.theory_group_id = coalesce(v_parent.code, st.theory_group_id))))
          or (v_part = 'theory' and (st.theory_node_id = v_node.id or st.theory_group_id = v_node.code))
        )
    ), '[]'::jsonb)
  );
end $$;

revoke execute on function open_attendance_session_scoped(bigint, smallint, bigint, smallint, boolean) from public, anon, authenticated;
grant execute on function open_attendance_session_scoped(bigint, smallint, bigint, smallint, boolean) to service_role;
revoke execute on function scan_attendance(bigint, bigint, text) from public, anon, authenticated;
grant execute on function scan_attendance(bigint, bigint, text) to service_role;
revoke execute on function attendance_matrix_scoped(bigint, int, bigint) from public, anon, authenticated;
grant execute on function attendance_matrix_scoped(bigint, int, bigint) to service_role;

-- 4) Security hardening for 0023 (append-only, never editing applied 0023):
--    a) search_users_for_role: prevent non-developers from enumerating users outside their managed subtree.
create or replace function search_users_for_role(
  p_actor         bigint,
  p_query         text,
  p_scope_node_id bigint default null,
  p_limit         int default 15
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_q      text    := trim(coalesce(p_query, ''));
  v_uname  text    := ltrim(v_q, '@');
  v_lim    int     := greatest(1, least(coalesce(p_limit, 15), 30));
  v_is_dev boolean := is_developer(p_actor);
  v_rows   jsonb;
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
          v_is_dev
          -- Non-developers can only browse students inside their managed subtree,
          -- OR look up a specific user by exact telegram_id / exact @username.
          or (s.cohort_node_id is not null and has_perm_scoped(p_actor, 'roles.manage', s.cohort_node_id))
          or (v_q <> '' and u.telegram_id::text = v_q)
          or (v_uname <> '' and lower(coalesce(u.username, '')) = lower(v_uname))
        )
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

--    b) revoke_role_invite: enforce rank hierarchy (matches revoke_role anti-escalation).
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
    if actor_max_role_rank(p_actor, ri.scope_node_id) <= role_rank(ri.role) then
      raise exception 'forbidden' using errcode = '42501';
    end if;
  end if;

  update role_invites set revoked_at = now(), revoked_by = p_actor where id = p_invite_id;
  perform log_activity(p_actor, 'role_invite.revoke', 'role_invite', p_invite_id::text,
                       jsonb_build_object('role', ri.role, 'scope_node_id', ri.scope_node_id));
  return jsonb_build_object('status', 'ok');
end $$;

revoke execute on function search_users_for_role(bigint, text, bigint, int) from public, anon, authenticated;
grant execute on function search_users_for_role(bigint, text, bigint, int) to service_role;
revoke execute on function revoke_role_invite(bigint, bigint) from public, anon, authenticated;
grant execute on function revoke_role_invite(bigint, bigint) to service_role;
