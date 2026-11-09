-- On-Call Board: version history with restore, personal PINs and verified identity on saves.
-- Run once in Supabase → project "kora" → SQL Editor. Adds new oncall_ tables and functions only.
create table if not exists public.oncall_board_history (
  id bigserial primary key,
  board_id text not null references public.oncall_boards(id) on delete cascade,
  version bigint not null, state jsonb not null, updated_by text,
  created_at timestamptz not null default now()
);
create index if not exists oncall_board_history_board_idx on public.oncall_board_history (board_id, id desc);
create table if not exists public.oncall_pins (
  board_id text not null references public.oncall_boards(id) on delete cascade,
  staff_id text not null, pin_hash text not null,
  failed int not null default 0, locked_until timestamptz,
  created_at timestamptz not null default now(),
  primary key (board_id, staff_id)
);
create table if not exists public.oncall_sessions (
  token_hash text primary key,
  board_id text not null references public.oncall_boards(id) on delete cascade,
  staff_id text not null,
  created_at timestamptz not null default now(), last_used timestamptz not null default now()
);
alter table public.oncall_board_history enable row level security;
alter table public.oncall_pins enable row level security;
alter table public.oncall_sessions enable row level security;
revoke all on public.oncall_board_history, public.oncall_pins, public.oncall_sessions from anon, authenticated;

create or replace function public.oncall_staff_of(p_state jsonb, p_staff text) returns jsonb
language sql immutable set search_path = '' as $$
  select s from jsonb_array_elements(coalesce(p_state->'staff', '[]'::jsonb)) s where s->>'id' = p_staff limit 1
$$;
create or replace function public.oncall_session(p_board text, p_token text) returns text
language plpgsql security definer set search_path = '' as $$
declare sid text;
begin
  if p_token is null or length(p_token) < 20 then return null; end if;
  update public.oncall_sessions set last_used = now()
   where token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex') and board_id = p_board and created_at > now() - interval '180 days'
   returning staff_id into sid;
  return sid;
end $$;
create or replace function public.oncall_new_session(p_board text, p_staff text) returns text
language plpgsql security definer set search_path = '' as $$
declare tok text := encode(extensions.gen_random_bytes(24), 'hex');
begin
  insert into public.oncall_sessions (token_hash, board_id, staff_id) values (encode(extensions.digest(tok, 'sha256'), 'hex'), p_board, p_staff);
  return tok;
end $$;
create or replace function public.oncall_history_add(p_old public.oncall_boards, p_new jsonb, p_by text, p_force boolean default false) returns void
language plpgsql security definer set search_path = '' as $$
declare last_at timestamptz;
begin
  select created_at into last_at from public.oncall_board_history where board_id = p_old.id order by id desc limit 1;
  if p_force or last_at is null or last_at < now() - interval '10 minutes'
     or coalesce(p_old.updated_by, '') <> coalesce(p_by, '')
     or pg_column_size(p_new) < pg_column_size(p_old.state) * 0.7 then
    insert into public.oncall_board_history (board_id, version, state, updated_by, created_at)
    values (p_old.id, p_old.version, p_old.state, p_old.updated_by, now());
  end if;
  delete from public.oncall_board_history where board_id = p_old.id and created_at < now() - interval '14 days';
end $$;
create or replace function public.oncall_tier_of(p_board text, p_staff text) returns text
language sql stable security definer set search_path = '' as $$
  select public.oncall_staff_of(b.state, p_staff)->>'tier' from public.oncall_boards b where b.id = p_board
$$;

