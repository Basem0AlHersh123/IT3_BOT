-- =====================================================================
-- 0017_scope_tree.sql — Phase C (Ticket C1): Multi-Tenant Scope Tree & Core Backfill
-- Implements ADR-0002 five-level Scope Tree:
--   College -> Major -> Cohort -> Theory Group -> Practical Group
-- Append-only, idempotent (safe to re-run). ONE-WAY DOOR migration.
-- =====================================================================

-- ---------- 1. Scope Tree Table (Tenant Scope Nodes) ----------
create table if not exists scope_nodes (
  id         bigint generated always as identity primary key,
  kind       text not null check (kind in ('college','major','cohort','theory_group','practical_group')),
  parent_id  bigint references scope_nodes(id) on delete restrict,
  code       text not null,
  name_ar    text not null,
  path       bigint[] not null default '{}',
  meta       jsonb not null default '{}',
  sort       smallint not null default 0,
  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  deleted_at timestamptz,
  check ((kind = 'college' and parent_id is null) or (kind <> 'college' and parent_id is not null))
);

create index if not exists scope_nodes_path_gin_idx
  on scope_nodes using gin (path);

create index if not exists scope_nodes_parent_idx
  on scope_nodes (parent_id, sort, id) where deleted_at is null;

create index if not exists scope_nodes_kind_idx
  on scope_nodes (kind) where deleted_at is null;

create unique index if not exists scope_nodes_parent_code_uq
  on scope_nodes (coalesce(parent_id, 0), code) where deleted_at is null;

-- ---------- 2. Parent-Kind Integrity & Materialized Path Trigger ----------
create or replace function trg_scope_nodes_maintain_path() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_parent         scope_nodes%rowtype;
  v_expected_kind  text;
begin
  new.code := trim(coalesce(new.code, ''));
  new.name_ar := trim(coalesce(new.name_ar, ''));
  if new.code = '' or new.name_ar = '' then
    raise exception 'scope_nodes: code and name_ar are required' using errcode = '22023';
  end if;

  if tg_op = 'UPDATE' then
    if (new.parent_id is distinct from old.parent_id or new.kind is distinct from old.kind)
       and exists (select 1 from scope_nodes where parent_id = old.id) then
      raise exception 'scope_nodes: cannot reparent or change kind of a node with children'
        using errcode = '22023';
    end if;
  end if;

  if new.kind = 'college' then
    if new.parent_id is not null then
      raise exception 'scope_nodes: college node must have null parent_id' using errcode = '22023';
    end if;
    new.path := array[new.id];
    return new;
  end if;

  v_expected_kind := case new.kind
    when 'major'           then 'college'
    when 'cohort'          then 'major'
    when 'theory_group'    then 'cohort'
    when 'practical_group' then 'theory_group'
    else null
  end;

  select * into v_parent from scope_nodes where id = new.parent_id;
  if not found then
    raise exception 'scope_nodes: parent_id % not found', new.parent_id using errcode = '23503';
  end if;

  if v_parent.kind <> v_expected_kind then
    raise exception 'scope_nodes: % parent must be %, got %', new.kind, v_expected_kind, v_parent.kind
      using errcode = '22023';
  end if;

  if new.id = any(v_parent.path) then
    raise exception 'scope_nodes: cycle detected in scope tree' using errcode = '22023';
  end if;

  new.path := v_parent.path || new.id;
  return new;
end $$;

drop trigger if exists trg_scope_nodes_path on scope_nodes;
create trigger trg_scope_nodes_path
  before insert or update on scope_nodes
  for each row execute function trg_scope_nodes_maintain_path();

drop trigger if exists bump_scope_nodes on scope_nodes;
create trigger bump_scope_nodes
  after insert or update or delete on scope_nodes
  for each statement execute function trg_bump('scopes');

-- ---------- 3. SQL Ancestry & Tree Helper Functions ----------
create or replace function scope_is_ancestor(p_ancestor bigint, p_target bigint) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1
      from scope_nodes
     where id = p_target
       and deleted_at is null
       and path @> array[p_ancestor]
  );
$$;

create or replace function scope_cohort_of(p_node bigint) returns bigint
language sql stable security definer set search_path = public as $$
  select case
    when array_length(path, 1) >= 3 then path[3]
    else null
  end
  from scope_nodes
  where id = p_node and deleted_at is null;
$$;

