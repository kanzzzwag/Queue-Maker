-- =====================================================================
-- Migration 007: "Daily Word" game + weekly competition.
-- Run in Supabase -> SQL Editor after migration-006. Safe to run again.
-- Does not touch queue entries.
--
-- The answer lives only in the database (daily_words: admins only).
-- Players see only the colors returned by submit_guess(), and the answer
-- after they finish their own game.
-- =====================================================================
begin;

-- ---------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------
-- Allowed guesses. common = may be picked as a random answer.
create table if not exists public.word_dictionary (
  word   text primary key check (word ~ '^[a-z]{5}$'),
  common boolean not null default false
);

-- Admin's list of upcoming answers, used one per day in order.
create table if not exists public.word_answer_queue (
  id       bigint generated always as identity primary key,
  word     text not null references public.word_dictionary(word),
  added_at timestamptz not null default now(),
  used_on  date
);

-- The answer of each day.
create table if not exists public.daily_words (
  day        date primary key,
  word       text not null,
  source     text not null check (source in ('queue', 'random')),
  created_at timestamptz not null default now()
);

-- One game per user per day.
create table if not exists public.game_plays (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  day         date not null,
  attempts    smallint not null default 0,
  solved      boolean not null default false,
  points      int not null default 0,          -- weekly score of this day (incl. first-solver bonus)
  first_bonus boolean not null default false,
  rewarded    boolean not null default false,  -- points also went to the wallet
  started_at  timestamptz not null default now(),
  finished_at timestamptz,
  unique (user_id, day)
);
create index if not exists game_plays_day_idx on public.game_plays (day);

create table if not exists public.game_guesses (
  id         bigint generated always as identity primary key,
  play_id    bigint not null references public.game_plays(id) on delete cascade,
  n          smallint not null check (n between 1 and 6),
  guess      text not null,
  result     text not null,                    -- 5 letters: c = correct, p = present, a = absent
  created_at timestamptz not null default now(),
  unique (play_id, n)
);

-- Weekly results, fixed every Monday 00:00 Almaty.
create table if not exists public.game_weeks (
  week_start date primary key,
  closed_at  timestamptz not null default now()
);

create table if not exists public.weekly_results (
  week_start     date not null references public.game_weeks(week_start) on delete cascade,
  user_id        uuid not null references public.profiles(id) on delete cascade,
  rank           int not null,
  score          int not null,
  days_played    int not null,
  total_attempts int not null,
  no_rewards     boolean not null default false,
  prize_place    smallint check (prize_place between 1 and 3),   -- badge "Weekly #N"
  prize          int not null default 0,
  primary key (week_start, user_id)
);

-- ---------------------------------------------------------------------
-- Grants + RLS
-- ---------------------------------------------------------------------
revoke all on public.word_dictionary   from anon, authenticated;
revoke all on public.word_answer_queue from anon, authenticated;
revoke all on public.daily_words       from anon, authenticated;
revoke all on public.game_plays        from anon, authenticated;
revoke all on public.game_guesses      from anon, authenticated;
revoke all on public.game_weeks        from anon, authenticated;
revoke all on public.weekly_results    from anon, authenticated;
grant select on public.word_answer_queue to authenticated;
grant select on public.daily_words       to authenticated;
grant select on public.game_plays        to authenticated;
grant select on public.game_guesses      to authenticated;
grant select on public.game_weeks        to authenticated;
grant select on public.weekly_results    to authenticated;

alter table public.word_dictionary   enable row level security;
alter table public.word_answer_queue enable row level security;
alter table public.daily_words       enable row level security;
alter table public.game_plays        enable row level security;
alter table public.game_guesses      enable row level security;
alter table public.game_weeks        enable row level security;
alter table public.weekly_results    enable row level security;

-- Answers: admins only.
drop policy if exists "daily_words: admin read" on public.daily_words;
create policy "daily_words: admin read" on public.daily_words
  for select to authenticated using (public.is_admin());

drop policy if exists "word_answer_queue: admin read" on public.word_answer_queue;
create policy "word_answer_queue: admin read" on public.word_answer_queue
  for select to authenticated using (public.is_admin());

-- Own games and guesses only. Others are shown through the board functions.
drop policy if exists "game_plays: own" on public.game_plays;
create policy "game_plays: own" on public.game_plays
  for select to authenticated using (user_id = auth.uid());

drop policy if exists "game_guesses: own" on public.game_guesses;
create policy "game_guesses: own" on public.game_guesses
  for select to authenticated using (
    exists (select 1 from public.game_plays p where p.id = play_id and p.user_id = auth.uid())
  );

drop policy if exists "game_weeks: members read" on public.game_weeks;
create policy "game_weeks: members read" on public.game_weeks
  for select to authenticated using (public.is_member());

drop policy if exists "weekly_results: members read" on public.weekly_results;
create policy "weekly_results: members read" on public.weekly_results
  for select to authenticated using (public.is_member());

-- ---------------------------------------------------------------------
-- Game logic
-- ---------------------------------------------------------------------
-- Colors for a guess. Repeated letters: a letter gets at most as many
-- hints as it appears in the answer (exact matches first).
create or replace function public._word_score(p_guess text, p_answer text)
returns text language plpgsql immutable set search_path = '' as $$
declare
  res  text[] := array['a', 'a', 'a', 'a', 'a'];
  pool text[] := array[]::text[];   -- answer letters not matched exactly
  i int;
  j int;
begin
  for i in 1..5 loop
    if substr(p_guess, i, 1) = substr(p_answer, i, 1) then
      res[i] := 'c';
    else
      pool := pool || substr(p_answer, i, 1);
    end if;
  end loop;
  for i in 1..5 loop
    if res[i] <> 'c' then
      j := array_position(pool, substr(p_guess, i, 1));
      if j is not null then
        res[i] := 'p';
        pool := pool[1:j - 1] || pool[j + 1:];   -- use this letter once
      end if;
    end if;
  end loop;
  return array_to_string(res, '');
end $$;
revoke execute on function public._word_score(text, text) from public, anon, authenticated;

-- The answer for a day: stored one, else next from the admin list, else a
-- random common word not used before. Picked once, under a lock.
create or replace function public._daily_word(p_day date)
returns text language plpgsql security definer set search_path = '' as $$
declare
  v_word text;
  v_id   bigint;
begin
  select word into v_word from public.daily_words where day = p_day;
  if found then return v_word; end if;

  perform pg_advisory_xact_lock(hashtextextended('daily_word', 0));
  select word into v_word from public.daily_words where day = p_day;
  if found then return v_word; end if;

  select id, word into v_id, v_word from public.word_answer_queue
  where used_on is null order by id limit 1 for update;
  if found then
    update public.word_answer_queue set used_on = p_day where id = v_id;
    insert into public.daily_words (day, word, source) values (p_day, v_word, 'queue');
    return v_word;
  end if;

  select d.word into v_word from public.word_dictionary d
  where d.common and not exists (select 1 from public.daily_words w where w.word = d.word)
  order by random() limit 1;
  if v_word is null then
    select word into v_word from public.word_dictionary where common order by random() limit 1;
  end if;
  insert into public.daily_words (day, word, source) values (p_day, v_word, 'random');
  return v_word;
end $$;
revoke execute on function public._daily_word(date) from public, anon, authenticated;

-- Today's game of the current user (guesses, colors; answer only when finished).
create or replace function public.game_state()
returns json language plpgsql stable security definer set search_path = '' as $$
declare
  v_play public.game_plays;
begin
  if not public.is_member() then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  select * into v_play from public.game_plays where user_id = auth.uid() and day = public.app_today();
  return json_build_object(
    'day',         public.app_today(),
    'attempts',    coalesce(v_play.attempts, 0),
    'finished',    v_play.finished_at is not null,
    'solved',      coalesce(v_play.solved, false),
    'points',      coalesce(v_play.points, 0),
    'first_bonus', coalesce(v_play.first_bonus, false),
    'rewarded',    coalesce(v_play.rewarded, false),
    'eligible',    public.email_verified(auth.uid()),
    'answer',      case when v_play.finished_at is not null
                     then (select word from public.daily_words where day = v_play.day) end,
    'guesses',     coalesce((
                     select json_agg(json_build_object('guess', g.guess, 'result', g.result) order by g.n)
                     from public.game_guesses g where g.play_id = v_play.id), '[]'::json)
  );
