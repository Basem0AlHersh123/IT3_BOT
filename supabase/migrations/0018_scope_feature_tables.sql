-- =====================================================================
-- 0018_scope_feature_tables.sql — Phase C (Ticket C2): Tenant-Owned Feature Tables Scoping
-- Adds and backfills cohort_node_id / scope_node_id / theory_node_id on all
-- remaining tenant-owned academic workflow tables and replaces globally
-- colliding unique constraints with scope-qualified ones.
-- Append-only, idempotent (safe to re-run). ONE-WAY DOOR migration.
-- =====================================================================

-- ---------- 1. Add Scope Columns to Tenant-Owned Feature Tables ----------

-- Cohort-owned tables
alter table files
  add column if not exists cohort_node_id bigint references scope_nodes(id),
  add column if not exists group_node_id  bigint references scope_nodes(id);

alter table drafts
  add column if not exists cohort_node_id bigint references scope_nodes(id),
  add column if not exists scope_node_id  bigint references scope_nodes(id);

alter table mcq_exams
  add column if not exists cohort_node_id bigint references scope_nodes(id);

alter table support_tickets
  add column if not exists cohort_node_id bigint references scope_nodes(id);

alter table assistant_logs
  add column if not exists cohort_node_id bigint references scope_nodes(id);

alter table activity_log
  add column if not exists scope_node_id bigint references scope_nodes(id);

-- Group-owned tables (transitively belong to a Cohort via scope_nodes.path)
alter table assignments
  add column if not exists cohort_node_id bigint references scope_nodes(id),
  add column if not exists scope_node_id  bigint references scope_nodes(id);

alter table attendance_sessions
  add column if not exists cohort_node_id bigint references scope_nodes(id),
  add column if not exists theory_node_id bigint references scope_nodes(id);

alter table scanner_devices
  add column if not exists cohort_node_id bigint references scope_nodes(id),
  add column if not exists theory_node_id bigint references scope_nodes(id);

alter table grievance_cycles
  add column if not exists cohort_node_id bigint references scope_nodes(id),
  add column if not exists theory_node_id bigint references scope_nodes(id);

alter table report_templates
  add column if not exists cohort_node_id bigint references scope_nodes(id),
  add column if not exists theory_node_id bigint references scope_nodes(id);

alter table daily_reports
  add column if not exists cohort_node_id bigint references scope_nodes(id),
  add column if not exists theory_node_id bigint references scope_nodes(id);

alter table weekly_reports
  add column if not exists cohort_node_id bigint references scope_nodes(id),
  add column if not exists theory_node_id bigint references scope_nodes(id);

alter table report_reminders_sent
  add column if not exists cohort_node_id bigint references scope_nodes(id),
  add column if not exists theory_node_id bigint references scope_nodes(id);

alter table sharek_campaigns
  add column if not exists cohort_node_id bigint references scope_nodes(id),
  add column if not exists theory_node_id bigint references scope_nodes(id);

-- ---------- 2. Idempotent Backfill of Feature Tables ----------
do $$
declare
  v_default_cohort bigint;
