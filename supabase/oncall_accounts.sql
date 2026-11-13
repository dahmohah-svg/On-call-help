-- On-Call Board: email accounts with admin approval.
-- Run once in Supabase → project "kora" → SQL Editor. Adds/updates oncall_ objects only; nothing else is touched.
--
-- How it works
-- * Doctors request access with name, grade, email and password. The request waits until an admin approves it
--   and links it to the doctor's name on the rota.
-- * The first admin is created by a second or third on-call who is already signed in with their PIN.
--   From that moment the board is in "accounts mode": it is private, only approved accounts can read it,
--   and PIN sign-in stops working.
-- * Only admins may change the rota, teams, staff, settings, the OT distribution, room cases, prepared details and
--   the NORA list. The server refuses a save from anyone else that changes those parts. Others can still tick
--   statuses (case running / done, NORA going / done, on-call tasks).
-- * Passwords are stored as bcrypt hashes. Emails never go into the board itself.

alter table public.oncall_boards add column if not exists accounts_mode boolean not null default false;

create table if not exists public.oncall_accounts (
  id bigserial primary key,
  board_id text not null references public.oncall_boards(id) on delete cascade,
  email text not null, name text not null, grade text not null,
  pw_hash text not null,
  status text not null default 'pending' check (status in ('pending', 'approved', 'disabled')),
  staff_id text, is_admin boolean not null default false,
  failed int not null default 0, locked_until timestamptz,
  created_at timestamptz not null default now(), approved_by text, approved_at timestamptz,
  unique (board_id, email)
);
alter table public.oncall_accounts enable row level security;
revoke all on public.oncall_accounts from anon, authenticated;
alter table public.oncall_sessions add column if not exists account_id bigint references public.oncall_accounts(id) on delete cascade;

-- a session counts only if, on a board in accounts mode, it belongs to an approved account
create or replace function public.oncall_session(p_board text, p_token text) returns text
language plpgsql security definer set search_path = '' as $$
declare sid text;
begin
  if p_token is null or length(p_token) < 20 then return null; end if;
  update public.oncall_sessions s set last_used = now()
   where s.token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex') and s.board_id = p_board and s.created_at > now() - interval '180 days'
     and (not coalesce((select b.accounts_mode from public.oncall_boards b where b.id = p_board), false)
          or exists (select 1 from public.oncall_accounts a where a.id = s.account_id and a.status = 'approved'))
   returning s.staff_id into sid;
  return sid;
end $$;

create or replace function public.oncall_account_of(p_board text, p_token text) returns public.oncall_accounts
language sql security definer set search_path = '' as $$
  select a.* from public.oncall_sessions s join public.oncall_accounts a on a.id = s.account_id
   where s.token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex') and s.board_id = p_board
     and s.created_at > now() - interval '180 days' and a.status = 'approved'
$$;
create or replace function public.oncall_account_json(a public.oncall_accounts) returns jsonb
language sql immutable set search_path = '' as $$
  select jsonb_build_object('id', a.id, 'name', a.name, 'grade', a.grade, 'admin', a.is_admin, 'staff', a.staff_id, 'email', a.email)
$$;
create or replace function public.oncall_account_session(a public.oncall_accounts) returns text
language plpgsql security definer set search_path = '' as $$
declare tok text := encode(extensions.gen_random_bytes(24), 'hex');
begin
  insert into public.oncall_sessions (token_hash, board_id, staff_id, account_id)
  values (encode(extensions.digest(tok, 'sha256'), 'hex'), a.board_id, coalesce(a.staff_id, 'acct:' || a.id), a.id);
  return tok;
end $$;

