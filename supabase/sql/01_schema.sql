create extension if not exists pgcrypto;

do $$
begin
  if not exists (select 1 from pg_type where typname = 'question_type') then
    create type public.question_type as enum ('text', 'qcm', 'scale');
  end if;

  if not exists (select 1 from pg_type where typname = 'session_status') then
    create type public.session_status as enum (
      'waiting_partner',
      'ready',
      'in_progress',
      'pick_reveal',
      'reveal',
      'ended'
    );
  end if;

  if not exists (select 1 from pg_type where typname = 'player_slot') then
    create type public.player_slot as enum ('A', 'B');
  end if;
end $$;

create table if not exists public.questions (
  id bigint generated always as identity primary key,
  category text not null,
  type public.question_type not null,
  prompt text not null,
  options jsonb,
  scale_min smallint not null default 1,
  scale_max smallint not null default 5,
  nsfw_level smallint not null default 0 check (nsfw_level between 0 and 2),
  is_active boolean not null default true,
  created_at timestamptz not null default timezone('utc', now()),
  check (
    (type = 'text' and options is null)
    or (type = 'qcm' and options is not null and jsonb_typeof(options) = 'array')
    or (type = 'scale' and scale_min < scale_max)
  )
);

create table if not exists public.sessions (
  id uuid primary key default gen_random_uuid(),
  code text not null unique check (code ~ '^[A-Z2-9]{6}$'),
  category text not null,
  status public.session_status not null default 'waiting_partner',
  player_a_token uuid not null,
  player_b_token uuid,
  player_a_ready boolean not null default false,
  player_b_ready boolean not null default false,
  player_a_last_seen timestamptz not null default timezone('utc', now()),
  player_b_last_seen timestamptz,
  current_index smallint not null default 0 check (current_index between 0 and 10),
  reveal_index smallint not null default 0 check (reveal_index between 0 and 6),
  reveal_ack_a boolean not null default false,
  reveal_ack_b boolean not null default false,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now()),
  check (player_b_token is null or player_b_token <> player_a_token)
);

create table if not exists public.session_questions (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.sessions(id) on delete cascade,
  question_id bigint not null references public.questions(id),
  position smallint not null check (position between 0 and 9),
  unique (session_id, position),
  unique (session_id, question_id)
);

create table if not exists public.session_answers (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.sessions(id) on delete cascade,
  question_id bigint not null references public.questions(id),
  player_slot public.player_slot not null,
  answer_text text,
  answer_choice text,
  answer_scale smallint,
  passed boolean not null default false,
  done boolean not null default false,
  answered_at timestamptz,
  unique (session_id, question_id, player_slot),
  check (answer_scale is null or answer_scale between 1 and 10)
);

create table if not exists public.session_reveal_picks (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.sessions(id) on delete cascade,
  picker_slot public.player_slot not null,
  question_id bigint not null references public.questions(id),
  pick_order smallint not null check (pick_order between 1 and 3),
  created_at timestamptz not null default timezone('utc', now()),
  unique (session_id, picker_slot, pick_order),
  unique (session_id, picker_slot, question_id),
  unique (session_id, question_id)
);

create table if not exists public.session_reveal_order (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.sessions(id) on delete cascade,
  position smallint not null check (position between 0 and 5),
  question_id bigint not null references public.questions(id),
  picked_by_slot public.player_slot not null,
  unique (session_id, position)
);

create or replace function public.set_timestamp()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = timezone('utc', now());
  return new;
end;
$$;

drop trigger if exists set_sessions_timestamp on public.sessions;
create trigger set_sessions_timestamp
before update on public.sessions
for each row
execute function public.set_timestamp();

create or replace function public.generate_session_code()
returns text
language plpgsql
as $$
declare
  alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  candidate text;
  idx integer;
begin
  loop
    candidate := '';
    for idx in 1..6 loop
      candidate := candidate || substr(
        alphabet,
        1 + floor(random() * length(alphabet))::integer,
        1
      );
    end loop;

    exit when not exists (select 1 from public.sessions where code = candidate);
  end loop;

  return candidate;
end;
$$;

create or replace function public.answer_payload(
  p_answer_text text,
  p_answer_choice text,
  p_answer_scale smallint,
  p_passed boolean
)
returns jsonb
language sql
immutable
as $$
  select jsonb_build_object(
    'passed', coalesce(p_passed, false),
    'text', p_answer_text,
    'choice', p_answer_choice,
    'scale', p_answer_scale
  );