create or replace function public.oncall_save_board2(p_code text, p_token text, p_state jsonb, p_base bigint, p_by text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare k text := public.oncall_key(p_code); r public.oncall_boards%rowtype; sid text; who text;
begin
  if pg_column_size(p_state) > 1000000 then raise exception 'board too large'; end if;
  select * into r from public.oncall_boards where id = k for update;
  if not found then return jsonb_build_object('ok', false, 'missing', true); end if;
  sid := public.oncall_session(k, p_token);
  if sid is null and exists (select 1 from public.oncall_pins where board_id = k) then return jsonb_build_object('ok', false, 'signin', true); end if;
  who := case when sid is not null then coalesce(public.oncall_staff_of(r.state, sid)->>'name', public.oncall_staff_of(p_state, sid)->>'name')
              else nullif(left(coalesce(p_by, ''), 60), '') || ' (no PIN)' end;
  if r.version <> p_base then
    return jsonb_build_object('ok', false, 'version', r.version, 'state', r.state, 'updated_at', r.updated_at, 'updated_by', r.updated_by);
  end if;
  perform public.oncall_history_add(r, p_state, who);
  update public.oncall_boards set state = p_state, version = version + 1, updated_at = now(), updated_by = who where id = k returning * into r;
  return jsonb_build_object('ok', true, 'version', r.version, 'updated_at', r.updated_at, 'updated_by', r.updated_by);
end $$;
create or replace function public.oncall_save_board(p_code text, p_state jsonb, p_base bigint, p_by text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  return public.oncall_save_board2(p_code, null, p_state, p_base, p_by);
end $$;

create or replace function public.oncall_pin_status(p_code text) returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(staff_id), '[]'::jsonb) from public.oncall_pins where board_id = public.oncall_key(p_code)
$$;
create or replace function public.oncall_pin_set(p_code text, p_staff text, p_pin text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare k text := public.oncall_key(p_code); st jsonb;
begin
  if coalesce(p_pin, '') !~ '^[0-9]{4,6}$' then return jsonb_build_object('ok', false, 'error', 'The PIN must be 4 to 6 digits.'); end if;
  select state into st from public.oncall_boards where id = k;
  if not found then return jsonb_build_object('ok', false, 'error', 'Team board not found.'); end if;
  if public.oncall_staff_of(st, p_staff) is null then return jsonb_build_object('ok', false, 'error', 'That name is not on this board.'); end if;
  insert into public.oncall_pins (board_id, staff_id, pin_hash) values (k, p_staff, extensions.crypt(p_pin, extensions.gen_salt('bf'))) on conflict do nothing;
  if not found then return jsonb_build_object('ok', false, 'error', 'This name already has a PIN. Enter it, or ask a second on-call to reset it.'); end if;
  return jsonb_build_object('ok', true, 'token', public.oncall_new_session(k, p_staff));
end $$;
create or replace function public.oncall_pin_login(p_code text, p_staff text, p_pin text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare k text := public.oncall_key(p_code); p public.oncall_pins%rowtype;
begin
  select * into p from public.oncall_pins where board_id = k and staff_id = p_staff for update;
  if not found then return jsonb_build_object('ok', false, 'nopin', true, 'error', 'No PIN set for this name yet.'); end if;
  if p.locked_until is not null and p.locked_until > now() then
    return jsonb_build_object('ok', false, 'error', 'Too many wrong PINs. Try again in 15 minutes, or ask a second on-call to reset it.');
  end if;
  if p.pin_hash <> extensions.crypt(coalesce(p_pin, ''), p.pin_hash) then
    update public.oncall_pins set failed = failed + 1, locked_until = case when failed + 1 >= 5 then now() + interval '15 minutes' else null end
     where board_id = k and staff_id = p_staff;
    return jsonb_build_object('ok', false, 'error', case when p.failed + 1 >= 5 then 'Too many wrong PINs. Locked for 15 minutes.' else 'Wrong PIN.' end);
  end if;
  update public.oncall_pins set failed = 0, locked_until = null where board_id = k and staff_id = p_staff;
  return jsonb_build_object('ok', true, 'token', public.oncall_new_session(k, p_staff));
end $$;
create or replace function public.oncall_pin_reset(p_code text, p_token text, p_staff text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare k text := public.oncall_key(p_code); sid text := public.oncall_session(public.oncall_key(p_code), p_token);
begin
  if sid is null or coalesce(public.oncall_tier_of(k, sid), '') not in ('second', 'third') then
    return jsonb_build_object('ok', false, 'error', 'Only a second or third on-call signed in with their PIN can reset PINs.');
  end if;
  delete from public.oncall_pins where board_id = k and staff_id = p_staff;
  delete from public.oncall_sessions where board_id = k and staff_id = p_staff;
  return jsonb_build_object('ok', true);
end $$;
create or replace function public.oncall_sign_out(p_code text, p_token text) returns void
language sql security definer set search_path = '' as $$
  delete from public.oncall_sessions where board_id = public.oncall_key(p_code) and token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex')
$$;

create or replace function public.oncall_history_list(p_code text) returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', h.id, 'version', h.version, 'at', h.created_at, 'by', h.updated_by,
           'staff', jsonb_array_length(coalesce(h.state->'staff', '[]'::jsonb)), 'shifts', (select count(*) from jsonb_object_keys(coalesce(h.state->'shifts', '{}'::jsonb))))
         order by h.id desc), '[]'::jsonb)
  from (select * from public.oncall_board_history where board_id = public.oncall_key(p_code) order by id desc limit 40) h
$$;
create or replace function public.oncall_history_restore(p_code text, p_token text, p_id bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare k text := public.oncall_key(p_code); sid text; who text; r public.oncall_boards%rowtype; h public.oncall_board_history%rowtype;
begin
  select * into r from public.oncall_boards where id = k for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'Team board not found.'); end if;
  sid := public.oncall_session(k, p_token);
  if (sid is null and exists (select 1 from public.oncall_pins where board_id = k))
     or (sid is not null and coalesce(public.oncall_staff_of(r.state, sid)->>'tier', '') not in ('second', 'third')) then
    return jsonb_build_object('ok', false, 'error', 'Only a second or third on-call signed in with their PIN can restore.');
  end if;
  select * into h from public.oncall_board_history where id = p_id and board_id = k;
  if not found then return jsonb_build_object('ok', false, 'error', 'That version is no longer kept.'); end if;
  who := coalesce(public.oncall_staff_of(r.state, sid)->>'name', 'Someone');
  perform public.oncall_history_add(r, h.state, who, true);
  update public.oncall_boards set state = h.state, version = version + 1, updated_at = now(),
         updated_by = who || ' (restored ' || to_char(h.created_at at time zone 'Asia/Kuwait', 'Dy HH24:MI') || ')'
   where id = k returning * into r;
  return jsonb_build_object('ok', true, 'version', r.version);
end $$;

revoke all on function public.oncall_staff_of(jsonb, text), public.oncall_session(text, text), public.oncall_new_session(text, text),
  public.oncall_history_add(public.oncall_boards, jsonb, text, boolean), public.oncall_tier_of(text, text) from public, anon, authenticated;
revoke all on function public.oncall_save_board2(text, text, jsonb, bigint, text), public.oncall_save_board(text, jsonb, bigint, text),
  public.oncall_pin_status(text), public.oncall_pin_set(text, text, text), public.oncall_pin_login(text, text, text),
  public.oncall_pin_reset(text, text, text), public.oncall_sign_out(text, text), public.oncall_history_list(text),
  public.oncall_history_restore(text, text, bigint) from public;
grant execute on function public.oncall_save_board2(text, text, jsonb, bigint, text), public.oncall_save_board(text, jsonb, bigint, text),
  public.oncall_pin_status(text), public.oncall_pin_set(text, text, text), public.oncall_pin_login(text, text, text),
  public.oncall_pin_reset(text, text, text), public.oncall_sign_out(text, text), public.oncall_history_list(text),
  public.oncall_history_restore(text, text, bigint) to anon, authenticated;