end $$;

-- One guess. Checks the word, saves it, returns the new state (colors only).
create or replace function public.submit_guess(p_guess text)
returns json language plpgsql security definer set search_path = '' as $$
declare
  v_uid    uuid := auth.uid();
  v_day    date := public.app_today();
  v_guess  text := lower(btrim(coalesce(p_guess, '')));
  v_word   text;
  v_play   public.game_plays;
  v_res    text;
  v_n      int;
  v_first  boolean;
  v_points int;
  v_paid   boolean;
begin
  if not public.is_member() then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if v_guess !~ '^[a-z]{5}$' then
    raise exception 'Enter a 5-letter word.';
  end if;
  if not exists (select 1 from public.word_dictionary where word = v_guess) then
    raise exception 'Not in word list.';
  end if;

  v_word := public._daily_word(v_day);

  insert into public.game_plays (user_id, day) values (v_uid, v_day) on conflict (user_id, day) do nothing;
  select * into v_play from public.game_plays where user_id = v_uid and day = v_day for update;
  if v_play.finished_at is not null then
    raise exception 'You already played today.';
  end if;

  v_n := v_play.attempts + 1;
  v_res := public._word_score(v_guess, v_word);
  insert into public.game_guesses (play_id, n, guess, result) values (v_play.id, v_n, v_guess, v_res);

  if v_res = 'ccccc' then
    -- First solver of the day gets +20 (lock so two cannot both be first).
    perform pg_advisory_xact_lock(hashtextextended('game_first:' || v_day::text, 0));
    v_first := not exists (select 1 from public.game_plays where day = v_day and solved and id <> v_play.id);
    v_points := (array[100, 80, 60, 40, 25, 10])[v_n] + case when v_first then 20 else 0 end;
    v_paid := public.email_verified(v_uid);
    update public.game_plays
    set attempts = v_n, solved = true, finished_at = now(),
        points = v_points, first_bonus = v_first, rewarded = v_paid
    where id = v_play.id;
    if v_paid then
      perform public._points_add(v_uid, v_points, 'game_reward', null,
        'Daily Word ' || to_char(v_day, 'DD Mon'), 'game_plays', v_play.id);
    end if;
  elsif v_n >= 6 then
    update public.game_plays set attempts = v_n, finished_at = now() where id = v_play.id;
  else
    update public.game_plays set attempts = v_n where id = v_play.id;
  end if;

  return public.game_state();
end $$;

-- ---------------------------------------------------------------------
-- Boards
-- ---------------------------------------------------------------------
-- Today: who finished, attempts, solved, time. No words, no guesses.
create or replace function public.game_today_board()
returns table (username text, display_name text, avatar_path text, attempts int,
               solved boolean, first_bonus boolean, finished_at timestamptz, no_rewards boolean)
language sql stable security definer set search_path = '' as $$
  select pr.username, pr.display_name, pr.avatar_path, gp.attempts::int, gp.solved, gp.first_bonus,
         gp.finished_at, not public.email_verified(gp.user_id)
  from public.game_plays gp
  join public.profiles pr on pr.id = gp.user_id
  where public.is_member() and gp.day = public.app_today() and gp.finished_at is not null
  order by gp.solved desc, gp.attempts, gp.finished_at;
$$;

-- Weekly ranking (Mon..Sun). Ties: more days played, then fewer attempts.
create or replace function public._week_ranking(p_week date)
returns table (user_id uuid, rank int, score int, days_played int, total_attempts int, no_rewards boolean)
language sql stable security definer set search_path = '' as $$
  select s.user_id,
         (row_number() over (order by s.score desc, s.days_played desc, s.total_attempts, s.first_finish))::int,
         s.score, s.days_played, s.total_attempts, not public.email_verified(s.user_id)
  from (
    select gp.user_id,
           sum(gp.points)::int   as score,
           count(*)::int         as days_played,
           sum(gp.attempts)::int as total_attempts,
           min(gp.finished_at)   as first_finish
    from public.game_plays gp
    where gp.day between p_week and p_week + 6 and gp.finished_at is not null
    group by gp.user_id
  ) s;
$$;
revoke execute on function public._week_ranking(date) from public, anon, authenticated;

create or replace function public.game_week_board(p_week date default null)
returns table (rank int, username text, display_name text, avatar_path text, score int,
               days_played int, total_attempts int, no_rewards boolean)
language sql stable security definer set search_path = '' as $$
  select r.rank, pr.username, pr.display_name, pr.avatar_path, r.score, r.days_played, r.total_attempts, r.no_rewards
  from public._week_ranking(coalesce(p_week, public.app_week_start())) r
  join public.profiles pr on pr.id = r.user_id
  where public.is_member()
  order by r.rank;
$$;

-- Close a finished week: save results, pay 300/200/100 to the top 3 players
-- with a confirmed email, give badges. Idempotent: a closed week is skipped.
create or replace function public.close_game_week(p_week date default null)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_week  date := coalesce(p_week, public.app_week_start() - 7);
  v_place int := 0;
  r       record;
begin
  if auth.uid() is not null and not public.is_admin() then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if extract(isodow from v_week) <> 1 then
    raise exception 'Week must start on Monday.';
  end if;
  if v_week >= public.app_week_start() then
    raise exception 'This week is not over yet.';
  end if;

  insert into public.game_weeks (week_start) values (v_week) on conflict do nothing;
  if not found then
    return;                                   -- already closed: no second payout
  end if;

  insert into public.weekly_results (week_start, user_id, rank, score, days_played, total_attempts, no_rewards)
  select v_week, w.user_id, w.rank, w.score, w.days_played, w.total_attempts, w.no_rewards
  from public._week_ranking(v_week) w;

  for r in
    select wr.user_id from public.weekly_results wr
    where wr.week_start = v_week and not wr.no_rewards and wr.score > 0
    order by wr.rank limit 3
  loop
    v_place := v_place + 1;
    update public.weekly_results
    set prize_place = v_place, prize = (array[300, 200, 100])[v_place]
    where week_start = v_week and user_id = r.user_id;
    perform public._points_add(r.user_id, (array[300, 200, 100])[v_place], 'weekly_prize', null,
      'Daily Word week of ' || to_char(v_week, 'DD Mon'), 'game_weeks', to_char(v_week, 'YYYYMMDD')::bigint);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- Admin: answer list