$$;

create or replace function public.cleanup_expired_sessions()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  deleted_count integer;
begin
  delete from public.sessions
  where status <> 'ended'
    and (
      (player_b_token is null and player_a_last_seen < now() - interval '5 minutes')
      or (
        player_b_token is not null
        and (
          player_a_last_seen < now() - interval '3 minutes'
          or player_b_last_seen is null
          or player_b_last_seen < now() - interval '3 minutes'
        )
      )
    );

  get diagnostics deleted_count = row_count;
  return deleted_count;
end;
$$;

create or replace function public.build_session_state(
  p_session_id uuid,
  p_player_token uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session public.sessions%rowtype;
  v_slot public.player_slot;
  v_partner_slot public.player_slot;
  v_self_ready boolean;
  v_partner_ready boolean;
  v_partner_last_seen timestamptz;
  v_current_question jsonb;
  v_pick_reveal jsonb;
  v_reveal jsonb;
begin
  select * into v_session from public.sessions where id = p_session_id;

  if not found then
    raise exception 'SESSION_NOT_FOUND';
  end if;

  if p_player_token = v_session.player_a_token then
    v_slot := 'A';
    v_partner_slot := 'B';
    v_self_ready := v_session.player_a_ready;
    v_partner_ready := coalesce(v_session.player_b_ready, false);
    v_partner_last_seen := v_session.player_b_last_seen;
  elsif p_player_token = v_session.player_b_token then
    v_slot := 'B';
    v_partner_slot := 'A';
    v_self_ready := v_session.player_b_ready;
    v_partner_ready := v_session.player_a_ready;
    v_partner_last_seen := v_session.player_a_last_seen;
  else
    raise exception 'SESSION_ACCESS_DENIED';
  end if;

  if v_session.status = 'in_progress' then
    select jsonb_build_object(
      'id', q.id,
      'position', sq.position,
      'type', q.type,
      'prompt', q.prompt,
      'options', coalesce(q.options, '[]'::jsonb),
      'scaleMin', q.scale_min,
      'scaleMax', q.scale_max,
      'selfAnswer',
        case
          when self_answer.done then public.answer_payload(
            self_answer.answer_text,
            self_answer.answer_choice,
            self_answer.answer_scale,
            self_answer.passed
          )
          else null
        end,
      'selfDone', coalesce(self_answer.done, false),
      'partnerDone', coalesce(partner_answer.done, false)
    )
    into v_current_question
    from public.session_questions sq
    join public.questions q on q.id = sq.question_id
    left join public.session_answers self_answer
      on self_answer.session_id = sq.session_id
      and self_answer.question_id = sq.question_id
      and self_answer.player_slot = v_slot
    left join public.session_answers partner_answer
      on partner_answer.session_id = sq.session_id
      and partner_answer.question_id = sq.question_id
      and partner_answer.player_slot = v_partner_slot
    where sq.session_id = v_session.id
      and sq.position = v_session.current_index;
  else
    v_current_question := null;
  end if;

  if v_session.status in ('pick_reveal', 'reveal', 'ended') then
    select jsonb_build_object(
      'questions',
        coalesce(
          jsonb_agg(
            jsonb_build_object(
              'id', q.id,
              'position', sq.position,
              'prompt', q.prompt,
              'type', q.type,
              'selectedBySelf', self_pick.question_id is not null,
              'unavailable',
                any_pick.question_id is not null
                and self_pick.question_id is null
            )
            order by sq.position
          ),
          '[]'::jsonb
        ),
      'pickedCountSelf',
        (
          select count(*)::integer
          from public.session_reveal_picks rp
          where rp.session_id = v_session.id
            and rp.picker_slot = v_slot
        ),
      'pickedCountPartner',
        (
          select count(*)::integer
          from public.session_reveal_picks rp
          where rp.session_id = v_session.id
            and rp.picker_slot = v_partner_slot
        )
    )
    into v_pick_reveal
    from public.session_questions sq
    join public.questions q on q.id = sq.question_id
    left join public.session_reveal_picks self_pick
      on self_pick.session_id = v_session.id
      and self_pick.question_id = q.id
      and self_pick.picker_slot = v_slot
    left join public.session_reveal_picks any_pick
      on any_pick.session_id = v_session.id
      and any_pick.question_id = q.id
    where sq.session_id = v_session.id;
  else
    v_pick_reveal := null;
  end if;

  if v_session.status in ('reveal', 'ended') then
    select jsonb_build_object(
      'total',
        (
          select count(*)::integer
          from public.session_reveal_order sro
          where sro.session_id = v_session.id
        ),
      'index', v_session.reveal_index,
      'selfAcknowledged',
        case when v_slot = 'A' then v_session.reveal_ack_a else v_session.reveal_ack_b end,
      'partnerAcknowledged',
        case when v_slot = 'A' then v_session.reveal_ack_b else v_session.reveal_ack_a end,
      'current',
        (
          select jsonb_build_object(
            'position', sro.position,
            'pickedBy', sro.picked_by_slot,
            'questionId', q.id,
            'prompt', q.prompt,
            'answers', jsonb_build_object(
              'A', public.answer_payload(a.answer_text, a.answer_choice, a.answer_scale, a.passed),
              'B', public.answer_payload(b.answer_text, b.answer_choice, b.answer_scale, b.passed)
            )
          )
          from public.session_reveal_order sro
          join public.questions q on q.id = sro.question_id
          join public.session_answers a
            on a.session_id = sro.session_id
            and a.question_id = sro.question_id
            and a.player_slot = 'A'
          join public.session_answers b
            on b.session_id = sro.session_id
            and b.question_id = sro.question_id
            and b.player_slot = 'B'
          where sro.session_id = v_session.id
            and sro.position = v_session.reveal_index
        )
    )
    into v_reveal;
  else
    v_reveal := null;
  end if;

  return jsonb_build_object(
    'session', jsonb_build_object(
      'code', v_session.code,
      'category', v_session.category,
      'status', v_session.status,
      'playerSlot', v_slot,
      'currentIndex', v_session.current_index,
      'revealIndex', v_session.reveal_index
    ),
    'presence', jsonb_build_object(
      'partnerJoined', v_session.player_b_token is not null,
      'selfReady', v_self_ready,
      'partnerReady', v_partner_ready,
      'partnerConnected',
        case
          when v_session.player_b_token is null then false
          else v_partner_last_seen is not null
            and v_partner_last_seen >= now() - interval '20 seconds'
        end
    ),
    'currentQuestion', v_current_question,
    'pickReveal', v_pick_reveal,
    'reveal', v_reveal
  );
end;
$$;

create or replace function public.list_categories()
returns jsonb
language sql
security definer
set search_path = public
as $$
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'category', category,
        'count', question_count,
        'maxNsfwLevel', max_nsfw_level
      )
      order by category
    ),
    '[]'::jsonb
  )
  from (
    select
      category,
      count(*)::integer as question_count,
      max(nsfw_level)::integer as max_nsfw_level
    from public.questions
    where is_active = true
    group by category
    having count(*) >= 10
  ) categories;