create or replace function scope_college_of(p_node bigint) returns bigint
language sql stable security definer set search_path = public as $$
  select path[1]
  from scope_nodes
  where id = p_node and deleted_at is null;
$$;

create or replace function scope_tree_for_cohort(p_cohort bigint) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_cohort  scope_nodes%rowtype;
  v_major   scope_nodes%rowtype;
  v_college scope_nodes%rowtype;
begin
  select * into v_cohort
    from scope_nodes
   where id = p_cohort and kind = 'cohort' and deleted_at is null;
  if not found then
    return null;
  end if;

  select * into v_major   from scope_nodes where id = v_cohort.parent_id;
  select * into v_college from scope_nodes where id = v_major.parent_id;

  return jsonb_build_object(
    'id', v_cohort.id,
    'code', v_cohort.code,
    'name_ar', v_cohort.name_ar,
    'meta', v_cohort.meta,
    'path', to_jsonb(v_cohort.path),
    'major', jsonb_build_object(
      'id', v_major.id,
      'code', v_major.code,
      'name_ar', v_major.name_ar
    ),
    'college', jsonb_build_object(
      'id', v_college.id,
      'code', v_college.code,
      'name_ar', v_college.name_ar
    ),
    'theory', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', t.id,
        'code', t.code,
        'name_ar', t.name_ar,
        'sort', t.sort,
        'path', to_jsonb(t.path)
      ) order by t.sort, t.id)
      from scope_nodes t
      where t.parent_id = v_cohort.id
        and t.kind = 'theory_group'
        and t.is_active
        and t.deleted_at is null
    ), '[]'::jsonb),
    'practical', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', p.id,
        'code', p.code,
        'name_ar', p.name_ar,
        'theory_node_id', t.id,
        'theory_code', t.code,
        'sort', p.sort,
        'path', to_jsonb(p.path)
      ) order by t.sort, p.sort, p.id)
      from scope_nodes t
      join scope_nodes p
        on p.parent_id = t.id
       and p.kind = 'practical_group'
       and p.is_active
       and p.deleted_at is null
      where t.parent_id = v_cohort.id
        and t.kind = 'theory_group'
        and t.is_active
        and t.deleted_at is null
    ), '[]'::jsonb)
  );
end $$;

-- ---------- 4. Add Scope Columns to Core Tables ----------
alter table theory_groups
  add column if not exists scope_node_id  bigint references scope_nodes(id),
  add column if not exists cohort_node_id bigint references scope_nodes(id);

alter table practical_groups
  add column if not exists scope_node_id  bigint references scope_nodes(id),
  add column if not exists cohort_node_id bigint references scope_nodes(id);

alter table students
  add column if not exists cohort_node_id    bigint references scope_nodes(id),
  add column if not exists theory_node_id    bigint references scope_nodes(id),
  add column if not exists practical_node_id bigint references scope_nodes(id);

alter table subjects
  add column if not exists cohort_node_id bigint references scope_nodes(id);

alter table teaching
  add column if not exists cohort_node_id bigint references scope_nodes(id),
  add column if not exists scope_node_id  bigint references scope_nodes(id);

alter table tg_destinations
  add column if not exists cohort_node_id bigint references scope_nodes(id),
  add column if not exists scope_node_id  bigint references scope_nodes(id);

alter table users
  add column if not exists active_cohort_node_id bigint references scope_nodes(id);

-- ---------- 5. Idempotent Seed & Core Backfill ----------
do $$
declare
  v_college_id  bigint;
  v_major_id    bigint;
  v_cohort_id   bigint;
  v_prefix      text;
  v_node_id     bigint;
  v_theory_node bigint;
  r_tg          record;
  r_pg          record;
