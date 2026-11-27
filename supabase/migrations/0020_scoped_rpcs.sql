-- =====================================================================
-- 0020_scoped_rpcs.sql — Phase C (Ticket C5): Scoped Bootstrap & Academic Workflow RPCs
-- Enforces Tenant Scope Node isolation and Scoped Role Grants in PostgreSQL
-- across bootstrap, files, assignments, attendance, grievances, sharek, MCQ,
-- home_summary, student import, teaching, and Telegram Destinations.
-- Append-only, idempotent (safe to re-run). ONE-WAY DOOR migration.
-- =====================================================================

-- ---------- 1. Active Cohort Resolution & Switching ----------
create or replace function resolve_user_cohort(
  p_tg               bigint,
  p_requested_cohort bigint default null
) returns bigint
language plpgsql stable security definer set search_path = public as $$
declare
  v_student_cohort bigint;
  v_user_cohort    bigint;
  v_user_kind      text;
  v_grant_cohort   bigint;
  v_default_cohort bigint;
begin
  select cohort_node_id into v_student_cohort
    from students
   where telegram_id = p_tg and deleted_at is null
   limit 1;

  select active_cohort_node_id, kind into v_user_cohort, v_user_kind
    from users
   where telegram_id = p_tg;

  if p_requested_cohort is not null then
    if not exists (
      select 1 from scope_nodes
       where id = p_requested_cohort and kind = 'cohort' and is_active and deleted_at is null
    ) then
      raise exception 'invalid_cohort' using errcode = '22023';
    end if;

    if is_developer(p_tg)
       or v_student_cohort = p_requested_cohort
       or coalesce(v_user_kind, 'new') in ('guest', 'new')
       or exists (
         select 1 from role_grants gr
          where gr.telegram_id = p_tg
            and gr.revoked_at is null
            and gr.scope_node_id is not null
            and scope_is_ancestor(gr.scope_node_id, p_requested_cohort)
       ) then
      return p_requested_cohort;
    end if;

    raise exception 'forbidden' using errcode = '42501';
  end if;

  if v_student_cohort is not null then
    return v_student_cohort;
  end if;

  if v_user_cohort is not null and exists (
    select 1 from scope_nodes
     where id = v_user_cohort and kind = 'cohort' and is_active and deleted_at is null
  ) then
    return v_user_cohort;
  end if;

  -- Resolve from highest-priority active grant
  select coalesce(
    scope_cohort_of(gr.scope_node_id),
    (select c.id from scope_nodes c
      where c.kind = 'cohort' and c.is_active and c.deleted_at is null
        and c.path @> array[gr.scope_node_id]
      order by c.sort, c.id limit 1)
  ) into v_grant_cohort
    from role_grants gr
   where gr.telegram_id = p_tg
     and gr.revoked_at is null
     and gr.scope_node_id is not null
   order by role_rank(gr.role) desc, gr.id asc
   limit 1;

  if v_grant_cohort is not null then
    return v_grant_cohort;
  end if;

  select id into v_default_cohort
    from scope_nodes
   where kind = 'cohort' and is_active and deleted_at is null
   order by sort, id
   limit 1;

  return v_default_cohort;
end $$;