$$;

create or replace function public.create_session(
  p_category text,
  p_player_token uuid,
  p_max_nsfw_level smallint default 2
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session public.sessions%rowtype;
  v_category text;
  selected_count integer;
begin
  perform public.cleanup_expired_sessions();

  select q.category
  into v_category
  from public.questions q
  where lower(q.category) = lower(trim(p_category))
    and q.is_active = true
    and q.nsfw_level <= p_max_nsfw_level
  group by q.category
  having count(*) >= 10
  limit 1;

  if v_category is null then
    raise exception 'CATEGORY_NOT_AVAILABLE';
  end if;

  insert into public.sessions (code, category, status, player_a_token)
  values (public.generate_session_code(), v_category, 'waiting_partner', p_player_token)
  returning * into v_session;

  with selected_questions as (
    select
      q.id,
      row_number() over (order by random()) - 1 as position
    from public.questions q
    where q.category = v_category
      and q.is_active = true
      and q.nsfw_level <= p_max_nsfw_level
    order by random()
    limit 10
  )
  insert into public.session_questions (session_id, question_id, position)
  select v_session.id, sq.id, sq.position::smallint
  from selected_questions sq;

  get diagnostics selected_count = row_count;

  if selected_count <> 10 then
    raise exception 'NOT_ENOUGH_QUESTIONS';
  end if;

  insert into public.session_answers (session_id, question_id, player_slot)
  select v_session.id, sq.question_id, slot.player_slot
  from public.session_questions sq
  cross join (values ('A'::public.player_slot), ('B'::public.player_slot)) as slot(player_slot)
  where sq.session_id = v_session.id;

  return public.build_session_state(v_session.id, p_player_token);
end;
$$;

create or replace function public.join_session(
  p_code text,
  p_player_token uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session public.sessions%rowtype;
begin
  perform public.cleanup_expired_sessions();

  select * into v_session
  from public.sessions
  where code = upper(trim(p_code))
  for update;

  if not found then
    raise exception 'SESSION_NOT_FOUND';
  end if;

  if p_player_token = v_session.player_a_token or p_player_token = v_session.player_b_token then
    update public.sessions
    set player_a_last_seen = case when p_player_token = player_a_token then now() else player_a_last_seen end,
        player_b_last_seen = case when p_player_token = player_b_token then now() else player_b_last_seen end
    where id = v_session.id;

    return public.build_session_state(v_session.id, p_player_token);
  end if;

  if v_session.player_b_token is not null then
    raise exception 'SESSION_FULL';
  end if;

  update public.sessions
  set player_b_token = p_player_token,
      player_b_last_seen = now(),
      status = 'ready'
  where id = v_session.id;

  return public.build_session_state(v_session.id, p_player_token);
end;
$$;

create or replace function public.get_session_state(
  p_code text,
  p_player_token uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session public.sessions%rowtype;
begin
  perform public.cleanup_expired_sessions();

  select * into v_session
  from public.sessions
  where code = upper(trim(p_code))
  for update;

  if not found then
    raise exception 'SESSION_NOT_FOUND';
  end if;

  if p_player_token = v_session.player_a_token then
    update public.sessions set player_a_last_seen = now() where id = v_session.id;
  elsif p_player_token = v_session.player_b_token then
    update public.sessions set player_b_last_seen = now() where id = v_session.id;
  else
    raise exception 'SESSION_ACCESS_DENIED';
  end if;

  return public.build_session_state(v_session.id, p_player_token);
end;
$$;

create or replace function public.set_ready(
  p_code text,
  p_player_token uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session public.sessions%rowtype;
begin
  perform public.cleanup_expired_sessions();

  select * into v_session
  from public.sessions
  where code = upper(trim(p_code))
  for update;

  if not found then
    raise exception 'SESSION_NOT_FOUND';
  end if;

  if v_session.player_b_token is null then
    raise exception 'PARTNER_NOT_JOINED';
  end if;

  if p_player_token = v_session.player_a_token then
    update public.sessions
    set player_a_ready = true,
        player_a_last_seen = now()
    where id = v_session.id;
  elsif p_player_token = v_session.player_b_token then
    update public.sessions
    set player_b_ready = true,
        player_b_last_seen = now()
    where id = v_session.id;
  else
    raise exception 'SESSION_ACCESS_DENIED';
  end if;

  update public.sessions
  set status = case
    when player_a_ready = true and player_b_ready = true then 'in_progress'::public.session_status
    else 'ready'::public.session_status
  end
  where id = v_session.id;

  return public.build_session_state(v_session.id, p_player_token);
end;
$$;

create or replace function public.submit_answer(
  p_code text,
  p_player_token uuid,
  p_question_id bigint,
  p_passed boolean default false,
  p_answer_text text default null,
  p_answer_choice text default null,
  p_answer_scale smallint default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session public.sessions%rowtype;
  v_slot public.player_slot;
  v_question public.questions%rowtype;
  v_expected_question_id bigint;
  v_done_count integer;
begin
  perform public.cleanup_expired_sessions();

  select * into v_session
  from public.sessions
  where code = upper(trim(p_code))
  for update;

  if not found then
    raise exception 'SESSION_NOT_FOUND';
  end if;

  if v_session.status <> 'in_progress' then
    raise exception 'SESSION_NOT_IN_PROGRESS';
  end if;

  if p_player_token = v_session.player_a_token then
    v_slot := 'A';
    update public.sessions set player_a_last_seen = now() where id = v_session.id;
  elsif p_player_token = v_session.player_b_token then
    v_slot := 'B';
    update public.sessions set player_b_last_seen = now() where id = v_session.id;
  else
    raise exception 'SESSION_ACCESS_DENIED';
  end if;

  select sq.question_id into v_expected_question_id
  from public.session_questions sq
  where sq.session_id = v_session.id
    and sq.position = v_session.current_index;

  if v_expected_question_id is distinct from p_question_id then
    raise exception 'CURRENT_QUESTION_MISMATCH';
  end if;

  select * into v_question
  from public.questions
  where id = v_expected_question_id;

  if not p_passed then
    if v_question.type = 'text' and coalesce(trim(p_answer_text), '') = '' then
      raise exception 'ANSWER_REQUIRED';
    end if;

    if v_question.type = 'qcm' and p_answer_choice is null then
      raise exception 'ANSWER_REQUIRED';
    end if;

    if v_question.type = 'qcm' and not (coalesce(v_question.options, '[]'::jsonb) ? p_answer_choice) then
      raise exception 'INVALID_OPTION';
    end if;

    if v_question.type = 'scale' and (
      p_answer_scale is null
      or p_answer_scale < v_question.scale_min
      or p_answer_scale > v_question.scale_max
    ) then
      raise exception 'INVALID_SCALE';
    end if;
  end if;

  update public.session_answers
  set answer_text = case when p_passed then null else nullif(trim(p_answer_text), '') end,
      answer_choice = case when p_passed then null else p_answer_choice end,
      answer_scale = case when p_passed then null else p_answer_scale end,
      passed = p_passed,
      done = true,
      answered_at = now()
  where session_id = v_session.id
    and question_id = v_expected_question_id
    and player_slot = v_slot;

  select count(*)::integer into v_done_count
  from public.session_answers sa
  where sa.session_id = v_session.id
    and sa.question_id = v_expected_question_id
    and sa.done = true;

  if v_done_count = 2 then
    if v_session.current_index = 9 then
      update public.sessions set status = 'pick_reveal' where id = v_session.id;
    else
      update public.sessions
      set current_index = current_index + 1
      where id = v_session.id;
    end if;
  end if;

  return public.build_session_state(v_session.id, p_player_token);
end;
$$;

create or replace function public.pick_reveal_questions(
  p_code text,
  p_player_token uuid,
  p_question_ids bigint[]
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session public.sessions%rowtype;
  v_slot public.player_slot;
  v_existing_other_count integer;
  v_valid_question_count integer;
  v_count_a integer;
  v_count_b integer;
begin
  perform public.cleanup_expired_sessions();

  select * into v_session
  from public.sessions
  where code = upper(trim(p_code))
  for update;

  if not found then
    raise exception 'SESSION_NOT_FOUND';
  end if;

  if v_session.status <> 'pick_reveal' then
    raise exception 'SESSION_NOT_READY_FOR_REVEAL_PICK';
  end if;

  if array_length(p_question_ids, 1) <> 3 then
    raise exception 'PICK_EXACTLY_THREE';
  end if;

  if (select count(distinct question_id) from unnest(p_question_ids) as question_id) <> 3 then
    raise exception 'PICK_EXACTLY_THREE';
  end if;

  if p_player_token = v_session.player_a_token then
    v_slot := 'A';
    update public.sessions set player_a_last_seen = now() where id = v_session.id;
  elsif p_player_token = v_session.player_b_token then
    v_slot := 'B';
    update public.sessions set player_b_last_seen = now() where id = v_session.id;
  else
    raise exception 'SESSION_ACCESS_DENIED';
  end if;

  select count(*)::integer into v_valid_question_count
  from public.session_questions sq
  where sq.session_id = v_session.id
    and sq.question_id = any (p_question_ids);

  if v_valid_question_count <> 3 then
    raise exception 'INVALID_REVEAL_PICK';
  end if;

  select count(*)::integer into v_existing_other_count
  from public.session_reveal_picks rp
  where rp.session_id = v_session.id
    and rp.picker_slot <> v_slot
    and rp.question_id = any (p_question_ids);

  if v_existing_other_count > 0 then
    raise exception 'QUESTION_ALREADY_RESERVED';
  end if;

  delete from public.session_reveal_picks
  where session_id = v_session.id
    and picker_slot = v_slot;

  insert into public.session_reveal_picks (session_id, picker_slot, question_id, pick_order)
  select
    v_session.id,
    v_slot,
    selected.question_id,
    selected.ordinality::smallint
  from unnest(p_question_ids) with ordinality as selected(question_id, ordinality);

  select count(*)::integer into v_count_a
  from public.session_reveal_picks
  where session_id = v_session.id
    and picker_slot = 'A';

  select count(*)::integer into v_count_b
  from public.session_reveal_picks
  where session_id = v_session.id
    and picker_slot = 'B';

  if v_count_a = 3 and v_count_b = 3 then
    delete from public.session_reveal_order
    where session_id = v_session.id;

    insert into public.session_reveal_order (session_id, position, question_id, picked_by_slot)
    select
      v_session.id,
      ordered.position,
      ordered.question_id,
      ordered.picker_slot
    from (
      select
        ((pick_order - 1) * 2 + case when picker_slot = 'A' then 0 else 1 end)::smallint as position,
        question_id,
        picker_slot
      from public.session_reveal_picks
      where session_id = v_session.id
    ) ordered
    order by ordered.position;

    update public.sessions
    set status = 'reveal',
        reveal_index = 0,
        reveal_ack_a = false,
        reveal_ack_b = false
    where id = v_session.id;
  end if;

  return public.build_session_state(v_session.id, p_player_token);
end;
$$;

create or replace function public.advance_reveal(
  p_code text,
  p_player_token uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_session public.sessions%rowtype;
  v_last_position smallint;
begin
  perform public.cleanup_expired_sessions();

  select * into v_session
  from public.sessions
  where code = upper(trim(p_code))
  for update;

  if not found then
    raise exception 'SESSION_NOT_FOUND';
  end if;

  if v_session.status = 'ended' then
    return public.build_session_state(v_session.id, p_player_token);
  end if;

  if v_session.status <> 'reveal' then
    raise exception 'SESSION_NOT_REVEALING';
  end if;

  if p_player_token = v_session.player_a_token then
    update public.sessions
    set reveal_ack_a = true,
        player_a_last_seen = now()
    where id = v_session.id;
  elsif p_player_token = v_session.player_b_token then
    update public.sessions
    set reveal_ack_b = true,
        player_b_last_seen = now()
    where id = v_session.id;
  else
    raise exception 'SESSION_ACCESS_DENIED';
  end if;

  select max(position) into v_last_position
  from public.session_reveal_order
  where session_id = v_session.id;

  select * into v_session
  from public.sessions
  where id = v_session.id
  for update;

  if v_session.reveal_ack_a = true and v_session.reveal_ack_b = true then
    if v_session.reveal_index >= coalesce(v_last_position, 0) then
      update public.sessions
      set status = 'ended',
          reveal_index = coalesce(v_last_position, 0) + 1,
          reveal_ack_a = false,
          reveal_ack_b = false
      where id = v_session.id;
    else
      update public.sessions
      set reveal_index = reveal_index + 1,
          reveal_ack_a = false,
          reveal_ack_b = false
      where id = v_session.id;
    end if;
  end if;

  return public.build_session_state(v_session.id, p_player_token);
end;
$$;

alter table public.questions enable row level security;
alter table public.sessions enable row level security;
alter table public.session_questions enable row level security;
alter table public.session_answers enable row level security;
alter table public.session_reveal_picks enable row level security;
alter table public.session_reveal_order enable row level security;

revoke all on public.questions from anon, authenticated;
revoke all on public.sessions from anon, authenticated;
revoke all on public.session_questions from anon, authenticated;
revoke all on public.session_answers from anon, authenticated;
revoke all on public.session_reveal_picks from anon, authenticated;
revoke all on public.session_reveal_order from anon, authenticated;

grant execute on function public.list_categories() to anon, authenticated;
grant execute on function public.create_session(text, uuid, smallint) to anon, authenticated;
grant execute on function public.join_session(text, uuid) to anon, authenticated;
grant execute on function public.get_session_state(text, uuid) to anon, authenticated;
grant execute on function public.set_ready(text, uuid) to anon, authenticated;
grant execute on function public.submit_answer(text, uuid, bigint, boolean, text, text, smallint) to anon, authenticated;
grant execute on function public.pick_reveal_questions(text, uuid, bigint[]) to anon, authenticated;
grant execute on function public.advance_reveal(text, uuid) to anon, authenticated;