begin
  select id into v_default_cohort
    from scope_nodes
   where kind = 'cohort' and deleted_at is null
   order by sort, id
   limit 1;

  if v_default_cohort is null then
    raise exception '0018_scope_feature_tables: no cohort node found in scope_nodes (run 0017_scope_tree.sql first)';
  end if;

  -- files: derive cohort from subject
  update files f
     set cohort_node_id = coalesce(s.cohort_node_id, v_default_cohort)
    from subjects s
   where s.id = f.subject_id
     and f.cohort_node_id is null;

  update files
     set cohort_node_id = v_default_cohort
   where cohort_node_id is null;

  -- drafts: derive cohort from payload subject_id or owner's student/user record
  update drafts d
     set cohort_node_id = coalesce(
       (select s.cohort_node_id from subjects s where s.id = (d.payload->>'subject_id')::smallint),
       (select st.cohort_node_id from students st where st.telegram_id = d.owner_id and st.deleted_at is null limit 1),
       (select u.active_cohort_node_id from users u where u.telegram_id = d.owner_id),
       v_default_cohort
     )
   where d.cohort_node_id is null;

  update drafts d
     set scope_node_id = coalesce(
       d.scope_node_id,
       (select pg.scope_node_id from practical_groups pg where pg.code = d.payload->>'practical_group_id' limit 1),
       (select tg.scope_node_id from theory_groups tg where tg.id = d.payload->>'theory_group_id' limit 1),
       d.cohort_node_id
     )
   where d.scope_node_id is null;

  -- mcq_exams: derive cohort from subject
  update mcq_exams e
     set cohort_node_id = coalesce(s.cohort_node_id, v_default_cohort)
    from subjects s
   where s.id = e.subject_id
     and e.cohort_node_id is null;

  update mcq_exams
     set cohort_node_id = v_default_cohort
   where cohort_node_id is null;

  -- support_tickets: derive cohort from submitter's student/user record
  update support_tickets t
     set cohort_node_id = coalesce(
       (select st.cohort_node_id from students st where st.telegram_id = t.telegram_id and st.deleted_at is null limit 1),
       (select u.active_cohort_node_id from users u where u.telegram_id = t.telegram_id),
       v_default_cohort
     )
   where t.cohort_node_id is null;

  -- assistant_logs: derive cohort from user's student/user record
  update assistant_logs a
     set cohort_node_id = coalesce(
       (select st.cohort_node_id from students st where st.telegram_id = a.telegram_id and st.deleted_at is null limit 1),
       (select u.active_cohort_node_id from users u where u.telegram_id = a.telegram_id),
       v_default_cohort
     )
   where a.cohort_node_id is null;

  -- assignments: derive scope_node_id from theory_group or practical_group, cohort from subject/group
  update assignments a
     set scope_node_id  = tg.scope_node_id,
         cohort_node_id = coalesce(tg.cohort_node_id, v_default_cohort)
    from theory_groups tg
   where a.part = 'theory'
     and a.theory_group_id = tg.id
     and (a.scope_node_id is null or a.cohort_node_id is null);

  update assignments a
     set scope_node_id  = pg.scope_node_id,
         cohort_node_id = coalesce(pg.cohort_node_id, v_default_cohort)
    from practical_groups pg
   where a.part = 'practical'
     and a.practical_group_id = pg.code
     and (a.scope_node_id is null or a.cohort_node_id is null);

  update assignments a
     set cohort_node_id = coalesce((select s.cohort_node_id from subjects s where s.id = a.subject_id), v_default_cohort),
         scope_node_id  = coalesce(a.scope_node_id, (select s.cohort_node_id from subjects s where s.id = a.subject_id), v_default_cohort)
   where a.cohort_node_id is null or a.scope_node_id is null;

  -- attendance_sessions
  update attendance_sessions s
     set theory_node_id = tg.scope_node_id,
         cohort_node_id = coalesce(tg.cohort_node_id, v_default_cohort)
    from theory_groups tg
   where tg.id = s.theory_group_id
     and (s.theory_node_id is null or s.cohort_node_id is null);

  -- scanner_devices
  update scanner_devices sd
     set theory_node_id = tg.scope_node_id,
         cohort_node_id = coalesce(tg.cohort_node_id, v_default_cohort)
    from theory_groups tg
   where tg.id = sd.theory_group_id
     and (sd.theory_node_id is null or sd.cohort_node_id is null);

  -- grievance_cycles (theory_group_id may be null for cohort-wide cycle)
  update grievance_cycles gc
     set theory_node_id = tg.scope_node_id,
         cohort_node_id = coalesce(tg.cohort_node_id, v_default_cohort)
    from theory_groups tg
   where gc.theory_group_id = tg.id
     and (gc.theory_node_id is null or gc.cohort_node_id is null);

  update grievance_cycles gc
     set cohort_node_id = coalesce((select s.cohort_node_id from subjects s where s.id = gc.subject_id), v_default_cohort)
   where gc.cohort_node_id is null;

  -- report_templates
  update report_templates rt
     set theory_node_id = tg.scope_node_id,
         cohort_node_id = coalesce(tg.cohort_node_id, v_default_cohort)
    from theory_groups tg
   where tg.id = rt.theory_group_id
     and (rt.theory_node_id is null or rt.cohort_node_id is null);

  -- daily_reports
  update daily_reports dr
     set theory_node_id = tg.scope_node_id,
         cohort_node_id = coalesce(tg.cohort_node_id, v_default_cohort)
    from theory_groups tg
   where tg.id = dr.theory_group_id
     and (dr.theory_node_id is null or dr.cohort_node_id is null);

  -- weekly_reports
  update weekly_reports wr
     set theory_node_id = tg.scope_node_id,
         cohort_node_id = coalesce(tg.cohort_node_id, v_default_cohort)
    from theory_groups tg
   where tg.id = wr.theory_group_id
     and (wr.theory_node_id is null or wr.cohort_node_id is null);

  -- report_reminders_sent
  update report_reminders_sent rr
     set theory_node_id = tg.scope_node_id,
         cohort_node_id = coalesce(tg.cohort_node_id, v_default_cohort)
    from theory_groups tg
   where tg.id = rr.theory_group_id
     and (rr.theory_node_id is null or rr.cohort_node_id is null);

  -- sharek_campaigns (theory_group_id may be null for cohort-wide campaign)
  update sharek_campaigns sc
     set theory_node_id = tg.scope_node_id,
         cohort_node_id = coalesce(tg.cohort_node_id, v_default_cohort)
    from theory_groups tg
   where sc.theory_group_id = tg.id
     and (sc.theory_node_id is null or sc.cohort_node_id is null);

  update sharek_campaigns
     set cohort_node_id = v_default_cohort
   where cohort_node_id is null;
