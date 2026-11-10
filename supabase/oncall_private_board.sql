-- On-Call Board: private boards (only signed-in staff can see them), personal invites, sign-in by name + PIN,
-- and a stronger PIN lockout. Run once in Supabase → project "kora" → SQL Editor. Adds/updates oncall_ objects only.

alter table public.oncall_boards add column if not exists private boolean not null default false;

create table if not exists public.oncall_invites (
  code_hash text primary key,
  board_id text not null references public.oncall_boards(id) on delete cascade,
  staff_id text not null, created_by text,
  created_at timestamptz not null default now(), expires_at timestamptz not null, used_at timestamptz
);
alter table public.oncall_invites enable row level security;
revoke all on public.oncall_invites from anon, authenticated;

-- a private board answers only to a signed-in phone
create or replace function public.oncall_can_read(p_board text, p_token text) returns boolean
language sql security definer set search_path = '' as $$
  select coalesce((select not b.private from public.oncall_boards b where b.id = p_board), false)
      or public.oncall_session(p_board, p_token) is not null
$$;

create or replace function public.oncall_get_board2(p_code text, p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare k text := public.oncall_key(p_code); r public.oncall_boards%rowtype; sid text;
begin
  select * into r from public.oncall_boards where id = k;
  if not found then return jsonb_build_object('ok', false, 'missing', true); end if;
  sid := public.oncall_session(k, p_token);
  if r.private and sid is null then return jsonb_build_object('ok', false, 'signin', true, 'private', true); end if;
  return jsonb_build_object('ok', true, 'state', r.state, 'version', r.version, 'updated_at', r.updated_at, 'updated_by', r.updated_by, 'private', r.private, 'me', sid);
end $$;

create or replace function public.oncall_board_version2(p_code text, p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare k text := public.oncall_key(p_code); r public.oncall_boards%rowtype;
begin
  select * into r from public.oncall_boards where id = k;
  if not found then return jsonb_build_object('ok', false, 'missing', true); end if;
  if r.private and public.oncall_session(k, p_token) is null then return jsonb_build_object('ok', false, 'signin', true, 'private', true); end if;
  return jsonb_build_object('ok', true, 'version', r.version, 'private', r.private);
end $$;

-- the older read paths stop answering once a board is private
create or replace function public.oncall_get_board(p_code text)
returns table (state jsonb, version bigint, updated_at timestamptz, updated_by text)
language sql stable security definer set search_path = '' as $$
  select b.state, b.version, b.updated_at, b.updated_by from public.oncall_boards b where b.id = public.oncall_key(p_code) and not b.private
$$;
create or replace function public.oncall_board_version(p_code text) returns bigint
language sql stable security definer set search_path = '' as $$
  select b.version from public.oncall_boards b where b.id = public.oncall_key(p_code) and not b.private
$$;
create or replace function public.oncall_pin_status(p_code text) returns jsonb
language sql stable security definer set search_path = '' as $$
  select case when coalesce((select private from public.oncall_boards where id = public.oncall_key(p_code)), false) then '[]'::jsonb
    else (select coalesce(jsonb_agg(staff_id), '[]'::jsonb) from public.oncall_pins where board_id = public.oncall_key(p_code)) end
$$;
create or replace function public.oncall_pin_status2(p_code text, p_token text) returns jsonb
language sql security definer set search_path = '' as $$
  select case when public.oncall_can_read(public.oncall_key(p_code), p_token)
    then (select coalesce(jsonb_agg(staff_id), '[]'::jsonb) from public.oncall_pins where board_id = public.oncall_key(p_code)) else '[]'::jsonb end
$$;
-- keep the history listing itself in one place; the public name now returns nothing for private boards
create or replace function public.oncall_history_list_all(p_code text) returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', h.id, 'version', h.version, 'at', h.created_at, 'by', h.updated_by,
           'staff', jsonb_array_length(coalesce(h.state->'staff', '[]'::jsonb)), 'shifts', (select count(*) from jsonb_object_keys(coalesce(h.state->'shifts', '{}'::jsonb))))
         order by h.id desc), '[]'::jsonb)
  from (select * from public.oncall_board_history where board_id = public.oncall_key(p_code) order by id desc limit 40) h
$$;
create or replace function public.oncall_history_list2(p_code text, p_token text) returns jsonb
language sql security definer set search_path = '' as $$
  select case when public.oncall_can_read(public.oncall_key(p_code), p_token) then public.oncall_history_list_all(p_code) else '[]'::jsonb end
$$;

create or replace function public.oncall_history_list(p_code text) returns jsonb
language sql stable security definer set search_path = '' as $$
  select case when coalesce((select private from public.oncall_boards where id = public.oncall_key(p_code)), false) then '[]'::jsonb
    else public.oncall_history_list_all(p_code) end
$$;