-- request access. The first request, made from a phone where a second / third on-call is signed in with a PIN,
-- becomes the first admin and switches the board to accounts mode.
create or replace function public.oncall_request_access(p_code text, p_token text, p_name text, p_grade text, p_email text, p_password text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare k text := public.oncall_key(p_code); b public.oncall_boards%rowtype; e text := lower(btrim(coalesce(p_email, ''))); n text := btrim(coalesce(p_name, ''));
  sid text; tier text; a public.oncall_accounts%rowtype;
begin
  select * into b from public.oncall_boards where id = k for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'Team board not found.'); end if;
  if e !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or length(e) > 120 then return jsonb_build_object('ok', false, 'error', 'Enter a valid email address.'); end if;
  if length(n) < 2 or length(n) > 60 then return jsonb_build_object('ok', false, 'error', 'Enter your name.'); end if;
  if coalesce(p_grade, '') not in ('Consultant', 'Senior specialist', 'Specialist', 'Senior registrar', 'Registrar') then return jsonb_build_object('ok', false, 'error', 'Choose your grade.'); end if;
  if length(coalesce(p_password, '')) < 8 then return jsonb_build_object('ok', false, 'error', 'Use a password of at least 8 characters.'); end if;
  if exists (select 1 from public.oncall_accounts where board_id = k and email = e) then
    return jsonb_build_object('ok', false, 'error', 'This email has already asked for access. Sign in, or ask an admin.');
  end if;
  if (select count(*) from public.oncall_accounts where board_id = k and status = 'pending') >= 300 then
    return jsonb_build_object('ok', false, 'error', 'Too many requests are waiting. Ask an admin to review them first.');
  end if;
  if not b.accounts_mode then
    sid := public.oncall_session(k, p_token); tier := public.oncall_staff_of(b.state, sid)->>'tier';
    if sid is null or coalesce(tier, '') not in ('second', 'third') then
      return jsonb_build_object('ok', false, 'error', 'Accounts are not set up yet. The first admin must be a second or third on-call signed in with their PIN.');
    end if;
    insert into public.oncall_accounts (board_id, email, name, grade, pw_hash, status, staff_id, is_admin, approved_by, approved_at)
    values (k, e, n, p_grade, extensions.crypt(p_password, extensions.gen_salt('bf')), 'approved', sid, true, 'first admin', now()) returning * into a;
    update public.oncall_boards set accounts_mode = true, private = true where id = k;
    delete from public.oncall_sessions where board_id = k and account_id is null;   -- PIN sessions end
    return jsonb_build_object('ok', true, 'token', public.oncall_account_session(a), 'account', public.oncall_account_json(a), 'first', true);
  end if;
  insert into public.oncall_accounts (board_id, email, name, grade, pw_hash) values (k, e, n, p_grade, extensions.crypt(p_password, extensions.gen_salt('bf')));
  return jsonb_build_object('ok', true, 'pending', true);
end $$;

create or replace function public.oncall_login(p_code text, p_email text, p_password text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare k text := public.oncall_key(p_code); a public.oncall_accounts%rowtype; f int;
begin
  select * into a from public.oncall_accounts where board_id = k and email = lower(btrim(coalesce(p_email, ''))) for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'Email or password not right.'); end if;
  if a.locked_until is not null and a.locked_until > now() then return jsonb_build_object('ok', false, 'error', 'Too many wrong passwords. Try again later or ask an admin to reset it.'); end if;
  if a.pw_hash <> extensions.crypt(coalesce(p_password, ''), a.pw_hash) then
    f := a.failed + 1;
    update public.oncall_accounts set failed = f, locked_until = case when f >= 10 then now() + interval '24 hours' when f % 5 = 0 then now() + interval '15 minutes' else null end where id = a.id;
    return jsonb_build_object('ok', false, 'error', 'Email or password not right.');
  end if;
  update public.oncall_accounts set failed = 0, locked_until = null where id = a.id;
  if a.status = 'pending' then return jsonb_build_object('ok', false, 'pending', true, 'error', 'Your request is waiting for an admin to approve it.'); end if;
  if a.status = 'disabled' then return jsonb_build_object('ok', false, 'error', 'This account has been switched off. Ask an admin.'); end if;
  return jsonb_build_object('ok', true, 'token', public.oncall_account_session(a), 'account', public.oncall_account_json(a));
end $$;