begin
  -- 5a. Ensure root College node
  select id into v_college_id
    from scope_nodes
   where kind = 'college' and parent_id is null and deleted_at is null
   order by sort, id
   limit 1;

  if v_college_id is null then
    insert into scope_nodes (kind, parent_id, code, name_ar, sort)
    values ('college', null, 'csit', 'كلية علوم الحاسوب وتقنية المعلومات', 1)
    returning id into v_college_id;
  end if;

  -- 5b. Ensure default Major node
  select id into v_major_id
    from scope_nodes
   where kind = 'major' and parent_id = v_college_id and deleted_at is null
   order by sort, id
   limit 1;

  if v_major_id is null then
    insert into scope_nodes (kind, parent_id, code, name_ar, sort)
    values ('major', v_college_id, 'it', 'تقنية المعلومات', 1)
    returning id into v_major_id;
  end if;

  -- 5c. Ensure default Cohort #1 node
  select id into v_cohort_id
    from scope_nodes
   where kind = 'cohort' and parent_id = v_major_id and deleted_at is null
   order by sort, id
   limit 1;

  if v_cohort_id is null then
    select coalesce(
      (select regexp_replace(id, '[0-9]+$', '') from theory_groups order by sort, id limit 1),
      'IT3_G'
    ) into v_prefix;

    insert into scope_nodes (kind, parent_id, code, name_ar, meta, sort)
    values (
      'cohort',
      v_major_id,
      'it3',
      'الدفعة الثالثة',
      jsonb_build_object('batch', '3', 'level', '', 'theory_prefix', v_prefix),
      1
    )
    returning id into v_cohort_id;
  end if;

  -- 5d. Backfill theory_groups -> scope_nodes
  for r_tg in select id, sort, scope_node_id from theory_groups order by sort, id loop
    if r_tg.scope_node_id is null then
      select id into v_node_id
        from scope_nodes
       where kind = 'theory_group' and parent_id = v_cohort_id and code = r_tg.id and deleted_at is null
       limit 1;

      if v_node_id is null then
        insert into scope_nodes (kind, parent_id, code, name_ar, sort)
        values ('theory_group', v_cohort_id, r_tg.id, r_tg.id, r_tg.sort)
        returning id into v_node_id;
      end if;

      update theory_groups
         set scope_node_id  = v_node_id,
             cohort_node_id = v_cohort_id
       where id = r_tg.id;
    elsif exists (select 1 from theory_groups where id = r_tg.id and cohort_node_id is null) then
      update theory_groups
         set cohort_node_id = coalesce(scope_cohort_of(scope_node_id), v_cohort_id)
       where id = r_tg.id;
    end if;
  end loop;

  -- 5e. Backfill practical_groups -> scope_nodes
  for r_pg in select code, theory_group_id, sort, scope_node_id from practical_groups order by sort, code loop
    select scope_node_id into v_theory_node
      from theory_groups
     where id = r_pg.theory_group_id;

    if r_pg.scope_node_id is null and v_theory_node is not null then
      select id into v_node_id
        from scope_nodes
       where kind = 'practical_group' and parent_id = v_theory_node and code = r_pg.code and deleted_at is null
       limit 1;

      if v_node_id is null then
        insert into scope_nodes (kind, parent_id, code, name_ar, sort)
        values ('practical_group', v_theory_node, r_pg.code, r_pg.code, r_pg.sort)
        returning id into v_node_id;
      end if;

      update practical_groups
         set scope_node_id  = v_node_id,
             cohort_node_id = coalesce(scope_cohort_of(v_theory_node), v_cohort_id)
       where code = r_pg.code;
    elsif exists (select 1 from practical_groups where code = r_pg.code and cohort_node_id is null) then
      update practical_groups
         set cohort_node_id = coalesce(scope_cohort_of(scope_node_id), v_cohort_id)
       where code = r_pg.code;
    end if;
  end loop;

  -- 5f. Backfill students
  update students s
     set theory_node_id    = coalesce(s.theory_node_id, tg.scope_node_id),
         practical_node_id = coalesce(s.practical_node_id, pg.scope_node_id),
         cohort_node_id    = coalesce(s.cohort_node_id, tg.cohort_node_id, v_cohort_id)
    from theory_groups tg,
         practical_groups pg
   where tg.id = s.theory_group_id
     and pg.code = s.practical_group_id
     and (s.theory_node_id is null or s.practical_node_id is null or s.cohort_node_id is null);

  -- 5g. Backfill subjects
  update subjects
     set cohort_node_id = v_cohort_id
   where cohort_node_id is null;

  -- 5h. Backfill teaching
  update teaching t
     set scope_node_id  = tg.scope_node_id,
         cohort_node_id = coalesce(tg.cohort_node_id, v_cohort_id)
    from theory_groups tg
   where t.part = 'theory'
     and t.theory_group_id = tg.id
     and (t.scope_node_id is null or t.cohort_node_id is null);

  update teaching t
     set scope_node_id  = pg.scope_node_id,
         cohort_node_id = coalesce(pg.cohort_node_id, v_cohort_id)
    from practical_groups pg
   where t.part = 'practical'
     and t.practical_group_id = pg.code
     and (t.scope_node_id is null or t.cohort_node_id is null);

  -- 5i. Backfill tg_destinations
  update tg_destinations d
     set scope_node_id = coalesce(
       d.scope_node_id,
       case
         when d.key like '%:practical:%' then (
           select pg.scope_node_id
             from practical_groups pg
            where pg.code = split_part(d.key, ':', array_length(string_to_array(d.key, ':'), 1))
            limit 1
         )
         when d.key like '%:theory:%' or d.key like 'cohort:notices:%' then (
           select tg.scope_node_id
             from theory_groups tg
            where tg.id = split_part(d.key, ':', array_length(string_to_array(d.key, ':'), 1))
            limit 1
         )
         else v_cohort_id
       end,
       v_cohort_id
     )
   where d.scope_node_id is null;

  update tg_destinations d
     set cohort_node_id = coalesce(scope_cohort_of(d.scope_node_id), v_cohort_id)
   where d.cohort_node_id is null;

  -- 5j. Backfill users.active_cohort_node_id
  update users u
     set active_cohort_node_id = s.cohort_node_id
    from students s
   where s.telegram_id = u.telegram_id
     and s.deleted_at is null
     and s.cohort_node_id is not null
     and u.active_cohort_node_id is null;

  update users
     set active_cohort_node_id = v_cohort_id
   where kind = 'guest'
     and active_cohort_node_id is null;
