-- Applied to the "kora" Supabase project as migration "oncall_board_shared_state".
-- One row per team board, reachable only through these functions with the team code.
create table public.oncall_boards (
  id text primary key, state jsonb not null, version bigint not null default 1,
  updated_at timestamptz not null default now(), updated_by text, created_at timestamptz not null default now()
);
alter table public.oncall_boards enable row level security;
revoke all on public.oncall_boards from anon, authenticated;
-- Functions: oncall_key(code) (sha256 of the code; the code itself is never stored),
-- oncall_create_board(code, state, by), oncall_get_board(code), oncall_board_version(code),
-- oncall_save_board(code, state, base_version, by) -- saves only if base_version is current,
-- otherwise returns the newer board so the app can merge. See the migration in Supabase for the bodies.