create or replace function public.oncall_me(p_code text, p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare a public.oncall_accounts%rowtype; k text := public.oncall_key(p_code);
begin
  select * into a from public.oncall_account_of(k, p_token);
  if a.id is null then return jsonb_build_object('ok', false, 'signin', true,
    'accounts', coalesce((select accounts_mode from public.oncall_boards where id = k), false)); end if;
  return jsonb_build_object('ok', true, 'account', public.oncall_account_json(a), 'accounts', true,
    'pending', (select count(*) from public.oncall_accounts where board_id = k and status = 'pending'));
end $$;

create or replace function public.oncall_password_change(p_code text, p_token text, p_old text, p_new text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare a public.oncall_accounts%rowtype;
begin
  select * into a from public.oncall_account_of(public.oncall_key(p_code), p_token);
  if a.id is null then return jsonb_build_object('ok', false, 'error', 'Sign in again.'); end if;
  if a.pw_hash <> extensions.crypt(coalesce(p_old, ''), a.pw_hash) then return jsonb_build_object('ok', false, 'error', 'Current password not right.'); end if;
  if length(coalesce(p_new, '')) < 8 then return jsonb_build_object('ok', false, 'error', 'Use a password of at least 8 characters.'); end if;
  update public.oncall_accounts set pw_hash = extensions.crypt(p_new, extensions.gen_salt('bf')) where id = a.id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.oncall_accounts_list(p_code text, p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare k text := public.oncall_key(p_code); me public.oncall_accounts%rowtype;
begin
  select * into me from public.oncall_account_of(k, p_token);
  if me.id is null or not me.is_admin then return jsonb_build_object('ok', false, 'error', 'Only admins can see accounts.'); end if;
  return jsonb_build_object('ok', true, 'accounts', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'email', email, 'name', name, 'grade', grade, 'status', status,
    'staff', staff_id, 'admin', is_admin, 'at', created_at, 'by', approved_by) order by status = 'approved', created_at desc) from public.oncall_accounts where board_id = k), '[]'::jsonb));
end $$;