-- claiming a name without an invite is not allowed on a private board
create or replace function public.oncall_pin_set(p_code text, p_staff text, p_pin text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare k text := public.oncall_key(p_code); st jsonb; priv boolean;
begin
  if coalesce(p_pin, '') !~ '^[0-9]{4,6}$' then return jsonb_build_object('ok', false, 'error', 'The PIN must be 4 to 6 digits.'); end if;
  select state, private into st, priv from public.oncall_boards where id = k;
  if not found then return jsonb_build_object('ok', false, 'error', 'Team board not found.'); end if;
  if priv then return jsonb_build_object('ok', false, 'error', 'This board is private. Ask a second on-call for an invite code.'); end if;
  if public.oncall_staff_of(st, p_staff) is null then return jsonb_build_object('ok', false, 'error', 'That name is not on this board.'); end if;
  insert into public.oncall_pins (board_id, staff_id, pin_hash) values (k, p_staff, extensions.crypt(p_pin, extensions.gen_salt('bf'))) on conflict do nothing;
  if not found then return jsonb_build_object('ok', false, 'error', 'This name already has a PIN. Enter it, or ask a second on-call to reset it.'); end if;
  return jsonb_build_object('ok', true, 'token', public.oncall_new_session(k, p_staff));
end $$;

-- PIN check shared by sign-in paths: 5 wrong → 15 min lock, 10 wrong → 24 h lock
create or replace function public.oncall_check_pin(p_board text, p_staff text, p_pin text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare p public.oncall_pins%rowtype; f int;
begin
  select * into p from public.oncall_pins where board_id = p_board and staff_id = p_staff for update;
  if not found then return jsonb_build_object('ok', false, 'nopin', true, 'error', 'No PIN set for this name yet.'); end if;
  if p.locked_until is not null and p.locked_until > now() then
    return jsonb_build_object('ok', false, 'error', 'Too many wrong PINs. This name is locked for now; ask a second on-call to send you an invite.');
  end if;
  if p.pin_hash <> extensions.crypt(coalesce(p_pin, ''), p.pin_hash) then
    f := p.failed + 1;
    update public.oncall_pins set failed = f,
      locked_until = case when f >= 10 then now() + interval '24 hours' when f % 5 = 0 then now() + interval '15 minutes' else null end
     where board_id = p_board and staff_id = p_staff;
    return jsonb_build_object('ok', false, 'error', case when f >= 10 then 'Too many wrong PINs. Locked for 24 hours.' when f % 5 = 0 then 'Too many wrong PINs. Locked for 15 minutes.' else 'Name or PIN not right.' end);
  end if;
  update public.oncall_pins set failed = 0, locked_until = null where board_id = p_board and staff_id = p_staff;
  return jsonb_build_object('ok', true, 'token', public.oncall_new_session(p_board, p_staff));
end $$;
create or replace function public.oncall_pin_login(p_code text, p_staff text, p_pin text) returns jsonb
language sql security definer set search_path = '' as $$
  select public.oncall_check_pin(public.oncall_key(p_code), p_staff, p_pin)
$$;

-- sign in on a new phone with name + PIN (the name list itself stays private)
create or replace function public.oncall_signin(p_code text, p_name text, p_pin text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare k text := public.oncall_key(p_code); st jsonb; ids text[]; res jsonb;
begin
  select state into st from public.oncall_boards where id = k;
  if not found then return jsonb_build_object('ok', false, 'error', 'Team board not found.'); end if;
  select array_agg(s->>'id') into ids from jsonb_array_elements(coalesce(st->'staff', '[]'::jsonb)) s
   where lower(btrim(s->>'name')) = lower(btrim(coalesce(p_name, '')));
  if ids is null or array_length(ids, 1) <> 1 then return jsonb_build_object('ok', false, 'error', 'Name or PIN not right.'); end if;
  res := public.oncall_check_pin(k, ids[1], p_pin);
  if (res->>'ok')::boolean then res := res || jsonb_build_object('staff', ids[1], 'name', public.oncall_staff_of(st, ids[1])->>'name'); end if;
  if res ? 'nopin' then res := jsonb_build_object('ok', false, 'error', 'This name has no PIN yet. Ask a second on-call for an invite code.'); end if;
  return res;
end $$;

-- invites: a second or third on-call makes a one-time code for one person (7 days)
create or replace function public.oncall_invite_create(p_code text, p_token text, p_staff text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare k text := public.oncall_key(p_code); sid text := public.oncall_session(public.oncall_key(p_code), p_token);
  a text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; c text := ''; i int; b bytea := extensions.gen_random_bytes(8); st jsonb;
begin
  if sid is null or coalesce(public.oncall_tier_of(k, sid), '') not in ('second', 'third') then
    return jsonb_build_object('ok', false, 'error', 'Only a second or third on-call signed in with their PIN can send invites.');
  end if;
  select state into st from public.oncall_boards where id = k;
  if public.oncall_staff_of(st, p_staff) is null then return jsonb_build_object('ok', false, 'error', 'That name is not on this board.'); end if;
  for i in 0..7 loop c := c || substr(a, (get_byte(b, i) % 32) + 1, 1); end loop;
  delete from public.oncall_invites where board_id = k and staff_id = p_staff and used_at is null;
  insert into public.oncall_invites (code_hash, board_id, staff_id, created_by, expires_at)
  values (encode(extensions.digest(c, 'sha256'), 'hex'), k, p_staff, public.oncall_staff_of(st, sid)->>'name', now() + interval '7 days');
  return jsonb_build_object('ok', true, 'invite', substr(c, 1, 4) || '-' || substr(c, 5, 4), 'name', public.oncall_staff_of(st, p_staff)->>'name');
end $$;

-- using an invite sets (or replaces) that person's PIN and signs this phone in
create or replace function public.oncall_invite_redeem(p_code text, p_invite text, p_pin text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare k text := public.oncall_key(p_code); inv public.oncall_invites%rowtype; st jsonb;
  c text := upper(regexp_replace(coalesce(p_invite, ''), '[^A-Za-z0-9]', '', 'g'));
begin
  if coalesce(p_pin, '') !~ '^[0-9]{4,6}$' then return jsonb_build_object('ok', false, 'error', 'The PIN must be 4 to 6 digits.'); end if;
  select * into inv from public.oncall_invites
   where code_hash = encode(extensions.digest(c, 'sha256'), 'hex') and board_id = k and used_at is null and expires_at > now() for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'That invite code is not valid or has expired. Ask for a new one.'); end if;
  update public.oncall_invites set used_at = now() where code_hash = inv.code_hash;
  delete from public.oncall_sessions where board_id = k and staff_id = inv.staff_id;
  delete from public.oncall_pins where board_id = k and staff_id = inv.staff_id;
  insert into public.oncall_pins (board_id, staff_id, pin_hash) values (k, inv.staff_id, extensions.crypt(p_pin, extensions.gen_salt('bf')));
  select state into st from public.oncall_boards where id = k;
  return jsonb_build_object('ok', true, 'token', public.oncall_new_session(k, inv.staff_id), 'staff', inv.staff_id, 'name', public.oncall_staff_of(st, inv.staff_id)->>'name');
end $$;

-- resetting someone also cancels their open invites
create or replace function public.oncall_pin_reset(p_code text, p_token text, p_staff text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare k text := public.oncall_key(p_code); sid text := public.oncall_session(public.oncall_key(p_code), p_token);
begin
  if sid is null or coalesce(public.oncall_tier_of(k, sid), '') not in ('second', 'third') then
    return jsonb_build_object('ok', false, 'error', 'Only a second or third on-call signed in with their PIN can reset PINs.');
  end if;
  delete from public.oncall_pins where board_id = k and staff_id = p_staff;
  delete from public.oncall_sessions where board_id = k and staff_id = p_staff;
  delete from public.oncall_invites where board_id = k and staff_id = p_staff;
  return jsonb_build_object('ok', true);
end $$;

-- turning privacy on or off
create or replace function public.oncall_set_private(p_code text, p_token text, p_on boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare k text := public.oncall_key(p_code); sid text := public.oncall_session(public.oncall_key(p_code), p_token);
begin
  if sid is null or coalesce(public.oncall_tier_of(k, sid), '') not in ('second', 'third') then
    return jsonb_build_object('ok', false, 'error', 'Only a second or third on-call signed in with their PIN can change privacy.');
  end if;
  update public.oncall_boards set private = coalesce(p_on, false) where id = k;
  return jsonb_build_object('ok', true, 'private', coalesce(p_on, false));
end $$;

revoke all on function public.oncall_can_read(text, text), public.oncall_check_pin(text, text, text), public.oncall_history_list_all(text) from public, anon, authenticated;
revoke all on function public.oncall_get_board2(text, text), public.oncall_board_version2(text, text), public.oncall_pin_status2(text, text),
  public.oncall_history_list2(text, text), public.oncall_signin(text, text, text), public.oncall_invite_create(text, text, text),
  public.oncall_invite_redeem(text, text, text), public.oncall_set_private(text, text, boolean) from public;
grant execute on function public.oncall_get_board2(text, text), public.oncall_board_version2(text, text), public.oncall_pin_status2(text, text),
  public.oncall_history_list2(text, text), public.oncall_signin(text, text, text), public.oncall_invite_create(text, text, text),
  public.oncall_invite_redeem(text, text, text), public.oncall_set_private(text, text, boolean) to anon, authenticated;
grant execute on function public.oncall_get_board(text), public.oncall_board_version(text), public.oncall_pin_status(text),
  public.oncall_history_list(text), public.oncall_pin_set(text, text, text), public.oncall_pin_login(text, text, text),
  public.oncall_pin_reset(text, text, text) to anon, authenticated;