create or replace function set_active_cohort(p_tg bigint, p_cohort_node_id bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_cohort bigint;
begin
  v_cohort := resolve_user_cohort(p_tg, p_cohort_node_id);

  update users
     set active_cohort_node_id = v_cohort
   where telegram_id = p_tg;

  perform bump_scope('roles');
  return jsonb_build_object(
    'status', 'ok',
    'cohort_node_id', v_cohort,
    'active_cohort', scope_tree_for_cohort(v_cohort)
  );
end $$;

-- ---------- 2. Scoped app_bootstrap ----------
drop function if exists app_bootstrap(bigint, text, text);

create or replace function app_bootstrap(
  p_tg             bigint,
  p_name           text   default null,
  p_username       text   default null,
  p_cohort_node_id bigint default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  u             users%rowtype;
  s             students%rowtype;
  d             doctors%rowtype;
  v_kind        text;
  v_base        text[] := '{}';
  v_roles       jsonb;
  v_perms       jsonb;
  v_versions    jsonb;
  v_cohort_id   bigint;
  v_active_coh  jsonb;
begin
  insert into users (telegram_id, display_name, username, last_seen_at)
  values (p_tg, nullif(trim(coalesce(p_name, '')), ''), nullif(p_username, ''), now())
  on conflict (telegram_id) do update
     set last_seen_at = now(),
         username     = coalesce(excluded.username, users.username)
  returning * into u;

  select coalesce(jsonb_object_agg(scope, version), '{}') into v_versions from data_versions;

  if u.is_banned then
    return jsonb_build_object(
      'user', jsonb_build_object('telegram_id', u.telegram_id, 'kind', 'banned'),
      'versions', v_versions);
  end if;

  select * into s from students where telegram_id = p_tg and deleted_at is null;
  select * into d from doctors  where telegram_id = p_tg and is_active and deleted_at is null;

  v_kind := case
    when d.id is not null           then 'doctor'
    when s.academic_no is not null  then 'student'
    when u.kind = 'guest'           then 'guest'
    else 'new' end;

  v_base := case v_kind
    when 'doctor'  then array['doctor']
    when 'student' then array['student']
    when 'guest'   then array['guest']
    else '{}'::text[] end;

  v_cohort_id  := resolve_user_cohort(p_tg, p_cohort_node_id);
  v_active_coh := case when v_cohort_id is not null then scope_tree_for_cohort(v_cohort_id) else null end;

  select coalesce(jsonb_agg(jsonb_build_object(
    'role', g.role,
    'group', g.theory_group_id,
    'scope_node_id', g.scope_node_id,
    'path', case when n.id is not null then to_jsonb(n.path) else null end
  ) order by role_rank(g.role) desc, g.role), '[]')
    into v_roles
    from role_grants g
    left join scope_nodes n on n.id = g.scope_node_id
   where g.telegram_id = p_tg and g.revoked_at is null;

  select coalesce(jsonb_agg(distinct p), '[]') into v_perms from (
    select jsonb_build_object(
      'k', rp.permission, 's', rp.scope, 'n', null::bigint, 'g', null::text, 'c', rp.condition
    ) as p
      from role_permissions rp where rp.role = any (v_base)
    union all
    select jsonb_build_object(
      'k', rp.permission, 's', rp.scope, 'n', g.scope_node_id, 'g', g.theory_group_id, 'c', rp.condition
    )
      from role_grants g join role_permissions rp on rp.role = g.role
     where g.telegram_id = p_tg and g.revoked_at is null
  ) x;

  return jsonb_build_object(
    'user', jsonb_build_object(
      'telegram_id', u.telegram_id, 'kind', v_kind,
      'name', coalesce(s.full_name, d.name, u.display_name), 'username', u.username,
      'active_cohort_node_id', v_cohort_id),
    'student', case when s.academic_no is null then null else jsonb_build_object(
      'academic_no', s.academic_no, 'full_name', s.full_name,
      'theory_group_id', s.theory_group_id, 'practical_group_id', s.practical_group_id,
      'cohort_node_id', s.cohort_node_id, 'theory_node_id', s.theory_node_id,
      'practical_node_id', s.practical_node_id) end,
    'doctor_id', d.id,
    'roles', v_roles,
    'perms', v_perms,
    'active_cohort', v_active_coh,
    'scope_tree', list_scope_tree(p_tg, null),
    'groups', jsonb_build_object(
      'theory', coalesce((
        select jsonb_agg(t.code order by t.sort, t.id)
          from scope_nodes t
         where t.parent_id = v_cohort_id and t.kind = 'theory_group' and t.is_active and t.deleted_at is null
      ), '[]'::jsonb),
      'practical', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', p.code, 'theory', t.code, 'node_id', p.id, 'theory_node_id', t.id
        ) order by t.sort, p.sort, p.id)
          from scope_nodes t
          join scope_nodes p on p.parent_id = t.id and p.kind = 'practical_group' and p.is_active and p.deleted_at is null
         where t.parent_id = v_cohort_id and t.kind = 'theory_group' and t.is_active and t.deleted_at is null
      ), '[]'::jsonb)),
    'subjects', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', s_row.id, 'name', s_row.name_ar, 'tag', s_row.hashtag, 'cohort_node_id', s_row.cohort_node_id,
        'doctors', jsonb_build_object(
          'theory', coalesce((
            select jsonb_agg(jsonb_build_object('id', d_row.id, 'name', d_row.name) order by tc.cnt desc, d_row.id)
              from (select t.doctor_id, count(*) as cnt from teaching t where t.subject_id = s_row.id and t.part = 'theory' group by t.doctor_id) tc
              join doctors d_row on d_row.id = tc.doctor_id and d_row.is_active and d_row.deleted_at is null
          ), '[]'::jsonb),
          'practical', coalesce((
            select jsonb_agg(jsonb_build_object('id', d_row.id, 'name', d_row.name) order by tc.cnt desc, d_row.id)
              from (select t.doctor_id, count(*) as cnt from teaching t where t.subject_id = s_row.id and t.part = 'practical' group by t.doctor_id) tc
              join doctors d_row on d_row.id = tc.doctor_id and d_row.is_active and d_row.deleted_at is null
          ), '[]'::jsonb)
        )
      ) order by s_row.sort, s_row.id), '[]')
      from subjects s_row
     where s_row.is_active
       and s_row.deleted_at is null
       and (v_cohort_id is null or s_row.cohort_node_id = v_cohort_id)
    ),
    'versions', v_versions,
    'settings', (select coalesce(jsonb_object_agg(key, value), '{}') from app_settings where is_public)
  );