-- admin actions: approve (with a rota name), link, admin_on, admin_off, disable, enable, reset (new password), reject (a pending request)
create or replace function public.oncall_account_set(p_code text, p_token text, p_id bigint, p_action text, p_staff text default null, p_password text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare k text := public.oncall_key(p_code); me public.oncall_accounts%rowtype; a public.oncall_accounts%rowtype;
begin
  select * into me from public.oncall_account_of(k, p_token);
  if me.id is null or not me.is_admin then return jsonb_build_object('ok', false, 'error', 'Only admins can do this.'); end if;
  select * into a from public.oncall_accounts where id = p_id and board_id = k for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'Account not found.'); end if;
  if p_action in ('approve', 'link') then
    if p_staff is not null and p_staff <> '' and exists (select 1 from public.oncall_accounts where board_id = k and staff_id = p_staff and id <> a.id and status <> 'disabled') then
      return jsonb_build_object('ok', false, 'error', 'That rota name is already linked to another account.');
    end if;
    update public.oncall_accounts set staff_id = nullif(p_staff, ''),
      status = case when p_action = 'approve' then 'approved' else status end,
      approved_by = case when p_action = 'approve' then me.name else approved_by end,
      approved_at = case when p_action = 'approve' then now() else approved_at end where id = a.id;
    update public.oncall_sessions set staff_id = coalesce(nullif(p_staff, ''), 'acct:' || a.id) where account_id = a.id;
  elsif p_action = 'admin_on' then
    if a.status <> 'approved' then return jsonb_build_object('ok', false, 'error', 'Approve the account first.'); end if;
    update public.oncall_accounts set is_admin = true where id = a.id;
  elsif p_action = 'admin_off' then
    if (select count(*) from public.oncall_accounts where board_id = k and is_admin and status = 'approved' and id <> a.id) = 0 then
      return jsonb_build_object('ok', false, 'error', 'There must always be at least one admin.');
    end if;
    update public.oncall_accounts set is_admin = false where id = a.id;
  elsif p_action = 'disable' then
    if a.id = me.id then return jsonb_build_object('ok', false, 'error', 'You cannot switch off your own account.'); end if;
    update public.oncall_accounts set status = 'disabled', is_admin = false where id = a.id;
    delete from public.oncall_sessions where account_id = a.id;
  elsif p_action = 'enable' then
    update public.oncall_accounts set status = 'approved' where id = a.id;
  elsif p_action = 'reject' then
    if a.status <> 'pending' then return jsonb_build_object('ok', false, 'error', 'Only a waiting request can be rejected.'); end if;
    delete from public.oncall_accounts where id = a.id;
  elsif p_action = 'reset' then
    if length(coalesce(p_password, '')) < 8 then return jsonb_build_object('ok', false, 'error', 'Use a password of at least 8 characters.'); end if;
    update public.oncall_accounts set pw_hash = extensions.crypt(p_password, extensions.gen_salt('bf')), failed = 0, locked_until = null where id = a.id;
    delete from public.oncall_sessions where account_id = a.id;
  else
    return jsonb_build_object('ok', false, 'error', 'Unknown action.');
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- the parts of the board only admins may change: rota, teams, staff, settings, permissions,
-- the OT distribution with each room's case list and prepared details, and the NORA team and case list
-- (dates more than 50 days old are left out, because every phone tidies those away by itself;
--  settings are compared only for the keys already stored, because newer app versions add default keys)
create or replace function public.oncall_admin_frame(p jsonb, p_keys jsonb default null) returns jsonb
language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'staff', coalesce(p->'staff', '[]'), 'teams', coalesce(p->'teams', '[]'), 'perms', coalesce(p->'perms', '{}'),
    'rota', coalesce((select jsonb_object_agg(d.key, d.value) from jsonb_each(case when jsonb_typeof(p->'rota') = 'object' then p->'rota' else '{}' end) d
        where d.key >= to_char(current_date - 50, 'YYYY-MM-DD')), '{}'),
    'settings', coalesce((select jsonb_object_agg(d.key, d.value) from jsonb_each(case when jsonb_typeof(p->'settings') = 'object' then p->'settings' else '{}' end) d
        where p_keys is null or p_keys ? d.key), '{}'),
    'ot', coalesce((select jsonb_object_agg(d.key, (select coalesce(jsonb_agg(jsonb_build_object('id', r->>'id', 'name', r->>'name', 'list', r->>'list', 'anaes', r->>'anaes',
            'cases', (select coalesce(jsonb_agg(jsonb_build_object('id', c->>'id', 'title', c->>'title', 'location', c->>'location', 'notes', c->>'notes', 'details', c->'details') order by c->>'id'), '[]')
                      from jsonb_array_elements(coalesce(r->'cases', '[]')) c)) order by r->>'id'), '[]')
          from jsonb_array_elements(coalesce(d.value->'rooms', '[]')) r))
        from jsonb_each(case when jsonb_typeof(p->'ot') = 'object' then p->'ot' else '{}' end) d
        where jsonb_array_length(coalesce(d.value->'rooms', '[]')) > 0 and d.key >= to_char(current_date - 50, 'YYYY-MM-DD')), '{}'),
    'nora', coalesce((select jsonb_object_agg(d.key, jsonb_build_object('team', coalesce(d.value->>'team', ''),
          'cases', (select coalesce(jsonb_agg(jsonb_build_object('id', c->>'id', 'proc', c->>'proc', 'area', c->>'area', 'time', c->>'time', 'loc', c->>'loc', 'notes', c->>'notes', 'details', c->'details') order by c->>'id'), '[]')
                    from jsonb_array_elements(coalesce(d.value->'cases', '[]')) c)))
        from jsonb_each(case when jsonb_typeof(p->'nora') = 'object' then p->'nora' else '{}' end) d
        where (jsonb_array_length(coalesce(d.value->'cases', '[]')) > 0 or coalesce(d.value->>'team', '') <> '') and d.key >= to_char(current_date - 50, 'YYYY-MM-DD')), '{}'))
