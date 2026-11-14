-- =====================================================================
--  Zadanko English – baza danych (Supabase / PostgreSQL)
--  Wklej CAŁOŚĆ w Supabase → SQL Editor → New query → Run.
--  Można uruchomić ponownie (np. po aktualizacji) – dane zostają.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------- TABELE ----------------------------------------------------

create table if not exists public.teachers (
  user_id    uuid primary key,
  created_at timestamptz not null default now()
);

create table if not exists public.students (
  id            uuid primary key default gen_random_uuid(),
  login         text not null unique,
  full_name     text not null,
  class_name    text not null default '',
  pin_hash      text not null,
  failed_logins int  not null default 0,
  locked_until  timestamptz,
  created_at    timestamptz not null default now()
);

-- PIN w wersji czytelnej – widzi go tylko nauczyciel (logowanie dalej sprawdza wersję zahaszowaną)
alter table public.students add column if not exists pin text;

create table if not exists public.student_sessions (
  token      uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.students(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '60 days'
);

-- items: [{type:'vocab'|'gap'|'choice', prompt, answers:[..], options?:[..], explain?}]
create table if not exists public.quizzes (
  id           uuid primary key default gen_random_uuid(),
  title        text not null,
  class_name   text not null default '',          -- '' = wszystkie klasy
  items        jsonb not null,
  extra_count  int  not null default 5,            -- ile osobistych powtórek dodać
  is_open      boolean not null default true,
  allow_retake boolean not null default false,
  created_at   timestamptz not null default now()
);

create table if not exists public.attempts (
  id          uuid primary key default gen_random_uuid(),
  quiz_id     uuid not null references public.quizzes(id) on delete cascade,
  student_id  uuid not null references public.students(id) on delete cascade,
  items       jsonb not null,      -- kopia zadań tej konkretnej kartkówki (z powtórkami)
  answers     jsonb,
  results     jsonb,
  base_score  int, base_total  int,
  extra_score int, extra_total int,
  started_at  timestamptz not null default now(),
  finished_at timestamptz
);
create index if not exists attempts_student_idx on public.attempts(student_id);
create index if not exists attempts_quiz_idx    on public.attempts(quiz_id);

-- Statystyka każdego słówka / zadania dla każdego ucznia.
-- to_repeat: każdy błąd +1, każda późniejsza poprawna odpowiedź −1.
-- Słówko wraca w powtórkach, dopóki to_repeat > 0.
create table if not exists public.word_stats (
  student_id    uuid not null references public.students(id) on delete cascade,
  key           text not null,
  item          jsonb not null,
  errors        int not null default 0,
  corrects      int not null default 0,
  to_repeat     int not null default 0,
  last_wrong_at timestamptz,
  last_seen_at  timestamptz,
  primary key (student_id, key)
);

-- 2-minutowe ćwiczenie z błędnych słówek, generowane przez AI po kartkówce (jedno na kartkówkę).
create table if not exists public.practices (
  id          uuid primary key default gen_random_uuid(),
  attempt_id  uuid not null unique references public.attempts(id) on delete cascade,
  student_id  uuid not null references public.students(id) on delete cascade,
  words       jsonb not null,      -- słówka, z których jest ćwiczenie
  items       jsonb,               -- zadania od AI (z odpowiedziami); null = jeszcze nie wygenerowane
  answers     jsonb,
  results     jsonb,
  score       int, total int,
  created_at  timestamptz not null default now(),
  finished_at timestamptz
);

-- DAILY SENTENCES: tydzień słówek, w każdym dniu 5–6 wyrażeń; uczeń pisze po jednym zdaniu, AI sprawdza.
-- days: [{day:'Monday', items:[{phrase, type, definition, polish, model, status:'new'|'revisit'}]}]
create table if not exists public.sentence_weeks (
  id          uuid primary key default gen_random_uuid(),
  week_start  date not null,
  title       text not null default '',
  class_name  text not null default '',      -- '' = wszyscy uczniowie
  days        jsonb not null,
  is_open     boolean not null default true,
  created_at  timestamptz not null default now()
);
create table if not exists public.sentence_attempts (
  id          uuid primary key default gen_random_uuid(),
  week_id     uuid not null references public.sentence_weeks(id) on delete cascade,
  student_id  uuid not null references public.students(id) on delete cascade,
  day_index   int not null, item_index int not null,
  phrase      text not null,
  attempt_no  int not null,                   -- 1 = pierwsza próba, 2–3 = poprawki
  sentence    text not null,
  verdict     text not null,                  -- correct | almost | needs work
  corrected   text not null default '',
  feedback    text not null default '',
  error_types jsonb not null default '[]',
  tip         text not null default '',
  created_at  timestamptz not null default now()
);
create index if not exists sentence_attempts_ws_idx on public.sentence_attempts(week_id, student_id);
create table if not exists public.sentence_progress (
  week_id         uuid not null references public.sentence_weeks(id) on delete cascade,
  student_id      uuid not null references public.students(id) on delete cascade,
  day_index       int not null, item_index int not null,
  attempts        int not null default 0,
  done            boolean not null default false,
  final_verdict   text,
  model_viewed    boolean not null default false,
  model_viewed_at timestamptz,
  updated_at      timestamptz not null default now(),
  primary key (week_id, student_id, day_index, item_index)
);
alter table public.sentence_weeks    enable row level security;
alter table public.sentence_attempts enable row level security;
alter table public.sentence_progress enable row level security;
revoke all on public.sentence_weeks, public.sentence_attempts, public.sentence_progress from anon, authenticated;

-- Nikt nie czyta tabel bezpośrednio – wszystko idzie przez funkcje poniżej.
alter table public.practices enable row level security;
revoke all on public.practices from anon, authenticated;
alter table public.teachers         enable row level security;
alter table public.students         enable row level security;
alter table public.student_sessions enable row level security;
alter table public.quizzes          enable row level security;
alter table public.attempts         enable row level security;
alter table public.word_stats       enable row level security;
revoke all on public.teachers, public.students, public.student_sessions,
              public.quizzes, public.attempts, public.word_stats
  from anon, authenticated;

-- ---------- FUNKCJE POMOCNICZE (niedostępne z zewnątrz) ---------------

create or replace function public._norm(t text, typ text default '')
returns text language plpgsql immutable as $$
declare s text := lower(coalesce(t, ''));
begin
  s := translate(s, '’‘`´', '''''''''');
  s := replace(s, 'won''t', 'will not');
  s := replace(s, 'can''t', 'can not');
  s := replace(s, 'cannot', 'can not');
  s := replace(s, 'shan''t', 'shall not');
  s := replace(s, 'n''t', ' not');
  s := replace(s, '''re', ' are');
  s := replace(s, '''m', ' am');
  s := replace(s, '''ve', ' have');
  s := replace(s, '''ll', ' will');
  s := regexp_replace(s, '[.,!?;:"()]', ' ', 'g');
  s := btrim(regexp_replace(s, '\s+', ' ', 'g'));
  if typ = 'vocab' then
    s := regexp_replace(s, '^(to|a|an|the) ', '');
  end if;
  return s;
end $$;

create or replace function public._item_key(it jsonb)
returns text language sql immutable as $$
  select left(public._norm(it->>'prompt') || ' → ' || public._norm(it->'answers'->>0), 300)
$$;

create or replace function public._check(it jsonb, given text)
returns boolean language sql immutable as $$
  select public._norm(given, it->>'type') <> ''
     and exists (select 1 from jsonb_array_elements_text(it->'answers') a
                 where public._norm(a, it->>'type') = public._norm(given, it->>'type'))
$$;

create or replace function public._sid(p_token uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare sid uuid;
begin
  select student_id into sid from student_sessions
   where token = p_token and expires_at > now();
  if sid is null then raise exception 'session_expired'; end if;
  return sid;
end $$;

create or replace function public._need_teacher()
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not exists (select 1 from teachers where user_id = auth.uid()) then
    raise exception 'not_teacher';
  end if;
end $$;

create or replace function public._attempt_json(p_id uuid)
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'attempt_id', a.id, 'quiz_id', a.quiz_id, 'title', q.title,
    'student', s.full_name, 'class_name', s.class_name,
    'started_at', a.started_at, 'finished_at', a.finished_at,
    'base_score', a.base_score, 'base_total', a.base_total,
    'extra_score', a.extra_score, 'extra_total', a.extra_total,
    'practice', (select json_build_object('id', p.id, 'score', p.score, 'total', p.total,
                                          'finished', p.finished_at is not null)
                 from practices p where p.attempt_id = a.id),
    'items', (select json_agg(json_build_object(
                'type', it->>'type', 'prompt', it->>'prompt', 'options', it->'options',
                'answers', it->'answers', 'explain', it->>'explain',
                'extra', coalesce((it->>'extra')::boolean, false),
                'given', a.results->(o::int - 1)->>'given',
                'ok', (a.results->(o::int - 1)->>'ok')::boolean,
                'to_repeat', (a.results->(o::int - 1)->>'to_repeat')::int) order by o)
              from jsonb_array_elements(a.items) with ordinality e(it, o)))
  from attempts a join quizzes q on q.id = a.quiz_id join students s on s.id = a.student_id
  where a.id = p_id
$$;

create or replace function public._make_login(p_name text)
returns text language plpgsql security definer set search_path = public as $$
declare base text; cand text; n int := 1;
begin
  base := translate(lower(btrim(p_name)), 'ąćęłńóśźżäöüé', 'acelnoszzaoue');
  base := btrim(regexp_replace(base, '[^a-z0-9]+', '.', 'g'), '.');
  if base = '' then base := 'uczen'; end if;
  cand := base;
  while exists (select 1 from students where login = cand) loop
    n := n + 1; cand := base || n;
  end loop;
  return cand;
end $$;

create or replace function public._new_pin()
returns text language sql volatile as $$
  select lpad((floor(random() * 10000))::int::text, 4, '0')
$$;

-- ---------- UCZEŃ -----------------------------------------------------

create or replace function public.student_login(p_login text, p_pin text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare st students; tok uuid;
begin
  select * into st from students where login = lower(btrim(p_login));
  if not found then return json_build_object('error', 'bad_login'); end if;
  if st.locked_until is not null and st.locked_until > now() then
    return json_build_object('error', 'locked',
      'minutes', ceil(extract(epoch from st.locked_until - now()) / 60));
  end if;
  if st.pin_hash <> crypt(btrim(coalesce(p_pin, '')), st.pin_hash) then
    update students set
      locked_until  = case when failed_logins + 1 >= 8 then now() + interval '15 minutes' else null end,
      failed_logins = case when failed_logins + 1 >= 8 then 0 else failed_logins + 1 end
    where id = st.id;
    return json_build_object('error', 'bad_login');
  end if;
  update students set failed_logins = 0, locked_until = null where id = st.id;
  delete from student_sessions where expires_at < now();
  insert into student_sessions(student_id) values (st.id) returning token into tok;
  return json_build_object('token', tok, 'name', st.full_name, 'class_name', st.class_name);
end $$;

create or replace function public.student_logout(p_token uuid)
returns void language sql security definer set search_path = public as $$
  delete from student_sessions where token = p_token
$$;

create or replace function public.student_home(p_token uuid)
returns json language plpgsql security definer set search_path = public as $$
declare sid uuid := public._sid(p_token); st students;
begin
  select * into st from students where id = sid;
  return json_build_object(
    'student', json_build_object('name', st.full_name, 'class_name', st.class_name, 'login', st.login),
    'quizzes', coalesce((
      select json_agg(x order by x.created_at desc) from (
        select q.id, q.title, q.created_at, q.extra_count, q.allow_retake,
               jsonb_array_length(q.items) as item_count,
               (select a.id from attempts a where a.quiz_id = q.id and a.student_id = sid and a.finished_at is null limit 1) as open_attempt,
               (select json_build_object('attempt_id', a.id, 'base_score', a.base_score, 'base_total', a.base_total,
                                         'extra_score', a.extra_score, 'extra_total', a.extra_total, 'finished_at', a.finished_at)
                  from attempts a where a.quiz_id = q.id and a.student_id = sid and a.finished_at is not null
                  order by a.finished_at desc limit 1) as last
        from quizzes q
        where q.is_open and (q.class_name = '' or q.class_name = st.class_name)) x), '[]'),
    'review', coalesce((
      select json_agg(json_build_object('type', w.item->>'type', 'prompt', w.item->>'prompt',
                                        'answer', w.item->'answers'->>0, 'to_repeat', w.to_repeat, 'errors', w.errors)
                      order by w.to_repeat desc, w.last_wrong_at desc)
      from word_stats w where w.student_id = sid and w.to_repeat > 0), '[]'),
    'mastered', (select count(*) from word_stats w where w.student_id = sid and w.errors > 0 and w.to_repeat = 0),
    'history', coalesce((
      select json_agg(json_build_object('attempt_id', a.id, 'title', q.title, 'finished_at', a.finished_at,
                                        'base_score', a.base_score, 'base_total', a.base_total,
                                        'extra_score', a.extra_score, 'extra_total', a.extra_total)
                      order by a.finished_at desc)
      from attempts a join quizzes q on q.id = a.quiz_id
      where a.student_id = sid and a.finished_at is not null), '[]'));
end $$;

create or replace function public.start_attempt(p_token uuid, p_quiz_id uuid)
returns json language plpgsql security definer set search_path = public as $$
declare sid uuid := public._sid(p_token); st students; q quizzes; a attempts; base jsonb; extras jsonb;
begin
  select * into st from students where id = sid;
  select * into q from quizzes
   where id = p_quiz_id and is_open and (class_name = '' or class_name = st.class_name);
  if not found then raise exception 'quiz_unavailable'; end if;

  select * into a from attempts
   where quiz_id = q.id and student_id = sid and finished_at is null
   order by started_at desc limit 1;

  if not found then
    if not q.allow_retake and exists (select 1 from attempts
         where quiz_id = q.id and student_id = sid and finished_at is not null) then
      raise exception 'already_done';
    end if;
    select coalesce(jsonb_agg((it - 'key' - 'extra') || jsonb_build_object('key', public._item_key(it), 'extra', false) order by o), '[]')
      into base from jsonb_array_elements(q.items) with ordinality e(it, o);
    select coalesce(jsonb_agg(w.item || jsonb_build_object('key', w.key, 'extra', true) order by w.to_repeat desc, w.last_wrong_at desc), '[]')
      into extras
      from (select * from word_stats
             where student_id = sid and to_repeat > 0
               and key not in (select b->>'key' from jsonb_array_elements(base) b)
             order by to_repeat desc, last_wrong_at desc nulls last, random()
             limit greatest(q.extra_count, 0)) w;
    insert into attempts(quiz_id, student_id, items) values (q.id, sid, base || extras)
      returning * into a;
  end if;

  return json_build_object(
    'attempt_id', a.id, 'title', q.title,
    'items', (select json_agg(json_build_object(
                'type', it->>'type', 'prompt', it->>'prompt', 'options', it->'options',
                'extra', (it->>'extra')::boolean,
                'to_repeat', (select w.to_repeat from word_stats w where w.student_id = sid and w.key = it->>'key'))
              order by o)
              from jsonb_array_elements(a.items) with ordinality e(it, o)));
end $$;

create or replace function public.submit_attempt(p_token uuid, p_attempt_id uuid, p_answers jsonb)
returns json language plpgsql security definer set search_path = public as $$
declare sid uuid := public._sid(p_token); a attempts; r record; given text; good boolean; rep int;
        res jsonb := '[]'; bs int := 0; bt int := 0; es int := 0; et int := 0;
begin
  select * into a from attempts where id = p_attempt_id and student_id = sid for update;
  if not found then raise exception 'attempt_not_found'; end if;
  if a.finished_at is not null then return public._attempt_json(a.id); end if;

  for r in select it, (o - 1)::int as i from jsonb_array_elements(a.items) with ordinality e(it, o) loop
    given := left(coalesce(p_answers->>r.i, ''), 300);
    good  := public._check(r.it, given);
    if coalesce((r.it->>'extra')::boolean, false) then
      et := et + 1; if good then es := es + 1; end if;
    else
      bt := bt + 1; if good then bs := bs + 1; end if;
    end if;

    insert into word_stats as w (student_id, key, item, errors, corrects, to_repeat, last_wrong_at, last_seen_at)
    values (sid, r.it->>'key', r.it - 'key' - 'extra',
            case when good then 0 else 1 end, case when good then 1 else 0 end,
            case when good then 0 else 1 end, case when good then null else now() end, now())
    on conflict (student_id, key) do update set
      errors        = w.errors   + excluded.errors,
      corrects      = w.corrects + excluded.corrects,
      to_repeat     = greatest(0, w.to_repeat + case when excluded.errors > 0 then 1 else -1 end),
      last_wrong_at = coalesce(excluded.last_wrong_at, w.last_wrong_at),
      last_seen_at  = now(),
      item          = excluded.item
    returning w.to_repeat into rep;

    res := res || jsonb_build_array(jsonb_build_object('given', given, 'ok', good, 'to_repeat', rep));
  end loop;

  update attempts set answers = p_answers, results = res,
         base_score = bs, base_total = bt, extra_score = es, extra_total = et, finished_at = now()
   where id = a.id;
  return public._attempt_json(a.id);
end $$;

create or replace function public.student_attempt(p_token uuid, p_attempt_id uuid)
returns json language plpgsql security definer set search_path = public as $$
declare sid uuid := public._sid(p_token);
begin
  if not exists (select 1 from attempts where id = p_attempt_id and student_id = sid and finished_at is not null) then
    raise exception 'attempt_not_found';
  end if;
  return public._attempt_json(p_attempt_id);
end $$;

-- ---------- NAUCZYCIEL ------------------------------------------------

-- Pierwsze konto, które się zaloguje, zostaje nauczycielem. Kolejne – już nie.
create or replace function public.claim_teacher()
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return false; end if;
  if exists (select 1 from teachers where user_id = auth.uid()) then return true; end if;
  if exists (select 1 from teachers) then return false; end if;
  insert into teachers(user_id) values (auth.uid());
  return true;
end $$;

create or replace function public.t_students()
returns json language plpgsql security definer set search_path = public as $$
begin
  perform public._need_teacher();
  return coalesce((select json_agg(x order by x.class_name, x.full_name) from (
    select s.id, s.login, s.full_name, s.class_name, s.created_at, s.pin,
      (select count(*) from attempts a where a.student_id = s.id and a.finished_at is not null) as done,
      (select round(avg(100.0 * a.base_score / nullif(a.base_total, 0)))
         from attempts a where a.student_id = s.id and a.finished_at is not null) as avg_pct,
      (select count(*) from word_stats w where w.student_id = s.id and w.to_repeat > 0) as to_repeat,
      (s.locked_until is not null and s.locked_until > now()) as locked
    from students s) x), '[]');
end $$;

-- p_rows: [{full_name, class_name}] → zwraca [{id, full_name, class_name, login, pin}] (PIN widać tylko raz)
create or replace function public.t_create_students(p_rows jsonb)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare r jsonb; lg text; new_pin text; out jsonb := '[]'; nid uuid;
begin
  perform public._need_teacher();
  for r in select * from jsonb_array_elements(p_rows) loop
    continue when btrim(coalesce(r->>'full_name', '')) = '';
    lg  := public._make_login(r->>'full_name');
    new_pin := public._new_pin();
    insert into students(login, full_name, class_name, pin_hash, pin)
    values (lg, btrim(r->>'full_name'), btrim(coalesce(r->>'class_name', '')), crypt(new_pin, gen_salt('bf', 8)), new_pin)
    returning id into nid;
    out := out || jsonb_build_array(jsonb_build_object('id', nid, 'full_name', btrim(r->>'full_name'),
             'class_name', btrim(coalesce(r->>'class_name', '')), 'login', lg, 'pin', new_pin));
  end loop;
  return out;
end $$;

create or replace function public.t_reset_pin(p_student_id uuid)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare new_pin text := public._new_pin(); st students;
begin
  perform public._need_teacher();
  update students set pin_hash = crypt(new_pin, gen_salt('bf', 8)), pin = new_pin, failed_logins = 0, locked_until = null
   where id = p_student_id returning * into st;
  if not found then raise exception 'not_found'; end if;
  delete from student_sessions where student_id = p_student_id;
  return json_build_object('login', st.login, 'full_name', st.full_name, 'class_name', st.class_name, 'pin', new_pin);
end $$;

create or replace function public.t_update_student(p_student_id uuid, p_full_name text, p_class_name text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public._need_teacher();
  update students set full_name = btrim(p_full_name), class_name = btrim(coalesce(p_class_name, ''))
   where id = p_student_id;
end $$;

create or replace function public.t_delete_student(p_student_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public._need_teacher();
  delete from students where id = p_student_id;
end $$;

create or replace function public.t_student_detail(p_student_id uuid)
returns json language plpgsql security definer set search_path = public as $$
begin
  perform public._need_teacher();
  return json_build_object(
    'review', coalesce((select json_agg(json_build_object('prompt', w.item->>'prompt', 'answer', w.item->'answers'->>0,
                         'errors', w.errors, 'corrects', w.corrects, 'to_repeat', w.to_repeat) order by w.to_repeat desc, w.errors desc)
                        from word_stats w where w.student_id = p_student_id and w.errors > 0), '[]'));
end $$;

create or replace function public.t_quizzes()
returns json language plpgsql security definer set search_path = public as $$
begin
  perform public._need_teacher();
  return coalesce((select json_agg(x order by x.created_at desc) from (
    select q.*, jsonb_array_length(q.items) as item_count,
      (select count(distinct a.student_id) from attempts a where a.quiz_id = q.id and a.finished_at is not null) as done,
      (select round(avg(100.0 * a.base_score / nullif(a.base_total, 0)))
         from attempts a where a.quiz_id = q.id and a.finished_at is not null) as avg_pct
    from quizzes q) x), '[]');
end $$;

create or replace function public.t_save_quiz(p_id uuid, p_title text, p_class_name text, p_items jsonb,
                                              p_extra_count int, p_is_open boolean, p_allow_retake boolean)
returns uuid language plpgsql security definer set search_path = public as $$
declare nid uuid;
begin
  perform public._need_teacher();
  if btrim(coalesce(p_title, '')) = '' then raise exception 'no_title'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'no_items'; end if;
  if exists (select 1 from jsonb_array_elements(p_items) it
             where coalesce(it->>'type', '') not in ('vocab', 'gap', 'choice')
                or btrim(coalesce(it->>'prompt', '')) = ''
                or jsonb_typeof(it->'answers') <> 'array' or jsonb_array_length(it->'answers') = 0) then
    raise exception 'bad_items';
  end if;
  if p_id is null then
    insert into quizzes(title, class_name, items, extra_count, is_open, allow_retake)
    values (btrim(p_title), btrim(coalesce(p_class_name, '')), p_items, least(greatest(coalesce(p_extra_count, 5), 0), 20),
            coalesce(p_is_open, true), coalesce(p_allow_retake, false))
    returning id into nid;
  else
    update quizzes set title = btrim(p_title), class_name = btrim(coalesce(p_class_name, '')), items = p_items,
           extra_count = least(greatest(coalesce(p_extra_count, 5), 0), 20),
           is_open = coalesce(p_is_open, true), allow_retake = coalesce(p_allow_retake, false)
     where id = p_id returning id into nid;
  end if;
  return nid;
end $$;

create or replace function public.t_set_quiz_open(p_id uuid, p_is_open boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public._need_teacher();
  update quizzes set is_open = p_is_open where id = p_id;
end $$;

create or replace function public.t_delete_quiz(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public._need_teacher();
  delete from quizzes where id = p_id;
end $$;

create or replace function public.t_results()
returns json language plpgsql security definer set search_path = public as $$
begin
  perform public._need_teacher();
  return coalesce((select json_agg(x order by x.finished_at desc) from (
    select a.id as attempt_id, a.quiz_id, q.title, a.student_id, s.full_name, s.class_name, a.finished_at,
           a.base_score, a.base_total, a.extra_score, a.extra_total,
           p.score as practice_score, p.total as practice_total
    from attempts a join quizzes q on q.id = a.quiz_id join students s on s.id = a.student_id
    left join practices p on p.attempt_id = a.id and p.finished_at is not null
    where a.finished_at is not null
    order by a.finished_at desc limit 2000) x), '[]');
end $$;

create or replace function public.t_attempt(p_attempt_id uuid)
returns json language plpgsql security definer set search_path = public as $$
begin
  perform public._need_teacher();
  return public._attempt_json(p_attempt_id);
end $$;

create or replace function public.t_delete_attempt(p_attempt_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public._need_teacher();
  delete from attempts where id = p_attempt_id;
end $$;

create or replace function public.t_hard_words(p_class_name text default '')
returns json language plpgsql security definer set search_path = public as $$
begin
  perform public._need_teacher();
  return coalesce((select json_agg(x order by x.errors desc, x.err_students desc) from (
    select w.key,
           (array_agg(w.item->>'type'))[1]          as type,
           (array_agg(w.item->>'prompt'))[1]        as prompt,
           (array_agg(w.item->'answers'->>0))[1]    as answer,
           sum(w.errors)::int                        as errors,
           sum(w.corrects)::int                      as corrects,
           count(*) filter (where w.errors > 0)::int as err_students,
           count(*)::int                             as seen_students,
           count(*) filter (where w.to_repeat > 0)::int as repeat_students,
           json_agg(json_build_object('name', s.full_name, 'class_name', s.class_name,
                                      'errors', w.errors, 'to_repeat', w.to_repeat)
                    order by w.errors desc) filter (where w.errors > 0) as students
    from word_stats w join students s on s.id = w.student_id
    where coalesce(p_class_name, '') = '' or s.class_name = p_class_name
    group by w.key
    having sum(w.errors) > 0
    order by sum(w.errors) desc
    limit 300) x), '[]');
end $$;

-- ---------- ĆWICZENIE 2 MIN (AI) --------------------------------------

create or replace function public.t_ping()
returns boolean language plpgsql security definer set search_path = public as $$
begin
  perform public._need_teacher();
  return true;
end $$;

create or replace function public._practice_view(p_id uuid, with_answers boolean)
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'practice_id', p.id, 'attempt_id', p.attempt_id, 'practice', true,
    'title', 'Ćwiczenie: ' || q.title,
    'finished', p.finished_at is not null, 'finished_at', p.finished_at,
    'base_score', p.score, 'base_total', p.total, 'extra_score', 0, 'extra_total', 0,
    'student', s.full_name, 'class_name', s.class_name,
    'items', (select json_agg(case when with_answers then json_build_object(
                'type', it->>'type', 'prompt', it->>'prompt', 'options', it->'options',
                'answers', it->'answers', 'explain', it->>'explain', 'extra', false,
                'word', it->>'word_prompt',
                'given', p.results->(o::int - 1)->>'given',
                'ok', (p.results->(o::int - 1)->>'ok')::boolean,
                'to_repeat', (select w.to_repeat from word_stats w where w.student_id = p.student_id and w.key = it->>'key'))
              else json_build_object('type', it->>'type', 'prompt', it->>'prompt', 'options', it->'options', 'extra', false) end
              order by o)
              from jsonb_array_elements(p.items) with ordinality e(it, o)))
  from practices p join attempts a on a.id = p.attempt_id join quizzes q on q.id = a.quiz_id
  join students s on s.id = p.student_id
  where p.id = p_id
$$;

-- Woła funkcja serwerowa (Edge Function) w imieniu ucznia.
-- Zwraca: {none:true} gdy nie było błędów; gotowe ćwiczenie; albo słówka do wygenerowania.
create or replace function public.practice_begin(p_token uuid, p_attempt_id uuid)
returns json language plpgsql security definer set search_path = public as $$
declare sid uuid := public._sid(p_token); a attempts; p practices; w jsonb;
begin
  select * into a from attempts where id = p_attempt_id and student_id = sid and finished_at is not null;
  if not found then raise exception 'attempt_not_found'; end if;
  select * into p from practices where attempt_id = a.id;
  if not found then
    select coalesce(jsonb_agg(x), '[]') into w from (
      select distinct on (it->>'key')
             jsonb_build_object('key', it->>'key', 'type', it->>'type', 'prompt', it->>'prompt',
                                'answers', it->'answers', 'options', it->'options') as x
      from jsonb_array_elements(a.items) with ordinality e(it, o)
      where not coalesce((a.results->(o::int - 1)->>'ok')::boolean, false)
      order by it->>'key', o
      limit 8) z;
    if jsonb_array_length(w) = 0 then return json_build_object('none', true); end if;
    insert into practices(attempt_id, student_id, words) values (a.id, sid, w)
      on conflict (attempt_id) do nothing;
    select * into p from practices where attempt_id = a.id;
  end if;
  if p.items is not null then
    return public._practice_view(p.id, p.finished_at is not null);
  end if;
  return json_build_object('practice_id', p.id, 'generate', true, 'words', p.words);
end $$;

-- Tylko dla funkcji serwerowej (klucz service_role): zapisuje zadania wygenerowane przez AI.
create or replace function public.practice_store(p_practice_id uuid, p_items jsonb)
returns json language plpgsql security definer set search_path = public as $$
declare p practices; clean jsonb;
begin
  select * into p from practices where id = p_practice_id for update;
  if not found then raise exception 'not_found'; end if;
  if p.items is null then
    select coalesce(jsonb_agg(jsonb_build_object(
             'type', it->>'type', 'prompt', it->>'prompt', 'options', it->'options',
             'answers', it->'answers', 'explain', coalesce(it->>'explain', ''),
             'key', p.words->((it->>'word')::int - 1)->>'key',
             'word_prompt', p.words->((it->>'word')::int - 1)->>'prompt') order by o), '[]')
      into clean
      from jsonb_array_elements(p_items) with ordinality e(it, o)
     where it->>'type' in ('vocab', 'gap', 'choice')
       and btrim(coalesce(it->>'prompt', '')) <> ''
       and jsonb_typeof(it->'answers') = 'array' and jsonb_array_length(it->'answers') > 0
       and (it->>'word') ~ '^\d+$' and (it->>'word')::int between 1 and jsonb_array_length(p.words)
       and (it->>'type' <> 'choice' or (jsonb_typeof(it->'options') = 'array' and it->'options' ? (it->'answers'->>0)));
    if jsonb_array_length(clean) < 2 then raise exception 'ai_bad_output'; end if;
    update practices set items = clean where id = p.id;
  end if;
  return public._practice_view(p.id, false);
end $$;

create or replace function public.practice_submit(p_token uuid, p_practice_id uuid, p_answers jsonb)
returns json language plpgsql security definer set search_path = public as $$
declare sid uuid := public._sid(p_token); p practices; r record; good boolean; res jsonb := '[]'; sc int := 0;
begin
  select * into p from practices where id = p_practice_id and student_id = sid for update;
  if not found or p.items is null then raise exception 'attempt_not_found'; end if;
  if p.finished_at is not null then return public._practice_view(p.id, true); end if;
  for r in select it, (o - 1)::int as i from jsonb_array_elements(p.items) with ordinality e(it, o) loop
    good := public._check(r.it, left(coalesce(p_answers->>r.i, ''), 300));
    if good then sc := sc + 1; end if;
    res := res || jsonb_build_array(jsonb_build_object('given', left(coalesce(p_answers->>r.i, ''), 300), 'ok', good, 'key', r.it->>'key'));
  end loop;
  -- słówko, którego wszystkie zadania w ćwiczeniu są poprawne: −1 powtórka
  update word_stats w set to_repeat = greatest(0, w.to_repeat - 1)
   where w.student_id = sid
     and w.key in (select x->>'key' from jsonb_array_elements(res) x group by x->>'key'
                   having bool_and((x->>'ok')::boolean));
  update practices set answers = p_answers, results = res, score = sc,
         total = jsonb_array_length(p.items), finished_at = now()
   where id = p.id;
  return public._practice_view(p.id, true);
end $$;

create or replace function public.t_practice(p_attempt_id uuid)
returns json language plpgsql security definer set search_path = public as $$
declare pid uuid;
begin
  perform public._need_teacher();
  select id into pid from practices where attempt_id = p_attempt_id and finished_at is not null;
  if pid is null then raise exception 'not_found'; end if;
  return public._practice_view(pid, true);
end $$;

-- ---------- DAILY SENTENCES -------------------------------------------

create or replace function public._sent_week(p_sid uuid, p_week_id uuid)
returns public.sentence_weeks language plpgsql stable security definer set search_path = public as $$
declare w sentence_weeks; cls text;
begin
  select class_name into cls from students where id = p_sid;
  select * into w from sentence_weeks where id = p_week_id and is_open and (class_name = '' or class_name = cls);
  if not found then raise exception 'week_unavailable'; end if;
  return w;
end $$;

create or replace function public._sent_item(w public.sentence_weeks, d int, i int)
returns jsonb language plpgsql immutable as $$
declare it jsonb := w.days->d->'items'->i;
begin
  if it is null or coalesce(it->>'phrase', '') = '' then raise exception 'item_not_found'; end if;
  return it;
end $$;

create or replace function public.sent_list(p_token uuid)
returns json language plpgsql security definer set search_path = public as $$
declare sid uuid := public._sid(p_token); cls text;
begin
  select class_name into cls from students where id = sid;
  return coalesce((select json_agg(x order by x.week_start desc) from (
    select w.id, w.title, w.week_start,
      (select count(*) from jsonb_array_elements(w.days) d, jsonb_array_elements(d->'items') it)::int as items,
      (select count(*) from sentence_progress p where p.week_id = w.id and p.student_id = sid and p.done)::int as done
    from sentence_weeks w
    where w.is_open and (w.class_name = '' or w.class_name = cls)) x), '[]');
end $$;

create or replace function public.sent_week(p_token uuid, p_week_id uuid)
returns json language plpgsql security definer set search_path = public as $$
declare sid uuid := public._sid(p_token); w sentence_weeks := public._sent_week(sid, p_week_id);
begin
  return json_build_object(
    'id', w.id, 'title', w.title, 'week_start', w.week_start,
    'days', (select json_agg(json_build_object('day', d->>'day',
               'items', (select coalesce(json_agg(json_build_object('phrase', it->>'phrase', 'type', it->>'type',
                          'definition', it->>'definition', 'polish', it->>'polish', 'status', it->>'status') order by io), '[]')
                         from jsonb_array_elements(d->'items') with ordinality e2(it, io))) order by dord)
             from jsonb_array_elements(w.days) with ordinality e(d, dord)),
    'progress', coalesce((select json_agg(json_build_object('d', p.day_index, 'i', p.item_index, 'attempts', p.attempts,
                  'done', p.done, 'final_verdict', p.final_verdict, 'model_viewed', p.model_viewed,
                  'model', case when p.model_viewed then w.days->p.day_index->'items'->p.item_index->>'model' end))
                from sentence_progress p where p.week_id = w.id and p.student_id = sid), '[]'),
    'attempts', coalesce((select json_agg(json_build_object('d', a.day_index, 'i', a.item_index, 'attempt_no', a.attempt_no,
                  'sentence', a.sentence, 'verdict', a.verdict, 'corrected', a.corrected, 'feedback', a.feedback,
                  'error_types', a.error_types, 'tip', a.tip, 'created_at', a.created_at) order by a.created_at)
                from sentence_attempts a where a.week_id = w.id and a.student_id = sid), '[]'));
end $$;

create or replace function public.sent_model(p_token uuid, p_week_id uuid, p_day int, p_item int)
returns json language plpgsql security definer set search_path = public as $$
declare sid uuid := public._sid(p_token); w sentence_weeks := public._sent_week(sid, p_week_id); it jsonb;
begin
  it := public._sent_item(w, p_day, p_item);
  insert into sentence_progress(week_id, student_id, day_index, item_index, model_viewed, model_viewed_at)
  values (w.id, sid, p_day, p_item, true, now())
  on conflict (week_id, student_id, day_index, item_index) do update
    set model_viewed = true, model_viewed_at = coalesce(sentence_progress.model_viewed_at, now()), updated_at = now();
  return json_build_object('model', coalesce(it->>'model', ''));
end $$;

-- Woła funkcja AI przed sprawdzeniem: czy wolno jeszcze sprawdzić (max 3 próby, nie zakończone).
create or replace function public.sent_check_begin(p_token uuid, p_week_id uuid, p_day int, p_item int)
returns json language plpgsql security definer set search_path = public as $$
declare sid uuid := public._sid(p_token); w sentence_weeks := public._sent_week(sid, p_week_id); it jsonb; pr sentence_progress;
begin
  it := public._sent_item(w, p_day, p_item);
  select * into pr from sentence_progress where week_id = w.id and student_id = sid and day_index = p_day and item_index = p_item;
  if found and pr.done then raise exception 'item_done'; end if;
  if found and pr.attempts >= 3 then raise exception 'item_done'; end if;
  return json_build_object('phrase', it->>'phrase', 'type', it->>'type', 'definition', it->>'definition',
                           'attempt_no', coalesce(pr.attempts, 0) + 1);
end $$;

-- Tylko dla funkcji AI (service_role): zapisuje wynik sprawdzenia.
create or replace function public.sent_store(p_token uuid, p_week_id uuid, p_day int, p_item int, p_sentence text, p_result jsonb)
returns json language plpgsql security definer set search_path = public as $$
declare sid uuid := public._sid(p_token); w sentence_weeks := public._sent_week(sid, p_week_id); it jsonb;
        n int; v text; fin boolean;
begin
  it := public._sent_item(w, p_day, p_item);
  select coalesce(max(attempts), 0) + 1 into n from sentence_progress
   where week_id = w.id and student_id = sid and day_index = p_day and item_index = p_item and not done;
  if exists (select 1 from sentence_progress where week_id = w.id and student_id = sid and day_index = p_day and item_index = p_item and done)
     or n > 3 then raise exception 'item_done'; end if;
  v := p_result->>'verdict';
  if v not in ('correct', 'almost', 'needs work') then raise exception 'ai_bad_output'; end if;
  fin := v = 'correct' or n >= 3;
  insert into sentence_attempts(week_id, student_id, day_index, item_index, phrase, attempt_no, sentence, verdict,
                                corrected, feedback, error_types, tip)
  values (w.id, sid, p_day, p_item, it->>'phrase', n, left(p_sentence, 600), v,
          left(coalesce(p_result->>'corrected', ''), 800), left(coalesce(p_result->>'feedback', ''), 800),
          coalesce(p_result->'error_types', '[]'), left(coalesce(p_result->>'tip', ''), 500));
  insert into sentence_progress(week_id, student_id, day_index, item_index, attempts, done, final_verdict)
  values (w.id, sid, p_day, p_item, n, fin, v)
  on conflict (week_id, student_id, day_index, item_index) do update
    set attempts = n, done = fin, final_verdict = v, updated_at = now();
  return public.sent_week(p_token, p_week_id);
end $$;

create or replace function public.t_sent_weeks()
returns json language plpgsql security definer set search_path = public as $$
begin
  perform public._need_teacher();
  return coalesce((select json_agg(x order by x.week_start desc, x.created_at desc) from (
    select w.*, (select count(*) from jsonb_array_elements(w.days) d, jsonb_array_elements(d->'items') it)::int as items,
      (select count(distinct a.student_id) from sentence_attempts a where a.week_id = w.id)::int as students_active
    from sentence_weeks w) x), '[]');
end $$;

create or replace function public.t_sent_save(p_id uuid, p_week_start date, p_title text, p_class_name text, p_days jsonb, p_is_open boolean)
returns uuid language plpgsql security definer set search_path = public as $$
declare nid uuid;
begin
  perform public._need_teacher();
  if p_week_start is null then raise exception 'no_week'; end if;
  if jsonb_typeof(p_days) <> 'array' or jsonb_array_length(p_days) = 0 then raise exception 'no_items'; end if;
  if exists (select 1 from jsonb_array_elements(p_days) d
             where jsonb_typeof(d->'items') <> 'array' or jsonb_array_length(d->'items') = 0
                or exists (select 1 from jsonb_array_elements(d->'items') it where btrim(coalesce(it->>'phrase', '')) = '')) then
    raise exception 'bad_items';
  end if;
  if p_id is null then
    insert into sentence_weeks(week_start, title, class_name, days, is_open)
    values (p_week_start, btrim(coalesce(p_title, '')), btrim(coalesce(p_class_name, '')), p_days, coalesce(p_is_open, true))
    returning id into nid;
  else
    update sentence_weeks set week_start = p_week_start, title = btrim(coalesce(p_title, '')),
      class_name = btrim(coalesce(p_class_name, '')), days = p_days, is_open = coalesce(p_is_open, true)
    where id = p_id returning id into nid;
  end if;
  return nid;
end $$;

create or replace function public.t_sent_delete(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public._need_teacher();
  delete from sentence_weeks where id = p_id;
end $$;

-- Podgląd tygodnia: treść (z modelami), uczniowie, wszystkie próby i postęp.
create or replace function public.t_sent_overview(p_week_id uuid)
returns json language plpgsql security definer set search_path = public as $$
declare w sentence_weeks;
begin
  perform public._need_teacher();
  select * into w from sentence_weeks where id = p_week_id;
  if not found then raise exception 'not_found'; end if;
  return json_build_object(
    'week', row_to_json(w),
    'students', coalesce((select json_agg(json_build_object('id', s.id, 'full_name', s.full_name, 'class_name', s.class_name) order by s.full_name)
                 from students s where w.class_name = '' or s.class_name = w.class_name
                    or exists (select 1 from sentence_attempts a where a.week_id = w.id and a.student_id = s.id)), '[]'),
    'attempts', coalesce((select json_agg(json_build_object('student_id', a.student_id, 'd', a.day_index, 'i', a.item_index,
                 'phrase', a.phrase, 'attempt_no', a.attempt_no, 'sentence', a.sentence, 'verdict', a.verdict, 'corrected', a.corrected,
                 'feedback', a.feedback, 'error_types', a.error_types, 'tip', a.tip, 'created_at', a.created_at) order by a.created_at)
                 from sentence_attempts a where a.week_id = w.id), '[]'),
    'progress', coalesce((select json_agg(json_build_object('student_id', p.student_id, 'd', p.day_index, 'i', p.item_index,
                 'attempts', p.attempts, 'done', p.done, 'final_verdict', p.final_verdict, 'model_viewed', p.model_viewed,
                 'model_viewed_at', p.model_viewed_at, 'updated_at', p.updated_at))
                 from sentence_progress p where p.week_id = w.id), '[]'));
end $$;

-- ---------- UPRAWNIENIA -----------------------------------------------

do $$
declare f text;
begin
  foreach f in array array['_norm(text,text)', '_item_key(jsonb)', '_check(jsonb,text)', '_sid(uuid)',
                           '_need_teacher()', '_attempt_json(uuid)', '_make_login(text)', '_new_pin()',
                           '_practice_view(uuid,boolean)', 'practice_store(uuid,jsonb)',
                           '_sent_week(uuid,uuid)', '_sent_item(sentence_weeks,int,int)',
                           'sent_store(uuid,uuid,int,int,text,jsonb)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
  end loop;
end $$;
grant execute on function public.practice_store(uuid, jsonb) to service_role;
grant execute on function public.sent_store(uuid, uuid, int, int, text, jsonb) to service_role;

notify pgrst, 'reload schema';