end $$;

-- ---------- 3. Scoped Files RPCs ----------
drop function if exists search_files_smart(bigint, int, text, text, text, smallint[], int);

create or replace function search_files_smart(
  p_tg             bigint,
  p_subject        int        default null,
  p_part           text       default null,
  p_type           text       default null,
  p_exam_kind      text       default null,
  p_numbers        smallint[] default null,
  p_limit          int        default 60,
  p_cohort_node_id bigint     default null
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_cohort bigint := resolve_user_cohort(p_tg, p_cohort_node_id);
begin
  perform require_perm_scoped(p_tg, 'files.view', v_cohort);
  return coalesce((
    select jsonb_agg(to_jsonb(r) order by r.created_at desc, r.id desc) from (
      select f.id, f.subject_id, sj.name_ar as subject, f.part, f.content_type, f.exam_kind,
             f.label_kind, f.numbers, f.description, f.file_name, f.created_at,
             f.cohort_node_id, d.name as doctor_name
        from files f
        join subjects sj on sj.id = f.subject_id
        left join doctors d on d.id = f.doctor_id
       where f.deleted_at is null
         and f.cohort_node_id = v_cohort
         and (p_subject is null or f.subject_id = p_subject)
         and (p_part is null or f.part = p_part)
         and (p_type is null or f.content_type = p_type)
         and (p_exam_kind is null or f.exam_kind = p_exam_kind)
         and (p_numbers is null or cardinality(p_numbers) = 0 or f.numbers && p_numbers)
       order by f.created_at desc, f.id desc
       limit greatest(1, least(coalesce(p_limit, 60), 500))
    ) r
  ), '[]'::jsonb);
end $$;

create or replace function get_file(p_tg bigint, p_id bigint) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_cohort bigint;
begin
  select f.cohort_node_id into v_cohort from files f where f.id = p_id and f.deleted_at is null;
  if v_cohort is null then
    return null;
  end if;
  -- Enforce both permission and cohort membership/access
  perform resolve_user_cohort(p_tg, v_cohort);
  perform require_perm_scoped(p_tg, 'files.view', v_cohort);

  return (
    select jsonb_build_object(
      'id', f.id, 'subject_id', f.subject_id, 'subject', sj.name_ar, 'part', f.part,
      'content_type', f.content_type, 'exam_kind', f.exam_kind, 'label_kind', f.label_kind,
      'numbers', f.numbers, 'description', f.description, 'caption', f.caption,
      'media_kind', f.media_kind, 'tg_file_id', f.tg_file_id, 'file_name', f.file_name,
      'mime', f.mime, 'size', f.size, 'chat_id', f.chat_id, 'topic_id', f.topic_id,
      'message_id', f.message_id, 'cohort_node_id', f.cohort_node_id,
      'doctor_id', f.doctor_id, 'doctor_name', d.name, 'created_at', f.created_at
    )
    from files f
    join subjects sj on sj.id = f.subject_id
    left join doctors d on d.id = f.doctor_id
    where f.id = p_id and f.deleted_at is null
  );
end $$;

-- ---------- 4. Scoped Grievances & Home Summary ----------
create or replace function cycle_targets_student(c grievance_cycles, s students) returns boolean
language sql immutable as $$
  select (c.cohort_node_id is null or s.cohort_node_id is null or c.cohort_node_id = s.cohort_node_id)
     and (
       (c.theory_node_id is null and c.theory_group_id is null)
       or (c.theory_node_id is not null and c.theory_node_id = s.theory_node_id)
       or (c.theory_node_id is null and c.theory_group_id = s.theory_group_id)
     )
     and (
       c.part = 'theory'
       or cardinality(c.practical_groups) = 0
       or s.practical_group_id = any (c.practical_groups)
     );
$$;

create or replace function home_summary(p_tg bigint) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  s     students%rowtype;
  v_asg jsonb;
begin
  select * into s from students where telegram_id = p_tg and deleted_at is null;
  v_asg := case when s.academic_no is not null then my_assignments(p_tg, 40) else '[]'::jsonb end;

  return jsonb_build_object(
    'unread', (select count(*) from notifications where telegram_id = p_tg and read_at is null),
    'items', coalesce((
      select jsonb_agg(x) from (
        select r from jsonb_array_elements(v_asg) r
         where r->>'status' = 'open' and (r->>'submitted_at') is null and (r->>'closes_at')::timestamptz > now()
         order by (r->>'due_at')::timestamptz limit 5
      ) y(x)
    ), '[]'::jsonb),
    'missed', '[]'::jsonb,
    'announcements', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', n.id,
               'title', coalesce(nullif(n.payload->>'title', ''), 'إعلان'),
               'body', n.payload->>'body',
               'grp', coalesce(n.payload->>'group', 'الجميع'),
               'created_at', n.created_at
             ) order by n.id desc)
        from (
          select * from notifications
           where telegram_id = p_tg and kind = 'manual'
             and created_at > now() - interval '24 hours'
           order by id desc limit 3
        ) n
    ), '[]'::jsonb),
    'grievances', case when s.academic_no is not null then coalesce((
      select jsonb_agg(to_jsonb(g) order by g.closes_at asc) from (
        select c.id, sj.name_ar as subject, c.part, c.title, c.closes_at,
               exists (select 1 from grievances gr where gr.cycle_id = c.id and gr.student_no = s.academic_no) as submitted
          from grievance_cycles c join subjects sj on sj.id = c.subject_id
         where c.status = 'open' and c.closes_at > now() and cycle_targets_student(c, s)
         order by c.closes_at asc limit 4
      ) g
    ), '[]'::jsonb) else '[]'::jsonb end,
    'sharek', case when s.academic_no is not null then coalesce((
      select jsonb_agg(to_jsonb(sh) order by sh.id desc) from (
        select c.id, c.kind, coalesce(c.theory_group_id, 'الجميع') as grp, c.title, c.created_at,
               (select option_idx from sharek_votes v where v.campaign_id = c.id and v.student_no = s.academic_no) as my_vote,
               exists (select 1 from sharek_sessions ss where ss.campaign_id = c.id and ss.student_no = s.academic_no) as is_finished
          from sharek_campaigns c
         where c.status = 'open'
           and c.cohort_node_id = s.cohort_node_id
           and (c.theory_node_id is null or c.theory_node_id = s.theory_node_id)
           and (
             (c.kind = 'poll' and not exists (select 1 from sharek_votes v where v.campaign_id = c.id and v.student_no = s.academic_no))
             or
             (c.kind = 'submission' and not exists (select 1 from sharek_sessions ss where ss.campaign_id = c.id and ss.student_no = s.academic_no))
           )
         order by c.id desc limit 4
      ) sh
    ), '[]'::jsonb) else '[]'::jsonb end
  );