$$;

create or replace function public.oncall_save_board2(p_code text, p_token text, p_state jsonb, p_base bigint, p_by text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare k text := public.oncall_key(p_code); r public.oncall_boards%rowtype; sid text; who text; me public.oncall_accounts%rowtype;
begin
  if pg_column_size(p_state) > 1000000 then raise exception 'board too large'; end if;
  select * into r from public.oncall_boards where id = k for update;
  if not found then return jsonb_build_object('ok', false, 'missing', true); end if;
  sid := public.oncall_session(k, p_token);
  if sid is null and (r.accounts_mode or exists (select 1 from public.oncall_pins where board_id = k)) then return jsonb_build_object('ok', false, 'signin', true); end if;
  if r.accounts_mode then
    select * into me from public.oncall_account_of(k, p_token);
    who := me.name;
  else
    who := case when sid is not null then coalesce(public.oncall_staff_of(r.state, sid)->>'name', public.oncall_staff_of(p_state, sid)->>'name')
                else nullif(left(coalesce(p_by, ''), 60), '') || ' (no PIN)' end;
  end if;
  if r.version <> p_base then
    return jsonb_build_object('ok', false, 'version', r.version, 'state', r.state, 'updated_at', r.updated_at, 'updated_by', r.updated_by);
  end if;
  if r.accounts_mode and not coalesce(me.is_admin, false) and public.oncall_admin_frame(p_state, r.state->'settings') is distinct from public.oncall_admin_frame(r.state, r.state->'settings') then
    return jsonb_build_object('ok', false, 'denied', true, 'error', 'Only admins can change the rota, staff, room lists, prepared details and the NORA list.',
      'version', r.version, 'state', r.state, 'updated_at', r.updated_at, 'updated_by', r.updated_by);
  end if;
  perform public.oncall_history_add(r, p_state, who);
  update public.oncall_boards set state = p_state, version = version + 1, updated_at = now(), updated_by = who where id = k returning * into r;
  return jsonb_build_object('ok', true, 'version', r.version, 'updated_at', r.updated_at, 'updated_by', r.updated_by);
end $$;

-- reads report accounts mode and, when signed in, the account
create or replace function public.oncall_get_board2(p_code text, p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare k text := public.oncall_key(p_code); r public.oncall_boards%rowtype; sid text; a public.oncall_accounts%rowtype;
begin
  select * into r from public.oncall_boards where id = k;
  if not found then return jsonb_build_object('ok', false, 'missing', true); end if;
  sid := public.oncall_session(k, p_token);
  if r.private and sid is null then return jsonb_build_object('ok', false, 'signin', true, 'private', true, 'accounts', r.accounts_mode); end if;
  if r.accounts_mode then select * into a from public.oncall_account_of(k, p_token); end if;
  return jsonb_build_object('ok', true, 'state', r.state, 'version', r.version, 'updated_at', r.updated_at, 'updated_by', r.updated_by, 'private', r.private, 'me', sid,
    'accounts', r.accounts_mode, 'account', case when a.id is null then null else public.oncall_account_json(a) end);
end $$;
create or replace function public.oncall_board_version2(p_code text, p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare k text := public.oncall_key(p_code); r public.oncall_boards%rowtype;
begin
  select * into r from public.oncall_boards where id = k;
  if not found then return jsonb_build_object('ok', false, 'missing', true); end if;
  if r.private and public.oncall_session(k, p_token) is null then return jsonb_build_object('ok', false, 'signin', true, 'private', true, 'accounts', r.accounts_mode); end if;
  return jsonb_build_object('ok', true, 'version', r.version, 'private', r.private, 'accounts', r.accounts_mode);
end $$;

-- in accounts mode: no PIN sign-in, the board stays private, and only admins restore history
create or replace function public.oncall_check_pin(p_board text, p_staff text, p_pin text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare p public.oncall_pins%rowtype; f int;
begin
  if coalesce((select accounts_mode from public.oncall_boards where id = p_board), false) then
    return jsonb_build_object('ok', false, 'error', 'This board now uses email sign-in. Sign in with your email and password.');
  end if;
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
create or replace function public.oncall_set_private(p_code text, p_token text, p_on boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare k text := public.oncall_key(p_code); sid text := public.oncall_session(public.oncall_key(p_code), p_token);
begin
  if coalesce((select accounts_mode from public.oncall_boards where id = k), false) then
    return jsonb_build_object('ok', false, 'error', 'With email sign-in the board always stays private.');
  end if;
  if sid is null or coalesce(public.oncall_tier_of(k, sid), '') not in ('second', 'third') then
    return jsonb_build_object('ok', false, 'error', 'Only a second or third on-call signed in with their PIN can change privacy.');
  end if;
  update public.oncall_boards set private = coalesce(p_on, false) where id = k;
  return jsonb_build_object('ok', true, 'private', coalesce(p_on, false));
end $$;
create or replace function public.oncall_history_restore(p_code text, p_token text, p_id bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare k text := public.oncall_key(p_code); sid text; who text; r public.oncall_boards%rowtype; h public.oncall_board_history%rowtype; me public.oncall_accounts%rowtype;
begin
  select * into r from public.oncall_boards where id = k for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'Team board not found.'); end if;
  sid := public.oncall_session(k, p_token);
  if r.accounts_mode then
    select * into me from public.oncall_account_of(k, p_token);
    if me.id is null or not me.is_admin then return jsonb_build_object('ok', false, 'error', 'Only admins can restore.'); end if;
  elsif (sid is null and exists (select 1 from public.oncall_pins where board_id = k))
     or (sid is not null and coalesce(public.oncall_staff_of(r.state, sid)->>'tier', '') not in ('second', 'third')) then
    return jsonb_build_object('ok', false, 'error', 'Only a second or third on-call signed in with their PIN can restore.');
  end if;
  select * into h from public.oncall_board_history where id = p_id and board_id = k;
  if not found then return jsonb_build_object('ok', false, 'error', 'That version is no longer kept.'); end if;
  who := coalesce(me.name, public.oncall_staff_of(r.state, sid)->>'name', 'Someone');
  perform public.oncall_history_add(r, h.state, who, true);
  update public.oncall_boards set state = h.state, version = version + 1, updated_at = now(),
         updated_by = who || ' (restored ' || to_char(h.created_at at time zone 'Asia/Kuwait', 'Dy HH24:MI') || ')'
   where id = k returning * into r;
  return jsonb_build_object('ok', true, 'version', r.version);
end $$;

revoke all on function public.oncall_account_of(text, text), public.oncall_account_json(public.oncall_accounts), public.oncall_account_session(public.oncall_accounts),
  public.oncall_admin_frame(jsonb, jsonb), public.oncall_session(text, text), public.oncall_check_pin(text, text, text) from public, anon, authenticated;
revoke all on function public.oncall_request_access(text, text, text, text, text, text), public.oncall_login(text, text, text), public.oncall_me(text, text),
  public.oncall_password_change(text, text, text, text), public.oncall_accounts_list(text, text), public.oncall_account_set(text, text, bigint, text, text, text),
  public.oncall_save_board2(text, text, jsonb, bigint, text), public.oncall_get_board2(text, text), public.oncall_board_version2(text, text),
  public.oncall_set_private(text, text, boolean), public.oncall_history_restore(text, text, bigint) from public;
grant execute on function public.oncall_request_access(text, text, text, text, text, text), public.oncall_login(text, text, text), public.oncall_me(text, text),
  public.oncall_password_change(text, text, text, text), public.oncall_accounts_list(text, text), public.oncall_account_set(text, text, bigint, text, text, text),
  public.oncall_save_board2(text, text, jsonb, bigint, text), public.oncall_get_board2(text, text), public.oncall_board_version2(text, text),
  public.oncall_set_private(text, text, boolean), public.oncall_history_restore(text, text, bigint) to anon, authenticated;