end $$;

-- ---------- 6. Scope Indexes on Core Tables ----------
create unique index if not exists theory_groups_scope_node_uq
  on theory_groups (scope_node_id) where scope_node_id is not null;

create unique index if not exists practical_groups_scope_node_uq
  on practical_groups (scope_node_id) where scope_node_id is not null;

create index if not exists students_cohort_node_idx
  on students (cohort_node_id) where deleted_at is null;

create index if not exists students_theory_node_idx
  on students (theory_node_id) where deleted_at is null;

create index if not exists students_practical_node_idx
  on students (practical_node_id) where deleted_at is null;

create index if not exists subjects_cohort_node_idx
  on subjects (cohort_node_id, sort, id) where deleted_at is null;

create index if not exists teaching_cohort_node_idx
  on teaching (cohort_node_id, subject_id);

create index if not exists teaching_scope_node_idx
  on teaching (scope_node_id);

create index if not exists tg_destinations_scope_node_idx
  on tg_destinations (scope_node_id);

create index if not exists users_active_cohort_idx
  on users (active_cohort_node_id) where active_cohort_node_id is not null;

-- ---------- 7. Backup Registration (FK-ordered) ----------
create or replace function backup_tables() returns text[] language sql immutable as $$
  select array[
    'app_settings','data_versions','scope_nodes','theory_groups','practical_groups','subjects','doctors','teaching',
    'tg_destinations','students','users','role_grants','role_permissions','activity_log','link_attempts',
    'user_settings','notifications','drafts','files','assignments','assignment_files','submissions',
    'submission_files','submission_deliveries','reminders_sent','attendance_sessions','scanner_devices',
    'attendance_records','attendance_corrections','barcode_logs','grievance_cycles','grievances',
    'assistant_logs','support_tickets','report_templates','daily_reports','weekly_reports',
    'report_reminders_sent','sharek_campaigns','sharek_votes','sharek_items','sharek_sessions',
    'mcq_exams','mcq_questions','mcq_attempts'
  ];
$$;

-- ---------- 8. Security: Lock RLS & Restrict Function Execution to service_role ----------
alter table public.scope_nodes enable row level security;

revoke all on table public.scope_nodes from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;

revoke execute on function public.trg_scope_nodes_maintain_path() from public, anon, authenticated;
revoke execute on function public.scope_is_ancestor(bigint, bigint) from public, anon, authenticated;
revoke execute on function public.scope_cohort_of(bigint) from public, anon, authenticated;
revoke execute on function public.scope_college_of(bigint) from public, anon, authenticated;
revoke execute on function public.scope_tree_for_cohort(bigint) from public, anon, authenticated;
revoke execute on function public.backup_tables() from public, anon, authenticated;

grant execute on function public.scope_is_ancestor(bigint, bigint) to service_role;
grant execute on function public.scope_cohort_of(bigint) to service_role;
grant execute on function public.scope_college_of(bigint) to service_role;
grant execute on function public.scope_tree_for_cohort(bigint) to service_role;
grant execute on function public.backup_tables() to service_role;
