-- =====================================================================
-- 0022_assignment_number_reuse.sql
-- Fix soft-delete assignment numbering gap (fully multi-tenant scoped):
--   1. Make assignments_number_uq partial (where deleted_at is null) so
--      soft-deleted assignments do not reserve numbers.
--   2. In publish_assignment, resolve scope_node_id from scope_nodes under
--      the subject's cohort_node_id, enforce require_perm_scoped, pick the
--      smallest unused active number, and strictly isolate notifications,
--      teaching lookup, and tg_destinations by cohort/scope node.
--   3. In restore_assignment, enforce require_perm_scoped and reassign the
--      next active number if the original number was reused while deleted.
-- Append-only, idempotent. Safe to run after 0021_major_admin.sql.
-- =====================================================================

drop index if exists assignments_number_uq;
create unique index if not exists assignments_number_uq
  on assignments (subject_id, part, coalesce(theory_group_id, practical_group_id), number)
  where deleted_at is null;

create or replace function next_active_assignment_number(
  p_subject smallint,
  p_part text,
  p_group text,
  p_scope_node_id bigint default null
) returns int
language sql stable security definer set search_path = public as $$
  with active_nums as (
    select distinct number
      from assignments
     where subject_id = p_subject
       and part = p_part
       and deleted_at is null
       and (
         (p_scope_node_id is not null and scope_node_id = p_scope_node_id)
         or (p_scope_node_id is null and coalesce(theory_group_id, practical_group_id) = p_group)
       )
  ),
  bounds as (
    select coalesce(max(number), 0) + 1 as upper_n from active_nums
  )
  select min(g.n)::int
    from bounds b, generate_series(1, b.upper_n) as g(n)
   where not exists (select 1 from active_nums a where a.number = g.n);
$$;