end $$;

-- ---------- 5. Scoped Listing & Workflow RPCs (Assignments, Attendance, Sharek, MCQ) ----------
create or replace function list_assignments_scoped(
  p_tg             bigint,
  p_cohort_node_id bigint default null,
  p_scope_node_id  bigint default null,
  p_status         text   default null
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_cohort bigint := resolve_user_cohort(p_tg, p_cohort_node_id);
  v_target bigint := coalesce(p_scope_node_id, v_cohort);
begin
  perform require_perm_scoped(p_tg, 'assignments.manage', v_target);
  return coalesce((
    select jsonb_agg(to_jsonb(r) order by r.due_at desc, r.id desc) from (
      select a.id, a.subject_id, sj.name_ar as subject, a.part, a.number,
             a.cohort_node_id, a.scope_node_id, sn.code as group_code,
             a.description, a.due_at, a.closes_at, a.status, a.doctor_id, a.created_at
        from assignments a
        join subjects sj on sj.id = a.subject_id
        left join scope_nodes sn on sn.id = a.scope_node_id
       where a.deleted_at is null
         and a.cohort_node_id = v_cohort
         and (p_scope_node_id is null or a.scope_node_id = p_scope_node_id)
         and (p_status is null or a.status = p_status)
       order by a.due_at desc, a.id desc
       limit 100
    ) r
  ), '[]'::jsonb);
end $$;

create or replace function list_mcq_exams_scoped(
  p_tg             bigint,
  p_subject_id     int    default null,
  p_cohort_node_id bigint default null
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_cohort bigint := resolve_user_cohort(p_tg, p_cohort_node_id);
begin
  perform require_perm_scoped(p_tg, 'mcq.take', v_cohort);
  return coalesce((
    select jsonb_agg(to_jsonb(r) order by r.id desc) from (
      select e.id, e.subject_id, sj.name_ar as subject, e.title, e.description,
             e.duration_minutes, e.questions_count, e.cohort_node_id, e.created_at
        from mcq_exams e
        join subjects sj on sj.id = e.subject_id
       where e.deleted_at is null
         and e.cohort_node_id = v_cohort
         and (p_subject_id is null or e.subject_id = p_subject_id)
       order by e.id desc
    ) r
  ), '[]'::jsonb);
end $$;

create or replace function list_sharek_campaigns_scoped(
  p_tg             bigint,
  p_cohort_node_id bigint default null
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_cohort bigint := resolve_user_cohort(p_tg, p_cohort_node_id);
  v_student students%rowtype;
begin
  select * into v_student from students where telegram_id = p_tg and deleted_at is null;
  return coalesce((
    select jsonb_agg(to_jsonb(r) order by r.id desc) from (
      select c.id, c.kind, c.title, c.options, c.status, c.cohort_node_id,
             c.theory_node_id, coalesce(sn.code, c.theory_group_id, 'الجميع') as grp,
             c.created_at
        from sharek_campaigns c
        left join scope_nodes sn on sn.id = c.theory_node_id
       where c.cohort_node_id = v_cohort
         and c.status = 'open'
         and (
           has_perm_scoped(p_tg, 'sharek.publish', coalesce(c.theory_node_id, v_cohort))
           or c.theory_node_id is null
           or (v_student.academic_no is not null and c.theory_node_id = v_student.theory_node_id)
         )
       order by c.id desc
       limit 50
    ) r
  ), '[]'::jsonb);
end $$;

create or replace function list_grievance_cycles_scoped(
  p_tg             bigint,
  p_cohort_node_id bigint default null
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_cohort  bigint := resolve_user_cohort(p_tg, p_cohort_node_id);
  v_student students%rowtype;
begin
  select * into v_student from students where telegram_id = p_tg and deleted_at is null;
  return coalesce((
    select jsonb_agg(to_jsonb(r) order by r.closes_at desc, r.id desc) from (
      select c.id, c.subject_id, sj.name_ar as subject, c.part, c.title,
             c.cohort_node_id, c.theory_node_id, c.closes_at, c.status, c.created_at
        from grievance_cycles c
        join subjects sj on sj.id = c.subject_id
       where c.cohort_node_id = v_cohort
         and (
           has_perm_scoped(p_tg, 'grievances.open', coalesce(c.theory_node_id, v_cohort))
           or (v_student.academic_no is not null and cycle_targets_student(c, v_student))
         )
       order by c.closes_at desc, c.id desc
       limit 50
    ) r
  ), '[]'::jsonb);
end $$;

create or replace function open_attendance_session_scoped(
  p_actor           bigint,
  p_subject_id      smallint,
  p_theory_node_id  bigint,
  p_lecture_no      smallint,
  p_delegate_absent boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_cohort    bigint := scope_cohort_of(p_theory_node_id);
  v_theory_cd text;
  v_session   attendance_sessions%rowtype;
begin
  perform require_perm_scoped(p_actor, 'attendance.session', p_theory_node_id, p_delegate_absent);

  select code into v_theory_cd
    from scope_nodes
   where id = p_theory_node_id and kind = 'theory_group' and is_active and deleted_at is null;
  if v_theory_cd is null then
    return jsonb_build_object('status', 'invalid_scope');
  end if;

  if not exists (
    select 1 from subjects
     where id = p_subject_id and cohort_node_id = v_cohort and is_active and deleted_at is null
  ) then
    return jsonb_build_object('status', 'invalid_subject');
  end if;

  insert into attendance_sessions (
    subject_id, theory_group_id, cohort_node_id, theory_node_id, lecture_no, delegate_absent, opened_by
  )
  values (
    p_subject_id, v_theory_cd, v_cohort, p_theory_node_id, p_lecture_no, p_delegate_absent, p_actor
  )
  returning * into v_session;

  insert into activity_log (actor_id, action, entity, entity_id, scope_node_id, meta)
  values (
    p_actor, 'attendance.open', 'attendance_session', v_session.id::text, p_theory_node_id,
    jsonb_build_object('subject_id', p_subject_id, 'lecture_no', p_lecture_no)
  );

  return jsonb_build_object('status', 'ok', 'id', v_session.id);
end $$;

-- ---------- 6. Scoped Admin / Catalog RPCs ----------
create or replace function import_students_scoped(
  p_actor          bigint,
  p_cohort_node_id bigint,
  p_rows           jsonb
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  r             record;
  v_ins         int := 0;
  v_upd         int := 0;
  v_errors      jsonb := '[]';
  v_no          text;
  v_name        text;
  v_t           text;
  v_p           text;
  v_t_node      bigint;
  v_p_node      bigint;
  v_existed     boolean;
begin
  perform require_perm_scoped(p_actor, 'students.manage', p_cohort_node_id);

  if not exists (
    select 1 from scope_nodes where id = p_cohort_node_id and kind = 'cohort' and deleted_at is null
  ) then
    return jsonb_build_object('status', 'invalid_cohort');
  end if;

  for r in select value as item, ordinality as n from jsonb_array_elements(p_rows) with ordinality loop
    v_no   := trim(r.item->>'academic_no');
    v_name := regexp_replace(trim(coalesce(r.item->>'full_name', '')), '\s+', ' ', 'g');
    v_t    := upper(trim(r.item->>'theory'));
    v_p    := upper(trim(r.item->>'practical'));

    if v_no is null or v_no = '' or v_name = '' then
      v_errors := v_errors || jsonb_build_object('row', r.n, 'reason', 'بيانات ناقصة');
      continue;
    end if;

    select t.id, p.id into v_t_node, v_p_node
      from scope_nodes t
      join scope_nodes p on p.parent_id = t.id and p.kind = 'practical_group' and p.deleted_at is null
     where t.parent_id = p_cohort_node_id
       and t.kind = 'theory_group'
       and t.deleted_at is null
       and upper(t.code) = v_t
       and upper(p.code) = v_p
     limit 1;

    if v_t_node is null or v_p_node is null then
      v_errors := v_errors || jsonb_build_object('row', r.n, 'reason', 'مجموعة غير صحيحة ضمن هذه الدفعة');
      continue;
    end if;

    select exists (select 1 from students where academic_no = v_no) into v_existed;
    insert into students (
      academic_no, full_name, theory_group_id, practical_group_id,
      cohort_node_id, theory_node_id, practical_node_id
    )
    values (v_no, v_name, v_t, v_p, p_cohort_node_id, v_t_node, v_p_node)
    on conflict (academic_no) do update
       set full_name          = excluded.full_name,
           theory_group_id    = excluded.theory_group_id,
           practical_group_id = excluded.practical_group_id,
           cohort_node_id     = excluded.cohort_node_id,
           theory_node_id     = excluded.theory_node_id,
           practical_node_id  = excluded.practical_node_id,
           deleted_at         = null;

    if v_existed then v_upd := v_upd + 1; else v_ins := v_ins + 1; end if;
  end loop;

  perform bump_scope('roles');
  insert into activity_log (actor_id, action, entity, entity_id, scope_node_id, meta)
  values (
    p_actor, 'students.import', 'students', p_cohort_node_id::text, p_cohort_node_id,
    jsonb_build_object('inserted', v_ins, 'updated', v_upd, 'errors', jsonb_array_length(v_errors))
  );
  return jsonb_build_object('inserted', v_ins, 'updated', v_upd, 'errors', v_errors);
end $$;

create or replace function upsert_destination_scoped(
  p_actor         bigint,
  p_scope_node_id bigint,
  p_key           text,
  p_chat          bigint,
  p_topic         int  default null,
  p_label         text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_cohort bigint := coalesce(scope_cohort_of(p_scope_node_id), p_scope_node_id);
begin
  perform require_perm_scoped(p_actor, 'communities.manage', p_scope_node_id);

  insert into tg_destinations (scope_node_id, cohort_node_id, key, chat_id, topic_id, label, updated_at)
  values (p_scope_node_id, v_cohort, p_key, p_chat, p_topic, p_label, now())
  on conflict (scope_node_id, key) where scope_node_id is not null do update
     set chat_id = excluded.chat_id,
         topic_id = excluded.topic_id,
         label = coalesce(excluded.label, tg_destinations.label),
         updated_at = now();

  insert into activity_log (actor_id, action, entity, entity_id, scope_node_id, meta)
  values (
    p_actor, 'destination.upsert', 'tg_destination', p_key, p_scope_node_id,
    jsonb_build_object('chat_id', p_chat, 'topic_id', p_topic)
  );
  return jsonb_build_object('status', 'ok');
end $$;

create or replace function upsert_teaching_scoped(
  p_actor         bigint,
  p_subject_id    smallint,
  p_scope_node_id bigint,
  p_doctor_id     smallint
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_node   scope_nodes%rowtype;
  v_cohort bigint;
  v_part   text;
begin
  perform require_perm_scoped(p_actor, 'communities.manage', p_scope_node_id);

  select * into v_node from scope_nodes where id = p_scope_node_id and deleted_at is null;
  if not found or v_node.kind not in ('theory_group', 'practical_group') then
    return jsonb_build_object('status', 'invalid_scope');
  end if;

  v_cohort := scope_cohort_of(p_scope_node_id);
  v_part   := case v_node.kind when 'theory_group' then 'theory' else 'practical' end;

  if not exists (
    select 1 from subjects where id = p_subject_id and cohort_node_id = v_cohort and deleted_at is null
  ) then
    return jsonb_build_object('status', 'invalid_subject');
  end if;

  insert into teaching (
    subject_id, part,
    theory_group_id, practical_group_id,
    cohort_node_id, scope_node_id, doctor_id
  )
  values (
    p_subject_id, v_part,
    case when v_part = 'theory' then v_node.code else null end,
    case when v_part = 'practical' then v_node.code else null end,
    v_cohort, p_scope_node_id, p_doctor_id
  )
  on conflict (subject_id, scope_node_id) where scope_node_id is not null do update
     set doctor_id = excluded.doctor_id;

  return jsonb_build_object('status', 'ok');
end $$;

-- ---------- 7. Security: Restrict Function Execution to service_role ----------
revoke execute on function public.resolve_user_cohort(bigint, bigint) from public, anon, authenticated;
revoke execute on function public.set_active_cohort(bigint, bigint) from public, anon, authenticated;
revoke execute on function public.app_bootstrap(bigint, text, text, bigint) from public, anon, authenticated;
revoke execute on function public.search_files_smart(bigint, int, text, text, text, smallint[], int, bigint) from public, anon, authenticated;
revoke execute on function public.get_file(bigint, bigint) from public, anon, authenticated;
revoke execute on function public.home_summary(bigint) from public, anon, authenticated;
revoke execute on function public.list_assignments_scoped(bigint, bigint, bigint, text) from public, anon, authenticated;
revoke execute on function public.list_mcq_exams_scoped(bigint, int, bigint) from public, anon, authenticated;
revoke execute on function public.list_sharek_campaigns_scoped(bigint, bigint) from public, anon, authenticated;
revoke execute on function public.list_grievance_cycles_scoped(bigint, bigint) from public, anon, authenticated;
revoke execute on function public.open_attendance_session_scoped(bigint, smallint, bigint, smallint, boolean) from public, anon, authenticated;
revoke execute on function public.import_students_scoped(bigint, bigint, jsonb) from public, anon, authenticated;
revoke execute on function public.upsert_destination_scoped(bigint, bigint, text, bigint, int, text) from public, anon, authenticated;
revoke execute on function public.upsert_teaching_scoped(bigint, smallint, bigint, smallint) from public, anon, authenticated;

grant execute on function public.resolve_user_cohort(bigint, bigint) to service_role;
grant execute on function public.set_active_cohort(bigint, bigint) to service_role;
grant execute on function public.app_bootstrap(bigint, text, text, bigint) to service_role;
grant execute on function public.search_files_smart(bigint, int, text, text, text, smallint[], int, bigint) to service_role;
grant execute on function public.get_file(bigint, bigint) to service_role;
grant execute on function public.home_summary(bigint) to service_role;
grant execute on function public.list_assignments_scoped(bigint, bigint, bigint, text) to service_role;
grant execute on function public.list_mcq_exams_scoped(bigint, int, bigint) to service_role;
grant execute on function public.list_sharek_campaigns_scoped(bigint, bigint) to service_role;
grant execute on function public.list_grievance_cycles_scoped(bigint, bigint) to service_role;
grant execute on function public.open_attendance_session_scoped(bigint, smallint, bigint, smallint, boolean) to service_role;
grant execute on function public.import_students_scoped(bigint, bigint, jsonb) to service_role;
grant execute on function public.upsert_destination_scoped(bigint, bigint, text, bigint, int, text) to service_role;
grant execute on function public.upsert_teaching_scoped(bigint, smallint, bigint, smallint) to service_role;
