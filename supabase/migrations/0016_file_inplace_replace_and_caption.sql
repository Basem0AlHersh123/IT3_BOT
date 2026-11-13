-- =====================================================================
-- 0016_file_inplace_replace_and_caption.sql
-- 1) get_file يعيد التعليق المحفوظ (caption بعلامات 🔹) كي يصل الملف إلى الطالب بنفس الصيغة المعتمدة
--    حتى لو تعذّر النسخ من رسالة المجتمع (لم يُضبط المجتمع، أو حُذفت الرسالة، أو بعد الاسترجاع).
-- 2) استبدال الملف «في مكانه»: prepare_file يعيد مرجع رسالة المجتمع القديمة (ولا يعدّ إعادة الملف نفسه تكرارًا)،
--    و register_file يحدّث نفس سجل الملف (نفس الرقم ونفس تاريخ الإنشاء ونفس الترتيب) بدل إنشاء سجل جديد وحذف القديم.
-- آمن تمامًا على البيانات الحالية: دوال فقط (create or replace) دون تغيير أي جدول أو أي صف. شغّله بعد 0015.
-- =====================================================================

create or replace function get_file(p_tg bigint, p_id bigint) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare f files%rowtype;
begin
  perform require_perm(p_tg, 'files.view');
  select * into f from files where id = p_id and deleted_at is null;
  if not found then return jsonb_build_object('status', 'not_found'); end if;
  return jsonb_build_object('status', 'ok', 'src_chat', f.chat_id, 'src_msg', f.message_id,
                            'media_kind', f.media_kind, 'file_id', f.tg_file_id, 'caption', f.caption);
end $$;

create or replace function prepare_file(p_actor bigint, p_unique text, p_draft bigint default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare d drafts%rowtype; v_s subjects%rowtype; v_dup bigint; v_rid bigint; v_rep files%rowtype;
begin
  perform require_perm(p_actor, 'files.upload');
  select * into d from drafts
   where owner_id = p_actor and kind = 'file' and state = 'open' and expires_at > now()
     and (p_draft is null or id = p_draft)
   order by id desc limit 1;
  if not found then return jsonb_build_object('status', 'no_draft'); end if;
  select * into v_s from subjects where id = (d.payload->>'subject_id')::smallint;
  v_rid := nullif(d.payload->>'replaces_id', '')::bigint;
  if v_rid is not null then
    select * into v_rep from files where id = v_rid and deleted_at is null;
  end if;
  select id into v_dup from files
   where tg_unique_id = p_unique and deleted_at is null and subject_id = v_s.id
     and (v_rid is null or id <> v_rid)
   limit 1;
  return jsonb_build_object('status', 'ok', 'draft_id', d.id, 'payload', d.payload,
    'subject', jsonb_build_object('id', v_s.id, 'name', v_s.name_ar, 'tag', v_s.hashtag),
    'doctor', resolve_doctor(v_s.id, d.payload->>'part', nullif(d.payload->>'doctor_id', '')::int), 'duplicate', v_dup,
    'replace', case when v_rep.id is not null
                    then jsonb_build_object('id', v_rep.id, 'chat_id', v_rep.chat_id,
                                            'topic_id', v_rep.topic_id, 'message_id', v_rep.message_id) end);
end $$;

create or replace function register_file(p_actor bigint, p_draft bigint, p_media jsonb, p_post jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare d drafts%rowtype; pl jsonb; v_id bigint; v_doc smallint; v_rid bigint; v_inplace boolean := false;
begin
  perform require_perm(p_actor, 'files.upload');
  select * into d from drafts where id = p_draft and owner_id = p_actor and kind = 'file' and state = 'open' for update;
  if not found then return jsonb_build_object('status', 'no_draft'); end if;
  pl := d.payload;
  v_doc := (resolve_doctor((pl->>'subject_id')::int, pl->>'part', nullif(pl->>'doctor_id', '')::int)->>'id')::smallint;
  v_rid := nullif(pl->>'replaces_id', '')::bigint;

  if v_rid is not null then
    perform 1 from files where id = v_rid and deleted_at is null for update;
    v_inplace := found;
  end if;

  if v_inplace then
    -- استبدال في المكان: نفس السجل (الرقم والتاريخ والترتيب) مع الملف والتعليق الجديدين
    update files set
           subject_id = (pl->>'subject_id')::smallint, part = pl->>'part', doctor_id = v_doc,
           content_type = pl->>'content_type', exam_kind = nullif(pl->>'exam_kind', ''), label_kind = nullif(pl->>'label_kind', ''),
           numbers = coalesce(array(select x::smallint from jsonb_array_elements_text(coalesce(pl->'numbers', '[]'::jsonb)) x order by 1), '{}'),
           description = nullif(pl->>'description', ''), caption = p_post->>'caption',
           media_kind = p_media->>'media_kind', tg_file_id = p_media->>'file_id', tg_unique_id = p_media->>'unique_id',
           file_name = p_media->>'name', mime = p_media->>'mime', size = (p_media->>'size')::bigint,
           chat_id = (p_post->>'chat_id')::bigint, topic_id = (p_post->>'topic_id')::int, message_id = (p_post->>'message_id')::int
     where id = v_rid;
    v_id := v_rid;
  else
    insert into files (subject_id, part, doctor_id, content_type, exam_kind, label_kind, numbers, description, caption,
                       media_kind, tg_file_id, tg_unique_id, file_name, mime, size, chat_id, topic_id, message_id, uploaded_by)
    values ((pl->>'subject_id')::smallint, pl->>'part', v_doc, pl->>'content_type', nullif(pl->>'exam_kind', ''), nullif(pl->>'label_kind', ''),
            coalesce(array(select x::smallint from jsonb_array_elements_text(coalesce(pl->'numbers', '[]'::jsonb)) x order by 1), '{}'),
            nullif(pl->>'description', ''), p_post->>'caption',
            p_media->>'media_kind', p_media->>'file_id', p_media->>'unique_id', p_media->>'name', p_media->>'mime', (p_media->>'size')::bigint,
            (p_post->>'chat_id')::bigint, (p_post->>'topic_id')::int, (p_post->>'message_id')::int, p_actor)
    returning id into v_id;
  end if;

  update drafts set state = 'done' where id = d.id;
  perform log_activity(p_actor, case when v_inplace then 'file.replace' else 'file.upload' end, 'file', v_id::text,
                       jsonb_build_object('subject', pl->>'subject_id', 'type', pl->>'content_type'));
  return jsonb_build_object('status', 'ok', 'file_id', v_id, 'replaced', v_inplace, 'old', null);
end $$;