create or replace function publish_assignment(p_actor bigint, p_draft bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  d drafts%rowtype; pl jsonb; v_part text; v_group text; v_theory text; v_n int; v_id bigint;
  v_due timestamptz; v_doc smallint; v_subject text; r record; v_payload jsonb; v_dest tg_destinations%rowtype;
  v_subject_id smallint; v_cohort_node bigint; v_scope_node bigint; v_theory_node bigint;
begin
  select * into d from drafts where id = p_draft and owner_id = p_actor and kind = 'assignment' and state = 'open' for update;
  if not found then return jsonb_build_object('status', 'no_draft'); end if;

  pl := d.payload;
  v_subject_id := (pl->>'subject_id')::smallint;
  v_part := pl->>'part';
  v_group := pl->>'group';
  v_due := (pl->>'due_at')::timestamptz;
  if v_due <= now() then return jsonb_build_object('status', 'due_in_past'); end if;

  select name_ar, cohort_node_id into v_subject, v_cohort_node
    from subjects where id = v_subject_id;
  v_cohort_node := coalesce(v_cohort_node, d.cohort_node_id);

  -- Resolve target group node inside the subject's Cohort (multi-tenant safe)
  if (pl->>'scope_node_id') ~ '^\d+$' then
    v_scope_node := (pl->>'scope_node_id')::bigint;
  elsif v_cohort_node is not null then
    select id into v_scope_node
      from scope_nodes
     where kind = case when v_part = 'theory' then 'theory_group' else 'practical_group' end
       and code = v_group
       and path @> array[v_cohort_node]
       and deleted_at is null
     limit 1;
  end if;

  -- Legacy single-cohort fallback if scope_node_id is not yet populated
  if v_scope_node is null then
    if v_part = 'theory' then
      select scope_node_id into v_scope_node from theory_groups where id = v_group;
    else
      select scope_node_id into v_scope_node from practical_groups where code = v_group limit 1;
    end if;
  end if;

  if v_scope_node is not null then
    v_cohort_node := coalesce(v_cohort_node, scope_cohort_of(v_scope_node));
    if v_part = 'theory' then
      v_theory_node := v_scope_node;
      v_theory := v_group;
    else
      select p.id, p.code into v_theory_node, v_theory
        from scope_nodes c join scope_nodes p on p.id = c.parent_id
       where c.id = v_scope_node and p.kind = 'theory_group'
       limit 1;
    end if;
    perform require_perm_scoped(p_actor, 'assignments.create', v_scope_node);
  else
    v_theory := theory_of(v_group);
    perform require_perm(p_actor, 'assignments.create', v_theory);
  end if;

  perform pg_advisory_xact_lock(hashtext('asg:' || v_subject_id::text || ':' || v_part || ':' || coalesce(v_scope_node::text, v_group)));
  v_n := next_active_assignment_number(v_subject_id, v_part, v_group, v_scope_node);

  select doctor_id into v_doc from teaching
   where subject_id = v_subject_id
     and part = v_part
     and (
       (v_scope_node is not null and scope_node_id = v_scope_node)
       or (v_scope_node is null and coalesce(theory_group_id, practical_group_id) = v_group)
     )
   limit 1;

  insert into assignments (subject_id, part, theory_group_id, practical_group_id, number, description, due_at, closes_at, doctor_id, created_by, allow_text, scope_node_id, cohort_node_id)
  values (v_subject_id, v_part,
          case when v_part = 'theory' then v_group end, case when v_part = 'practical' then v_group end,
          v_n, nullif(pl->>'description', ''), v_due, v_due + grace_interval(), v_doc, p_actor,
          coalesce(pl->>'allow_text', 'false') in ('true', 't', '1'), v_scope_node, v_cohort_node)
  returning id into v_id;

  insert into assignment_files (assignment_id, media_kind, tg_file_id, file_name, position)
  select v_id, a->>'media_kind', a->>'file_id', a->>'name', ord::int
    from jsonb_array_elements(d.attachments) with ordinality t(a, ord);
  update drafts set state = 'done' where id = d.id;

  v_payload := jsonb_build_object('assignment_id', v_id, 'number', v_n, 'subject', v_subject, 'part', v_part, 'group', v_group,
                                  'description', nullif(pl->>'description', ''), 'due_at', v_due,
                                  'has_attachment', jsonb_array_length(d.attachments) > 0,
                                  'allow_text', coalesce(pl->>'allow_text', 'false') in ('true', 't', '1'));
  for r in
    select s.telegram_id as tg, coalesce(us.notify_assignment, true) as push
      from students s left join user_settings us on us.telegram_id = s.telegram_id
     where s.deleted_at is null and s.telegram_id is not null
       and (v_cohort_node is null or s.cohort_node_id = v_cohort_node)
       and (
         (v_scope_node is not null and (
           (v_part = 'theory' and s.theory_node_id = v_scope_node)
           or (v_part = 'practical' and s.practical_node_id = v_scope_node)
         ))
         or (v_scope_node is null and (
           (v_part = 'theory' and s.theory_group_id = v_group)
           or (v_part = 'practical' and s.practical_group_id = v_group)
         ))
       )
  loop
    perform notify_user(r.tg, 'assignment_new', v_payload, r.push, 'asg_new:' || v_id || ':' || r.tg);
  end loop;

  if v_cohort_node is not null then
    select * into v_dest from tg_destinations
     where key = 'cohort:notices:' || coalesce(v_theory, v_group)
       and (scope_node_id = v_cohort_node or scope_node_id = v_theory_node)
     order by (scope_node_id = v_theory_node) desc
     limit 1;
  else
    select * into v_dest from tg_destinations where key = 'cohort:notices:' || coalesce(v_theory, v_group) limit 1;
  end if;
  if found then
    insert into outbox (kind, chat_id, topic_id, payload, dedupe_key)
    values ('assignment_post', v_dest.chat_id, v_dest.topic_id, v_payload, 'asg_post:' || v_id) on conflict (dedupe_key) do nothing;
  end if;
  perform log_activity(p_actor, 'assignment.publish', 'assignment', v_id::text,
                       jsonb_build_object('group', v_group, 'number', v_n, 'scope_node_id', v_scope_node));
  return jsonb_build_object('status', 'ok', 'id', v_id, 'number', v_n);
end $$;

create or replace function restore_assignment(p_actor bigint, p_id bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  a assignments%rowtype;
  v_group text;
  v_new_n int;
begin
  select * into a from assignments where id = p_id and deleted_at is not null for update;
  if not found then return jsonb_build_object('status', 'not_found'); end if;
  v_group := coalesce(a.theory_group_id, a.practical_group_id);

  if a.scope_node_id is not null then
    perform require_perm_scoped(p_actor, 'assignments.manage', a.scope_node_id);
  else
    perform require_perm(p_actor, 'assignments.manage', theory_of(v_group));
  end if;

  perform pg_advisory_xact_lock(hashtext('asg:' || a.subject_id::text || ':' || a.part || ':' || coalesce(a.scope_node_id::text, v_group)));

  v_new_n := a.number;
  if exists (
    select 1 from assignments
     where subject_id = a.subject_id
       and part = a.part
       and deleted_at is null
       and number = a.number
       and (
         (a.scope_node_id is not null and scope_node_id = a.scope_node_id)
         or (a.scope_node_id is null and coalesce(theory_group_id, practical_group_id) = v_group)
       )
  ) then
    v_new_n := next_active_assignment_number(a.subject_id, a.part, v_group, a.scope_node_id);
  end if;

  update assignments set deleted_at = null, deleted_by = null, number = v_new_n where id = p_id;
  perform log_activity(p_actor, 'assignment.restore', 'assignment', p_id::text,
                       jsonb_build_object('number', v_new_n, 'scope_node_id', a.scope_node_id));
  return jsonb_build_object('status', 'ok', 'number', v_new_n);
end $$;

revoke execute on function next_active_assignment_number(smallint, text, text, bigint) from public, anon, authenticated;
grant execute on function next_active_assignment_number(smallint, text, text, bigint) to service_role;
revoke execute on function publish_assignment(bigint, bigint) from public, anon, authenticated;
grant execute on function publish_assignment(bigint, bigint) to service_role;
revoke execute on function restore_assignment(bigint, bigint) from public, anon, authenticated;
grant execute on function restore_assignment(bigint, bigint) to service_role;