end $$;

-- ---------- 3. Replace Globally Colliding Unique Constraints ----------

-- 3a. subjects: allow identical Arabic subject names in different Cohorts
alter table subjects drop constraint if exists subjects_name_ar_key;
create unique index if not exists subjects_cohort_name_ar_uq
  on subjects (cohort_node_id, name_ar) where deleted_at is null;

-- 3b. teaching: scope-node-qualified uniqueness alongside legacy indexes
create unique index if not exists teaching_subject_scope_uq
  on teaching (subject_id, scope_node_id) where scope_node_id is not null;

-- 3c. tg_destinations: migrate PK from global (key) to surrogate (id) + unique (scope_node_id, key)
alter table tg_destinations
  add column if not exists id bigint generated by default as identity;

do $$
declare
  v_pk_cols text[];
begin
  select array_agg(a.attname order by u.ord)
    into v_pk_cols
    from pg_constraint c
    join lateral unnest(c.conkey) with ordinality as u(attnum, ord) on true
    join pg_attribute a on a.attrelid = c.conrelid and a.attnum = u.attnum
   where c.conrelid = 'public.tg_destinations'::regclass
     and c.contype = 'p';

  if v_pk_cols = array['key'] then
    alter table public.tg_destinations drop constraint tg_destinations_pkey;
    alter table public.tg_destinations add primary key (id);
  end if;
end $$;

create unique index if not exists tg_destinations_scope_key_uq
  on tg_destinations (scope_node_id, key) where scope_node_id is not null;

-- ---------- 4. Scope Indexes on Feature Tables ----------
create index if not exists files_cohort_node_idx
  on files (cohort_node_id, subject_id, part, content_type, created_at desc) where deleted_at is null;

create index if not exists drafts_cohort_node_idx
  on drafts (cohort_node_id, owner_id, kind, id desc) where state = 'open';

create index if not exists mcq_exams_cohort_node_idx
  on mcq_exams (cohort_node_id, subject_id, id desc) where deleted_at is null;

create index if not exists support_tickets_cohort_node_idx
  on support_tickets (cohort_node_id, status, id desc);

create index if not exists assistant_logs_cohort_node_idx
  on assistant_logs (cohort_node_id, telegram_id, day_sanaa desc);

create index if not exists activity_log_scope_node_idx
  on activity_log (scope_node_id, at desc) where scope_node_id is not null;

create index if not exists assignments_cohort_node_idx
  on assignments (cohort_node_id, scope_node_id, closes_at) where deleted_at is null;

create unique index if not exists assignments_scope_number_uq
  on assignments (subject_id, scope_node_id, number) where scope_node_id is not null and deleted_at is null;

create index if not exists attendance_sessions_cohort_node_idx
  on attendance_sessions (cohort_node_id, theory_node_id, subject_id, lecture_no);

create unique index if not exists attendance_sessions_scope_lecture_uq
  on attendance_sessions (subject_id, theory_node_id, lecture_no) where theory_node_id is not null;

create unique index if not exists attendance_one_open_per_theory_node_uq
  on attendance_sessions (theory_node_id) where status = 'open' and theory_node_id is not null;

create index if not exists scanner_devices_theory_node_idx
  on scanner_devices (theory_node_id);

create index if not exists grievance_cycles_cohort_node_idx
  on grievance_cycles (cohort_node_id, theory_node_id, closes_at);

create unique index if not exists report_templates_theory_node_uq
  on report_templates (theory_node_id, weekday) where theory_node_id is not null;

create unique index if not exists daily_reports_theory_node_date_uq
  on daily_reports (theory_node_id, report_date) where theory_node_id is not null;

create unique index if not exists weekly_reports_theory_node_week_uq
  on weekly_reports (theory_node_id, week_start) where theory_node_id is not null;

create unique index if not exists report_reminders_theory_node_date_uq
  on report_reminders_sent (theory_node_id, report_date) where theory_node_id is not null;

create index if not exists sharek_campaigns_cohort_node_idx
  on sharek_campaigns (cohort_node_id, theory_node_id, id desc) where status = 'open';

-- Ensure any new sequences (e.g. tg_destinations.id) remain inaccessible to anon/authenticated
revoke all on all sequences in schema public from anon, authenticated;