-- ---------------------------------------------------------------------
-- Upcoming words (today's word is picked first, so it is never in this list).
create or replace function public.admin_answer_queue()
returns table (id bigint, word text, added_at timestamptz)
language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  perform public._daily_word(public.app_today());
  return query
    select q.id, q.word, q.added_at from public.word_answer_queue q
    where q.used_on is null order by q.id;
end $$;

-- Add words. Returns {"added": n, "rejected": [...]}.
create or replace function public.admin_add_answers(p_words text[])
returns json language plpgsql security definer set search_path = '' as $$
declare
  w text;
  v_added int := 0;
  v_bad text[] := array[]::text[];
begin
  if not public.is_admin() then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  if coalesce(array_length(p_words, 1), 0) > 500 then
    raise exception 'Max 500 words at a time.';
  end if;
  perform public._daily_word(public.app_today());   -- fix today's word before adding
  foreach w in array coalesce(p_words, array[]::text[]) loop
    w := lower(btrim(w));
    continue when w = '';
    if w ~ '^[a-z]{5}$' and exists (select 1 from public.word_dictionary d where d.word = w) then
      insert into public.word_answer_queue (word) values (w);
      v_added := v_added + 1;
    else
      v_bad := v_bad || w;
    end if;
  end loop;
  return json_build_object('added', v_added, 'rejected', to_json(v_bad));
end $$;

create or replace function public.admin_remove_answer(p_id bigint)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  delete from public.word_answer_queue where id = p_id and used_on is null;
end $$;

create or replace function public.admin_reveal_today()
returns text language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_admin() then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  return public._daily_word(public.app_today());
end $$;

revoke execute on function public.game_state()                  from public, anon;
revoke execute on function public.submit_guess(text)            from public, anon;
revoke execute on function public.game_today_board()            from public, anon;
revoke execute on function public.game_week_board(date)         from public, anon;
revoke execute on function public.close_game_week(date)         from public, anon;
revoke execute on function public.admin_answer_queue()          from public, anon;
revoke execute on function public.admin_add_answers(text[])     from public, anon;
revoke execute on function public.admin_remove_answer(bigint)   from public, anon;
revoke execute on function public.admin_reveal_today()          from public, anon;
grant  execute on function public.game_state()                  to authenticated;
grant  execute on function public.submit_guess(text)            to authenticated;
grant  execute on function public.game_today_board()            to authenticated;
grant  execute on function public.game_week_board(date)         to authenticated;
grant  execute on function public.close_game_week(date)         to authenticated;
grant  execute on function public.admin_answer_queue()          to authenticated;
grant  execute on function public.admin_add_answers(text[])     to authenticated;
grant  execute on function public.admin_remove_answer(bigint)   to authenticated;
grant  execute on function public.admin_reveal_today()          to authenticated;

-- ---------------------------------------------------------------------
-- Cron (UTC). 19:00 UTC = 00:00 Asia/Almaty.
--   word-pick:  fix the new day's word right at midnight.
--   game-week:  Sunday 19:00 UTC = Monday 00:00 Almaty -> close last week.
-- ---------------------------------------------------------------------
select cron.schedule('word-pick', '0 19 * * *', $$ select public._daily_word(public.app_today()) $$);
select cron.schedule('game-week', '0 19 * * 0', $$ select public.close_game_week() $$);

-- ---------------------------------------------------------------------
-- Dictionary (lowercase a-z, 5 letters). Built from open word lists
-- (Hunspell en_US + a subtitle frequency list); offensive words removed.
-- ---------------------------------------------------------------------
insert into public.word_dictionary (word)
select w from regexp_split_to_table(btrim($words$
aback abaft abase abash abate abbes abbey abbot abeam abets abhor abide abler abode abort about
above abuse abuts abuzz abyss ached aches achoo acids acing acmes acorn acres acrid acted actor
acute adage adapt added adder addle adept adieu adios adman admen admin admit admix adobe adopt
adore adorn adult adzes aegis aerie affix afire afoot afoul after again agape agate agave agent
aggro agile aging aglow agony agree ahead aided aides ailed aimed aired aisle aitch alack alarm
album alder alert algae algal alias alibi alien align alike alkyd allay alley allot allow alloy
aloes aloft aloha alone along aloof aloud alpha altar alter altos alums amass amaze amber ambit
amble amend amide amigo amine amino amiss amity among amour ample amply amuse anent angel anger
angle angry angst anime anion anise ankhs ankle annex annoy annul anode anons anted antes antic
antis antsy anvil aorta apace apart aphid aping apish apple apply apron apses apter aptly aquas
arbor arced ardor areal areas arena argon argot argue arias arise armed armor aroma arose arras
array arrow arsed arson artsy arums ascot ashed ashes aside asked askew aspen aspic assay asset
assoc aster astir atilt atlas atoll atoms atone atria attar attic audio audit auger aught augur
aunts aural auras autos auxin avail avast avert avian avoid avows await awake award aware awash
awful awing awoke axial axing axiom axles axons ayahs azure baaed babel babes baccy backs bacon
badge badly bagel baggy bahts bails bairn baits baize baked baker bakes balds baldy baled baler
bales balks balky balls bally balms balmy balsa banal bands bandy banes bangs banjo banks banns
barbs bards bared barer bares barfs barge barks barmy barns baron barre basal based baser bases
basic basil basin basis basks basso baste batch bated bates bathe baths batik baton batty bauds
bawds bawdy bawls bayed bayou beach beads beady beaks beams beans beard bears beast beats beaus
beaut bebop becks bedim beech beefs beefy beeps beery beets befit befog began begat beget begin
begot begum begun beige being belay belch belie belle bells belly below belts bench bends bendy
bents beret bergs berks berms berry berth beryl beset besom besot bests betas betel bevel bevvy
bezel bhaji bible bicep biddy bides bidet biffs bight bigot bijou biked biker bikes bilge bilks
bills billy binds binge bingo biped birch birds birth bison biter bites bitty blabs black blade
blags blahs blame bland blank blare blase blast blats blaze bleak blear bleat bleed bleep blend
bless blimp blind bling blini blink blips bliss blitz bloat blobs block blocs blogs bloke blond
blood bloom bloop blots blown blows blowy blued bluer blues bluet bluff blunt blurb blurs blurt
blush board boars boast boats bobby boded bodes bodge boffo bogey boggy bogie bogon bogus boils
boink bolas boles bolls bolts bolus bombs bonce bonds boned bones bongo bongs bonny bonus booed
books booms boons boors boost booth boots booty booze boozy borax bored borer bores borne boron
bosom bossy botch bough bound bouts bowed bowel bower bowls boxed boxer boxes bozos brace bract
brads braes brags braid brain brake brand brash brass brats brave bravo brawl brawn brays braze
bread break bream breed breve brews bribe brick bride brief brier brigs brill brims brine bring
brink briny brisk broad broil broke bronc brood brook broom broth brown brows bruin bruit brunt
brush brute bucks buddy budge buffs buggy bugle build built bulbs bulge bulgy bulks bulky bulls
bully bumph bumps bumpy bunch bunco bungs bunks bunny bunts buoys burbs burgh burgs burka burls
burly burns burnt burps burro burrs bursa burst busby bused buses bushy busks busts busty butch
butte butty buxom buyer bylaw byres bytes byway cabal cabby caber cabin cable cacao cache cacti
cadet cadge cadre cafes caffs caged cages cagey cairn caked cakes calks calla calls calms calve
calyx camel cameo camps campy canal candy caned caner canes canny canoe canon canst canto cants
caped caper capes capon capos carat carbs cards cared carer cares caret cargo carny carob carol
carom carpi carps carry carts carve cased cases casks caste casts catch cater catty caulk cause
caved caver caves cavil cawed cease cecal cecum cedar ceded ceder cedes celeb cello cells cents
certs chads chafe chaff chain chair chalk champ chant chaos chaps chard charm chars chart chary
chase chasm chats cheap cheat check cheek cheep cheer chefs chemo chert chess chest chews chewy
chick chide chief child chili chill chime chimp china chine chino chins chips chirp chits chive
chivy chock chocs choir choke chomp chops chord chore chose chows chubs chuck chugs chump chums
chunk churl churn chute chyme ciaos cider cigar cilia cinch circa cirri cited cites civet civic
civil clack clade claim clamp clams clang clank clans claps clash clasp class claws clean clear
cleat clefs cleft clerk clews click cliff climb clime cling clink clips clits cloak clock clods
clogs clomp clone clonk clops close cloth clots cloud clout clove clown cloys clubs cluck clued
clues clump clung clunk clvii clxii clxiv clxix clxvi coach coals coast coats cobra cocci cocks
cocky cocoa cocos codas coded coder codes codex codon coeds cohos coifs coils coins coked cokes
colas colds coley colic colon color colts comas combo combs comer comes comet comfy comic comma
compo comps conch condo conga conic contd cooed cooks cools coops coots copay coped copes copra
copse coral cords cored corer cores corgi corks corms corns corny corps costs cotes couch cough
could count coupe coups court coven cover coves covet covey cowed cower cowls coxed coxes coyer
coyly coypu cozen crabs crack craft crags cramp crams crane crank crape craps crash crass crate
crave crawl craws crays craze crazy creak cream credo creed creek creel creep creme crepe crept
cress crest crews cribs crick cried crier cries crime crimp crisp croak crock croft crone crony
crook croon crops cross croup crowd crown crows crude cruel cruet cruft crumb cruse crush crust
crypt cubed cuber cubes cubic cubit cuffs cuing culls cults cumin cupid cuppa curbs curds cured
curer cures curia curie curio curls curly curry curse curve curvy cushy cusps cuter cutey cutie
cutup cycle cynic cysts czars daces dacha daddy daffy dagos daily dairy daisy dales dally dames
damns damps dance dandy dangs dared darer dares darns darts dated dater dates datum daubs daunt
davit dawns dazed dazes dding deals dealt dears deary death debit debts debut decaf decal decay
decks decor decoy decry deems deeps deify deign deist deity delay delft delis dells delta delve
demon demur denim dense dents depth derby desks deter detox deuce devil dhoti dhows dials diary
diced dices dicey dicta didst diets diffs digit diked dikes dills dilly dimer dimes dimly dinar
dined diner dines dingo dingy dinky diode dippy dipso direr dirge dirks dirty disco dishy disks
ditch ditsy ditto ditty divan divas dived diver dives divot divvy dizzy dobro docks dodge dodgy
dodos doffs doges doggy dogie dogma doily doing doled doles dolls dolly dolor dolts domed domes
donas dongs donor dooms doors doped doper dopes dopey dorks dorky dorms dosed doses doted doter
dotes dotty doubt dough douse doves dowdy dowel dower downs downy dowry dowse doyen dozed dozen
dozes drabs draft drags drain drake drama drams drank drape drawl drawn draws drays dread dream
drear dregs dress dried drier dries drift drill drink drips drive droid droll drone drool droop
drops dross drove drown drubs drugs druid drums drunk drupe dryad dryer dryly ducal ducat duchy
ducks ducky ducts duded dudes duels duets duffs dukes dulls dully dummy dumps dumpy dunce dunes
dungs dunks dunno duped duper dupes duple durst durum dusky dusts dusty dutch duvet dwarf dweeb
dwell dwelt dying eager eagle eared earls early earns earth eased easel eases eaten eater eaves
ebbed ebony echos eclat edema edged edger edges edict edify edits educe eerie effed egged egret
eider eight eject eking eland elate elbow elder elect elegy elfin elide elite elope elude elver
elves email embed ember emcee emend emery emirs emits emoji emote empty enact ended endow endue
enema enemy enjoy ennui ensue enter entry envoy epees epics epoch epoxy equal equip equiv erase
erect ergot erode erred error eruct erupt essay ester ether ethic ethos ethyl etude euros evade
evens event every evict evils evoke exact exalt exams excel execs exert exile exist exits exons
expat expel expos extol extra exude exult exurb fable faced faces facet facts faddy faded fades
faffs fails faint fairs fairy faith faked faker fakes fakir falls false famed fancy fangs fanny
farad farce fared fares farms farts fasts fatal fated fates fatso fatty fatwa fault fauna fauns
faves favor fawns faxed faxes fayer fazed fazes fears feast feats fecal feces feeds feels feign
feint fella fells felon felts femur fence fends feral ferns ferny ferry fests fetal fetch feted
fetes fetid fetus feuds fever fewer fiats fiber fiche fichu ficus fiefs field fiend fiery fifer
fifes fifth fifty fight filch filed filer files filet fills filly films filmy filth final finch
finds fined finer fines finis finks finny fired firer fires firms first firth fishy fists fitly
fiver fives fixed fixer fixes fizzy fjord flack flags flail flair flake flaky flame flank flans
flaps flare flash flask flats flaws flays fleas fleck flees fleet flesh flick flied flier flies
fling flint flips flirt flits float flock floes flogs flood floor flops flora floss flour flout
flown flows flubs flues fluff fluid fluke fluky flume flung flunk flush flute flyby foals foams
foamy focal focus foggy foils foist folds folic folio folks folly fonts foods fools foots footy
foray force fords fores forge forgo forks forms forte forts forty forum fossa fouls found fount
fours fowls foxed foxes foyer frack frags frail frame franc frank frats fraud frays freak freed
freer frees fresh frets friar fried fries frigs frill frisk fritz frizz frock frogs frond front
frosh frost froth frown froze fruit frump fryer fudge fuels fugal fuggy fugue fulls fully fumed
fumes funds fungi funks funky funny furls furor furry furze fused fusee fuses fussy fusty futon
fuzzy gabby gable gaffe gaffs gaily gains gaits galas gales galls gamed gamer games gamin gamma
gammy gamut gangs ganja gaped gapes garbs gases gasps gassy gated gates gator gaudy gauge gaunt
gauze gauzy gavel gawks gawky gawps gayer gazed gazer gazes gears gecko geeks geeky geese gelds
gelid genes genie genii genre gents genus geode germs getup ghats ghost ghoul giant gibed gibes
giddy gifts gilds gills gilts gimme gimps gimpy girds girls girly giros girth girts gites given
giver gives gizmo glace glade glads gland glans glare glass glaze gleam glean glens glide glint
glitz gloat globe globs gloom glory gloss glove glows glued glues gluey gluon gluts glyph gnarl
gnash gnats gnaws gnome goads goals goats godly gofer going golds golfs golly gonad goner gongs
gonks gonzo goods goody gooey goofs goofy goons goose gored gores gorge gorps gorse goths gouge
gourd gouty gowns grabs grace grade grads graft grail grain grams grand grans grant grape graph
grasp grass grate grave gravy grays graze great grebe greed green greet greps grids grief grill
grime grimy grind grins gripe grips grist grits groan groat groin groks groom grope gross group
grout grove growl grown grows grubs gruel grues gruff grump grunt guano guard guava guess guest
guide guild guile guilt guise gulag gulch gulfs gulls gully gulps gumbo gummy gunge gungy gunky
gunny guppy gurus gushy gussy gusto gusts gusty gutsy gutty guyed gyros gyved gyves habit hacks
hadst hafts haiku hails hairs hairy hajji hakes halal haled haler hales halls halon halos halts
halve hammy hands handy hangs hanks haply happy hardy hared harem hares harks harms harps harpy
harry harsh harts hasps haste hasty hatch hated hater hates hauls haunt haven haves havoc hawed
hawks hayed hazed hazel hazer hazes hdqrs heads heady heals heaps heard hears heart heath heats
heave heavy hedge heeds heels hefts hefty heirs heist helix hello helms helot helps helve hence
henna herbs herds heron hertz hewed hewer hexed hexes hicks hided hider hides highs hijab hiked
hiker hikes hills hilly hilts hinds hinge hints hippo hippy hired hires hitch hived hives hoard
hoary hobby hobos hocks hogan hoick hoist hoked hokes hokey hokum holds holed holes holey holly
homed homer homes homey honed honer hones honey honks honor hooch hoods hooey hoofs hooks hooky
hoops hoots hoped hopes horas horde horns horse hosed hoses hosts hotel hotly hound houri hours
house hovel hover howdy howls hubby huffs huffy huger hulas hulks hulls human humid humor humph
humps humus hunch hunks hunky hunts hurls hurry hurts husks husky hutch hydra hydro hyena hying
hymen hymns hyped hyper hypes hypos iambi iambs icier icily icing icons ictus ideal ideas idiom
idiot idled idler idles idols idyll igloo ileum ilium illus image imago imams imbue impel imper
imply inane inbox inced incur index indie inept inert infix infra ingot inked inner innit instr
intel inter intro inure ioctl ionic iotas irate irked irons irony isles islet issue itchy items
ivied ivies ivory jabot jacks jaded jades jails jambs jammy japan japed japes jatos jaunt jawed
jazzy jeans jeeps jeers jello jells jelly jemmy jenny jerks jerky jests jetty jewel jibed jibes
jiffs jiffy jihad jilts jimmy jinks jinni jived jives jocks joeys johns joins joint joist joked
joker jokes jokey jolly jolts joule joust jowls jowly joyed judge juice juicy julep jumbo jumps
jumpy junco junks junta juror kanji kapok kappa kaput karat karma karts kayak kayos kazoo kebab
keels keens keeps kepis ketch keyed khaki khans kicks kicky kiddo kills kilns kilos kilts kinda
kinds kines kings kinks kinky kiosk kited kites kitty kiwis kluge klutz knack knave knead kneed
kneel knees knell knelt knife knish knits knobs knock knoll knots known knows knurl koala koans
kolas kooks kooky korma kraal kraut krill krona krone kudos kudzu label labia labor laced laces
lacks laded laden lades ladle lager laird lairs laity lakes lamas lambs lamed lamer lames lamps
lanai lance lands lanes lanky lapel lapin lapse larch lards lardy large largo larks larva lased
laser lases lasso lasts latch later latex lathe laths latte lauds laugh laved laves lawns laxer
laxly layer layup lazed lazes leach leads leafs leafy leaks leaky leans leaps leapt learn lease
leash least leave ledge leech leeks leery lefts lefty legal leggy legit lemma lemme lemon lemur
lends lento leper lepta letup levee level lever lexer lexis liars libel licit licks lidos liege
liens lifer lifts light liked liken liker likes lilac lilos lilts limbo limbs limed limes limey
limit limns limos limps lined linen liner lines lingo links lints linty lions lipid lippy lisle
lisps lists liter lithe lived liven liver lives livid llama llano loads loafs loamy loans loath
lobar lobby lobed lobes local locks locos locum locus lodes lodge lofts lofty loges logic login
logon logos loins lolls lolly loner longs looks looms loons loony loops loopy loose loots loped
lopes lords loris lorry loser loses lotto lotus lough lours louse lousy louts loved lover loves
lovey lowed lower lowly loyal luaus lubed lubes lucid lucks lucky lucre luffs luges lulls lulus
lumen lumps lumpy lunar lunch lunge lungs lupus lurch lured lures lurgy lurid lurks lusts lusty
lutes lxvii lying lymph lynch lyres lyric macaw maced maces macho macro madam madly mafia mages
magic magma magus maids mails maims mains maize major maker makes males malls malts malty mamas
mamba mambo mamma mammy maned manes manga mange mango mangy mania manic manky manly manna manor
manse manta maple march mares marge maria marks marry marsh marts maser masks mason masts match
mated mater mates matey matte matzo mauls mauve maven maxed maxes maxim maxis maybe mayor mayst
mazes meals mealy means meant meany meats meaty mecca medal media medic meets melds melee melon
melts memes memos mends menus meows mercy meres merge merit merry mesas meson messy metal meted
meter metes meths metro mewed mewls mezzo micks micro middy midge midis midst miffs might miked
mikes milch miler miles milfs milks milky mills milts mimed mimes mimic mince minds mined miner
mines mingy minim minis minks minor mints minty minus mired mires mirth misdo miser mists misty
miter mites mitts mixed mixer mixes moans moats mocha mocks modal model modem modes moggy mogul
moils moire moist molar molds moldy moles molls molly molts mommy monad money monks month mooch
moods moody mooed moons moors moose moots moped moper mopes mopey moral moray morel mores morns
moron morph mosey mossy motel motes motet moths motif motor motto moues mound mount mourn mouse
mousy mouth moved mover moves movie mowed mower moxie mucks mucky mucus muddy muffs mufti muggy
mulch mulct mules mulls multi mummy mumps munch mungs mural murks murky mused muses mushy music
musky mussy musts musty muted muter mutes mutts muzak muzzy mynas myrrh myths naans nabob nacho
nacre nadir naiad naifs nails naive naked named names nanny napes nappy narcs narky nasal nasty
natal natch natty naval navel naves navvy neaps nears neath necks needs needy neigh nerds nerdy
nerve nervy nests never nevus newel newer newly newsy newts nexus nicer niche nicks niece niffy
nifty night nimbi nimby nines ninja ninny ninth nippy nisei niter nitro nixed nixes noble nobly
nodal noddy nodes noels nohow noise noisy nomad nonce nooks nooky noose norms north nosed noses
notch noted notes nouns novae novas novel noway nubby nuder nudes nudge nuked nukes nulls numbs
nurse nutty nylon nymph oakum oared oases oasis oaths obese obeys obits oboes occur ocean ocher
ocker octal octet odder oddly odium odors offal offed offer often ogled ogler ogles ogres oiled
oinks okapi okays okras older oldie olive omega omits onion onset oohed oomph oozed oozes opals
opens opera opine oping opium opted optic orals orate orbit order organ oriel orris osier other
otter ought ounce ousts outdo outed outer outgo outre outta ouzos ovals ovary ovate ovens overs
overt ovoid ovule owing owlet owned owner oxbow oxide ozone paced pacer paces pacey packs pacts
paddy padre paean pagan paged pager pages pails pains paint pairs paled paleo paler pales palls
pally palms palmy palsy panda panel panes pangs panic pansy panto pants papal papas paper pappy
paras parch pared parer pares parka parks parky parry parse parts party pasha passe pasta paste
pasts pasty patch pates paths patio patsy patty pause paved paves pawed pawls pawns payed payee
payer peace peach peaks peaky peals pearl pears peaty pecan pecks pedal peeks peels peens peeps
peeve pekes pekoe pelts penal pence pends penny peons peony peppy perch peril perks perky perms
pervs pesky pesos pesto pests petal peter petty pewee pewit phage phase phial phish phlox phone
phony photo phyla piano picks picky picot piece piety piggy piing piked piker pikes pilaf piled
piles pills pilot pimps pinch pined pines piney pinko pinks pinny pinon pinto pints pinup pious
piped piper pipes pipit pique piste pitas pitch pithy piton pitta pivot pixel pixie pizza place
plaid plain plait plane plank plans plant plash plate plats platy plays plaza plead pleas pleat
plebe plebs plied plies plods plonk plops plots plows ploys pluck plugs plumb plume plump plums
plumy plunk plush poach pocks poems poesy poets point poise poked poker pokes pokey polar poled
poles polio polka polls polyp polys pommy poncy ponds pones pongs pooch pooed poohs pools poops
popes poppa poppy popup porch pored pores porgy porky ports posed poser poses posit posse posts
potty pouch poufs pound pours pouts power poxes prams prang prank prate prats prawn prays preen
preps press preys price pride pried prier pries prigs prime primp print prion prior prism privy
prize probe prods profs prole promo prone prong proof props prose prosy proud prove prowl prows
proxy prude prune psalm pseud pshaw psych pubis pucks pudgy puffs puffy puked pukes pukka puled
pules pulls pulps pulpy pulse pumas pumps punch punks punts pupae pupal pupil puppy puree purer
purge purls purrs purse pushy putts putty pwned pygmy pylon pyres pyxes pzazz quack quads quaff
quail quake quaky qualm quark quart quash quasi quays queen quell query quest queue quick quids
quiet quiff quill quilt quine quins quint quips quire quirk quirt quite quits quoin quoit quota
quote rabbi rabid raced racer races racks radar radii radio radon rafts ragas raged rages ragga
raids rails rains rainy raise rajah raked rakes rally ramie ramps ranch randy ranee range rangy
ranks rants raper rapid rared rarer rares rasps raspy rated rater rates ratio ratty raved ravel
raven raver raves rawer rayon razed razes razor reach react reads ready realm reals reams reaps
rears rebel rebid recap recce recon recto recur redye reedy reefs reeks reels reeve refer regal
regex rehab reify reign relax relay relic remit remix renal rends renew rents reorg repel resat
resit rests retch retro revel revue rheas rheum rhino rhyme rials riced ricer rices ricks rider
rides ridge ridgy rifer riffs rifle rifts right rigid rigor riled riles rills rimed rimes rinds
rinks rinse riots ripen riper risen riser rises risks risky rites ritzy rival rived river rives
rivet riyal roach roads roams roans roars roast robed robes robin robot rocks rocky rodeo roger
rogue roils roles rolls roman romeo romps rondo roods roofs rooks rooms roomy roost roots roped
roper ropes roses rosin rotas rotor roues rouge rough round rouse roust route routs roved rover
roves rowan rowdy rowed rowel rower royal rubes ruble rucks ruddy ruder ruffs rugby ruing ruins
ruled ruler rules rumba rummy rumor rumps runes rungs runic runny runts runty rupee rural ruses
rushy rusks rusts rusty rutty saber sable sabot sabra sacks sacra sades sadhu sadly safer safes
sagas sager sages saggy sahib sails saint saith salad sales sally salon salsa salts salty salve
salvo samba sames samey sands sandy saner sangs sappy saran sarge saris sarky sassy satay sated
sates satin satyr sauce saucy sauna saute saved saver saves savor savoy savvy sawed saxes scabs
scads scags scald scale scalp scaly scamp scams scans scant scare scarf scarp scars scary scats
scene scent schmo schwa scion scoff scold scone scoop scoot scope score scorn scour scout scowl
scows scrag scram scrap scree screw scrim scrip scrod scrog scrub scrum scuba scuds scuff scull
scums scurf seals seams seamy sears seats sebum sects sedan sedge sedgy seeds seedy seeks seems
seeps segue seine seize sells semis sends senna senor sense sepal sepia septa serer serfs serge
serif serum serve servo setts setup seven sever sewed sewer sexed sexes shack shade shads shady
shaft shags shahs shake shaky shale shall shalt shame shams shank shape shard share shark sharp
shave shawl shays sheaf shear sheds sheen sheep sheer sheet shelf shell shewn shews shied shier
shies shift shill shims shine shins shiny ships shire shirk shirr shirt shivs shoal shoat shock
shoes shone shook shoos shoot shops shore short shots shout shove shown shows showy shred shrew
shrub shrug shuck shuns shunt shush shuts shyer shyly sibyl sicko sicks sided sides sidle siege
sieve sifts sighs sight sigma signs silks silky sills silly silos silts silty since sines sinew
singe sings sinks sinus sired siren sires sisal sises sissy sitar sited sites sixes sixth sixty
sized sizer sizes skate skeet skein skews skids skied skier skies skiff skill skimp skims skins
skint skips skirt skits skive skoal skuas skulk skull skunk slabs slack slags slain slake slams
slang slant slaps slash slate slats slave slays sleds sleek sleep sleet slept slews slice slick
slide slier slime slims slimy sling slink slips slits slobs sloes slogs sloop slope slops slosh
sloth slots slows slued slues slugs slump slums slung slunk slurp slurs slush slyly smack small
smart smash smear smell smelt smile smirk smite smith smock smogs smoke smoky smote smurf smuts
snack snafu snags snail snake snaky snaps snare snarf snark snarl sneak sneer snick snide sniff
snipe snips snits snobs snogs snood snoop snoot snore snort snots snout snows snowy snubs snuff
snugs soaks soaps soapy soars sober socks sodas sofas softy soggy soils solar soled soles solid
solos solve sonar songs sonic sonny sooth sooty soppy sorer sores sorry sorta sorts sough souks
souls sound soups soupy sours souse south sowed sower space spade spake spams spank spans spare
spark spars spasm spate spats spawn spays speak spear speck specs speed spell spend spent spews
spice spicy spied spiel spies spiff spike spiky spill spine spins spiny spire spiry spite spits
spivs splat splay split spoil spoke spoof spook spool spoon spoor spore sport spots spout sprat
spray spree sprig sprog spuds spume spumy spurn spurs spurt sputa squab squad squat squib squid
stabs stack staff stage stags stagy staid stain stair stake stale stalk stall stamp stand stank
staph stare stark stars start stash state stats stave stays stdio stead steak steal steam steed
steel steep steer stein stems steno stent steps stern stets stews stick sties stiff stile still
stilt sting stink stint stirs stoat stock stoic stoke stole stomp stone stony stood stool stoop
stops store stork storm story stoup stout stove stows strap straw stray strep strew stria strip
strop strum strut stubs stuck studs study stuff stump stung stunk stuns stunt style styli suave
sucks sudsy suede suety sugar suing suite suits sulfa sulks sulky sully sumac sumps sunny sunup
super suppl supra surer surfs surge surly sushi swabs swags swain swami swamp swank swans swaps
sward swarm swash swath swats sways swear sweat swede sweep sweet swell swept swift swigs swill
swims swine swing swipe swirl swish swizz swoon swoop sword swore sworn swots swung sylph syncs
synod syrup sysop tabby tabla table taboo tabor tacit tacks tacky tacos taffy taiga tails taint
taken taker takes tales talks talky tally talon talus tamed tamer tames tamps tango tangs tangy
tanks tansy tapas taped taper tapes tapir tardy tared tares tarns taros tarot tarps tarry tarsi
tarts tarty taser tasks taste tasty tater tatty taunt taupe tawny taxed taxer taxes taxis taxon
teach teaks teals teams tears teary tease teats techs teddy teems teens teeny telex tells telly
tempo temps tempt tench tends tenet tenon tenor tense tenth tents tepee tepid terms terns terry
terse tests testy tetra texts thane thank thaws thees theft their theme there therm these theta
thews thick thief thigh thine thing think thins third thole thong thorn those thous three threw
throb throe throw thrum thuds thugs thumb thump thunk thyme tiara tibia ticks tidal tided tides
tiffs tiger tight tilde tiled tiler tiles tills tilts timed timer times timid tines tinge tinny
tints tipsy tired tires titan titch tithe title tizzy toads toady toast today toddy toffs togas
toils toked token tokes tolls tombs tomes tonal toned toner tones tongs tonic tonne tools tooth
toots topaz topee topic toque torch torso torte torts torus total toted totem totes touch tough
tours touts towed towel tower towns toxic toxin toyed trace track tract trade trail train trait
tramp trams trans traps trash trawl trays tread treas treat treed trees treks trend tress trews
treys triad trial tribe trice trick tried trier tries trike trill trims trios tripe trips trite
troll tromp trons troop trope troth trots trout trove trows troys truce truck trued truer trues
trugs truly trump trunk truss trust truth tryst tubal tubas tubby tubed tuber tubes tucks tufts
tulip tulle tumid tummy tumor tunas tuned tuner tunes tunic tunny tuple tuque turbo turfs turfy
turns turps tusks tutor tutti tutus tuxes twain twang tweak tweed tween tweet twerk twerp twice
twigs twill twine twink twins twirl twist twits twixt tying tykes typed types typos tyros udder
ukase ulcer ulnae ulnar ultra umbel umber umbra umiak umped unary unbid unbox uncap uncle uncut
under undue unfed unfit unfix unify union unite unity unlit unmet unpin unset until unwed upend
upped upper upset urban urged urges urine usage users usher using usual usurp usury uteri utter
uvula vague vagus vales valet valid valor value valve vamps vanes vaped vapes vapid vapor vases
vasts vault vaunt veeps veers vegan veges veils veins velar velds velum venal vends venom vents
venue verbs verge versa verse verso verve vests vetch vexed vexes vials viand vibes vicar viced
vices video views vigil vigor viler villa villi vines vinyl viola viols viper viral vireo virus
visas vised vises visit visor vista vitae vital vivas vivid vixen vocab vocal vodka vogue voice
voids voila voile voles volts vomit voted voter votes vouch vowed vowel vulva vying wacko wacks
wacky waded wader wades wadge wadis wafer wafts waged wager wages wagon waifs wails wains waist
waits waive waked waken wakes waldo waled wales walks walls wally waltz wands waned wanes wanly
wants wards wares warez warms warns warps warts warty washy wasps waste watch water watts waved
waver waves waxed waxes wazoo weals weans wears weary weave wedge weeds weedy weeks weens weeny
weeps weepy weest wefts weigh weird weirs welds wells welly welsh welts wench wends wetly whack
whale whams wharf whats wheal wheat wheel whelk whelm whelp whens where whets which whiff while
whims whine whiny whips whirl whirs whisk whist white whits whole whoop whops whorl whose whoso
whups wicks widen wider widow width wield wight wikis wilds wiled wiles wills willy wilts wimps
wimpy wince winch winds windy wined wines winks winos wiped wiper wipes wired wires wised wiser
wises wisps wispy witch withe witty wived wives wodge wolds wolfs woman wombs women wonks wonky
woods woody wooed wooer woofs woozy words wordy works world worms wormy worry worse worst worth
would wound woven wowed wrack wraps wrath wreak wreck wrens wrest wring wrist write writs wrong
wrote wroth wrung wryer wryly wurst wussy xcvii xenon xerox xrefs xterm xviii xxiii xxvii xxxii
xxxiv xxxix xxxvi xylem yacht yahoo yanks yards yarns yawed yawls yawns yeahs yearn years yeast
yeggs yells yelps yeses yetis yield yikes yobbo yodel yogic yogis yoked yokel yokes yolks yonks
young yours youth yowls yucca yucky yukky yummy yurts zappy zebra zebus zeros zests zesty zetas
zilch zincs zines zingy zippy zloty zonal zoned zones zooms zorch
$words$), '\s+') as w
where w ~ '^[a-z]{5}$'
on conflict (word) do nothing;

-- Common words: may be picked as random answers.
update public.word_dictionary set common = true
where word in (select w from regexp_split_to_table(btrim($words$
abbey abbot abide abode abort about above abuse abyss aches acids acorn acres acted actor acute
adapt added adept adieu adios admin admit adopt adore adorn adult afoot after again agent agile
aging agony agree ahead aided aimed aired aisle alarm album alert algae alias alibi alien align
alike alley allow alloy aloft aloha alone along aloof aloud alpha altar alter amaze amber amend
amigo amino amiss among amour ample amuse angel anger angle angry angst ankle annex annoy anvil
aorta apart apple apply apron arbor areas arena argue arise armed armor aroma arose array arrow
arson ashes aside asked aspen asset atlas atoms atone attic audio audit aunts avail avert avoid
await awake award aware awful awoke babes backs bacon badge badly bagel baggy baked baker baldy
balls banal bands bangs banjo banks barge barks baron based bases basic basil basin basis batch
bates bathe baths baton batty bayou beach beads beaks beams beans beard bears beast beats beaut
bebop becks beech beeps beets began begin begun beige being belch belle bells belly below belts
bench bends beret berry berth beryl betel bible bigot biker bikes bills billy binds binge bingo
birch birds birth bison bites bitty black blade blame bland blank blast blaze bleak bleed bleep
blend bless blimp blind blink bliss blitz block bloke blond blood bloom blown blows blues bluff
blunt blush board boars boast boats bobby bogey bogus boils bolts bombs bonds bones bongo bonny
bonus books booms boost booth boots booty booze bored bores borne bosom bossy bound bowed bowel
bower bowls boxed boxer boxes brace braid brain brake brand brass brats brave bravo brawl brawn
bread break breed bribe brick bride brief bring brink brisk broad broke brood brook broom broth
brown brunt brush brute bucks buddy budge buggy bugle build built bulbs bulge bulky bulls bully
bumps bumpy bunch bunny burns burnt burps burst buses busts butch buyer cabal cabin cable cache
cadet cafes caged cages cakes calls calms camel camps canal candy canoe canon caper cards cared
cares cargo carol carry carts carve cases caste casts catch cater cause caved caves cease cedar
cello cells cents chain chair chalk champ chant chaos chaps charm chart chase chasm chats cheap
cheat check cheek cheer chefs chess chest chews chewy chick chief child chili chill chime chimp
china chino chips chirp choir choke chops chord chore chose chuck chump chunk chute cider cigar
cinch cited civic civil clack claim clamp clams clang clank clans claps clash clasp class claws
clean clear clerk click cliff climb cling clink clips cloak clock clogs clone close cloth cloud
clout clown clubs cluck clues clung coach coals coast coats cobra cocks cocky cocoa coded codes
coils coins cokes colds colon color combo combs comer comes comet comfy comic comma condo conga
cooks cools coral cords corny corps costs couch cough could count coupe court coven cover covet
crabs crack craft cramp crane crank craps crash crass crate crave crawl craze crazy creak cream
creed creek creep creme crepe crept crest crews crick cried cries crime crisp croak crock croft
crook crops cross crowd crown crows crude cruel crumb crush crust crypt cubes cubic cuffs cupid
cuppa cured cures curls curly curry curse curve cushy cuter cutie cycle cynic daddy daffy daily
dairy daisy dames dance dandy dared dares darts dated dates dazed deals dealt dears death debit
debts debut decay decks decor decoy deity delay delta demon denim dense depth derby desks deter
deuce devil dials diary diets dimes dined diner dingo dinky dirty disco disks ditch ditto dived
diver dives dizzy docks dodge dodgy doggy doing dolls dolly donor doors dopey dorms doses dotty
doubt dough douse doves downs dowry dozed dozen draft drags drain drake drama drank drape drawn
draws dread dream dress dried dries drift drill drink drips drive drone drool drops drove drown
drugs druid drums drunk dryer ducks ducky ducts dudes dukes dummy dumps dunes dunno duped dusty
dutch duvet dwarf dwell dying eager eagle early earns earth eaten eater ebony edema edges edict
eerie eight eject elbow elder elect elite elope elves email emery empty ended enema enemy enjoy
enter entry envoy equal erase erect error erupt essay ester ether ethic euros evade event every
evict evils exact exams excel exert exile exist exits expel extra fable faced faces facts faded
fades fails faint fairy faith faked fakes falls false famed fancy fangs fanny farce fares farms
farts fatal fated fates fatso fatty fault favor faxed fears feast feats feces feeds feels fella
felon femur fence feral ferry fetal fetch fetus fever fewer fiber field fiend fiery fifth fifty
fight filed files filet fills filly films filth final finch finds fined finer fines fired fires
firms first fishy fists fiver fives fixed fixer fixes flack flags flair flake flaky flame flank
flaps flare flash flask flats flaws fleas fleet flesh flick flier flies fling flint flips flirt
float flock flood floor flora floss flour flown flows fluff fluid fluke flung flunk flush flute
focal focus foggy folds folks folly foods fools force forge forks forms forte forty forum found
fours foxes foyer frail frame franc frank fraud freak freed frees fresh friar fried fries frisk
fritz frock frogs front frost frown froze fruit fryer fudge fuels fully fumes funds funky funny
furry fused fuses fussy fuzzy gabby gable gains games gamma gangs gases gasps gates gator gauge
gauze gavel gazed gears gecko geeks geese genes genie genre gents germs getup ghost ghoul giant
giddy gifts gills gimme girls girly given giver gives gizmo gland glare glass glaze gleam glide
gloat globe gloom glory gloss glove glows glued gnome goals goats going golly goner gonzo goods
goody gooey goofy goons goose gorge gouge gourd gowns grabs grace grade graft grail grain grams
grand grant grape graph grasp grass grate grave gravy graze great greed green greet grief grill
grind grips grits groan groin groom grope gross group grove growl grown grows grunt guard guess
guest guide guild guilt guise gulls gully gulps gumbo gummy gunny gusto gutsy habit hacks hairs
hairy halls hands handy hangs hanks happy hardy harem harms harry harsh haste hasty hatch hated
hater hates haunt haven havoc hawks hazel heads heals heaps heard hears heart heath heats heave
heavy hedge heels hefty heirs heist helix hello helps hence henna herbs herds hicks hides highs
hills hinge hints hippo hippy hired hires hitch hives hoard hobby hogan hoist holds holed holes
holly homer homes homey honey honks honor hooch hoods hooks hooky hoops hoots hoped hopes horde
horns horse hoses hosts hotel hound hours house hover howdy howls hubby huffs human humid humor
hunch hunts hurry hurts husky hutch hydra hyena hymns hyper icing icons ideal ideas idiot idols
image imply index inept inner intel inter intro irons irony isles issue itchy items ivory jacks
jails japan jazzy jeans jelly jenny jerks jerky jewel jiffy jihad jimmy jocks johns joins joint
joker jokes jolly judge juice juicy jumbo jumps jumpy juror kappa kaput karma kebab keeps kicks
kiddo kills kilos kinds kings kinks kinky kiosk kites kitty klutz knack knave kneel knees knife
knobs knock knots known knows koala kooky kraut kudos label labor laced laces lacks laden lager
laird lakes lambs lamps lance lands lanes lapse large largo laser lasso lasts latch later latex
laugh lawns layer leach leads leaks leaky leans leaps leapt learn lease leash least leave ledge
leech lefty legal legit lemon lemur lends leper level lever liars libel licks liege lifts light
liked likes lilac limbo limbs limit lined linen liner lines lingo links lions lists liter lived
liven liver lives livid llama loads loans lobby lobes local locks lodge lofty logic loins lolly
loner longs looks loony loops loose lords lorry loser loses lotto lotus louse lousy loved lover
loves lovey lower lowly loyal lucid lucky lumps lumpy lunar lunch lungs lupus lurch lured lurks
lying lynch lyric macho madam madly mafia magic magma maids mails major maker makes males malls
mamas mambo mamma mammy manga mango mangy mania manic manly manor manta maple march mares marge
maria marks marry marsh masks mason match mater mates matey maxim maybe mayor meals means meant
meats mecca medal media medic meets melon melts memos menus meows mercy merge merit merry messy
metal meter metro micro midge midst might miles milky mills mimic mince minds mined miner mines
minor mints minus miser misty mitts mixed mixer mixes moans mocha model mogul moist moldy moles
molly mommy money monks month moods moody moons moors moose moped moral moray moron morph motel
moths motif motor motto mound mount mourn mouse mouth moved mover moves movie mower mucus muddy
mules mummy mumps munch mural murky mushy music muted myths nacho nails naive naked named names
nanny nappy nasal nasty naval navel necks needs needy nerds nerdy nerve nests never newer newly
nexus nicer niche nicks niece nifty night nines ninja ninny ninth nitro noble nodes noise noisy
nomad noose north noses notch noted notes novel nudge nukes nurse nutty nylon nymph oasis obese
obeys occur ocean oddly offer often older oldie olive omega onion onset opens opera opium opted
optic orbit order organ other otter ought ounce outer ovens owing owned owner oxide ozone paces
packs paddy padre pagan paged pager pages pains paint pairs palms panda panel panic pansy pants
papal paper pappy parks parry parts party pasha pasta paste pasty patch paths patio patsy patty
pause paved pawns peace peach peaks pearl pears pecan pedal peeps penal pence penny perch peril
perks perky pesky pesos pests petal peter petty phase phone phony photo piano picks picky piece
piety piggy piled piles pills pilot pimps pinch pines pinto pints pious piper pipes pitch pivot
pixie pizza place plaid plain plait plane plank plans plant plate plays plaza plead pleas plots
pluck plugs plumb plume plump plums poems poets point poise poked poker pokey polar poles polio
polka polls ponds pooch pools poppa poppy porch pores porky ports posed poses posse posts potty
pouch pound pours power prank prawn prays press price pride prime print prior prism privy prize
probe prone proof props prose proud prove prowl proxy prude prune psych puffs puffy puked pulls
pulse pumps punch punks pupil puppy puree purge purse pushy putty quack quail quake quark quart
queen query quest queue quick quiet quill quilt quint quite quits quota quote rabbi rabid raced
racer races racks radar radio raged rages raids rails rains rainy raise rally ranch randy range
ranks rapid rated rates ratio ratty raven razor reach react reads ready realm rebel recap recon
reefs reeks reels refer regal reign relax relay relic renal renew rents repel rests retro rhino
rhyme rider rides ridge rifle right rigid rigor riled rinse riots risen rises risks risky rites
rival river roach roads roars roast robes robin robot rocks rocky rodeo roger rogue roles rolls
roman romeo roofs rooms roost roots roped roper ropes roses rouge rough round rouse route rover
rowan rowdy royal ruddy rugby ruins ruled ruler rules rumba rummy rumor runny rupee rural rusty
saber sable sacks sadly safer sahib sails saint salad sales sally salon salsa salts salty salve
salvo samba sands sandy sarge sassy satin sauce saucy sauna saved saver saves savor savoy savvy
scale scalp scamp scams scans scare scarf scars scary scene scent scoff scold scoop scoot scope
score scorn scour scout scram scrap screw scrub scuba seals seams sears seats sedan seeds seedy
seeks seems seine seize sells sends senor sense serge serum serve setup seven sever sewed sewer
sexes shack shade shady shaft shake shaky shall shalt shame shank shape shard share shark sharp
shave shawl sheds sheen sheep sheer sheet shelf shell shift shine shiny ships shirt shock shoes
shone shook shoot shops shore short shots shout shove shown shows shred shrew shush shuts sided
sides siege sieve sighs sight sigma signs silky silly since sings sinks sinus siren sissy sites
sixes sixth sixty sized sizes skate skies skill skins skips skirt skull skunk slack slain slams
slang slaps slash slate slave sleek sleep sleet slept slice slick slide slime slimy sling slips
slope sloth slots slows slugs slump slums slush smack small smart smash smear smell smelt smile
smirk smith smoke smoky snack snail snake snaps snare sneak sniff snoop snore snort snout snows
snowy snuff soaps soapy sober socks sodas soggy solar soles solid solos solve sonar songs sonic
sonny sores sorry sorts souls sound south space spade spank spare spark spasm spawn speak spear
speck specs speed spell spend spent spice spicy spied spies spike spill spine spins spite spits
splat split spoil spoke spook spoon sport spots spout spray spree spurs squad squat squid stabs
stack staff stage stain stair stake stale stalk stall stamp stand stank stare stark stars start
stash state stats stays stead steak steal steam steed steel steep steer stein stems steps stern
stick stiff still sting stink stint stirs stock stoke stole stomp stone stony stood stool stoop
stops store stork storm story stout stove strap straw stray strip strut stuck studs study stuff
stump stung stunt style suave sucks suede sugar suing suite suits sully sunny super surge surly
sushi swabs swain swami swamp swans swarm swear sweat swede sweep sweet swell swept swift swims
swine swing swipe swirl swish swoop sword swore sworn swung syrup table taboo tacky tacos taffy
tails taint taken taker takes tales talks tally talon tamed tango tanks taped tapes tardy tarot
tarts tasks taste tasty tater taunt taxes taxis teach teams tears tease teddy teens teeny tells
telly tempo temps tempt tends tenor tense tenth tents terms terry tests texts thane thank theft
their theme there these theta thick thief thigh thine thing think third thong thorn those three
threw throw thuds thugs thumb thump thyme tiara tibia ticks tidal tides tiger tight tiles timed
timer times timid tinny tipsy tired tires titan title toads toast today toddy token tolls tombs
tones tongs tonic tools tooth toots topic torch torso total totem touch tough tours towed towel
tower towns toxic toxin trace track tract trade trail train trait tramp trans traps trash trays
tread treat trees trend triad trial tribe trick tried tries tripe trips troll troop trout truce
truck truly trump trunk trust truth tubby tubes tulip tummy tumor tuned tunes tunic turbo turns
tusks tutor twain tweak tweed tweet twerp twice twigs twine twins twirl twist tying typed types
ulcer ultra uncle under undue unfit union unite unity until upped upper upset urban urged urges
urine usage users usher using usual utter vague valet valid valor value valve vapor vault vegan
veins venom vents venue verge versa verse vests vials vibes vicar vices video views vigil vigor
villa vines vinyl viola viper viral virus visas visit visor vista vital vivid vixen vocal vodka
vogue voice voila volts vomit voted voter votes vouch vowed wacky waged wager wages wagon wails
waist waits waive wakes wales walks walls wally waltz wants wards warms warns warts wasps waste
watch water watts waved waves waxed wears weary weave wedge weeds weeks weeps weigh weird wells
welsh wench whack whale wharf whats wheat wheel where which whiff while whims whine whiny whips
whirl whirs whisk white whole whoop whose widen wider widow width wield wills willy winch winds
windy wines wiped wipes wired wires wiser witch witty wives woman women woods woody woozy words
wordy works world worms worry worse worst worth would wound woven wraps wrath wreak wreck wring
wrist write wrong wrote yacht yahoo yanks yards yawns yearn years yeast yells yelps yield yikes
young yours youth yummy zebra zeros zilch zones
$words$), '\s+') as w);

commit;
