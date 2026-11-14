# anglistycznie.pl – strona + aplikacja Zadanko English

Ten plik czyta Claude przed pracą w repozytorium. Aktualizuj go, gdy zmieniasz architekturę.

## Co to jest
- **Strona** Angeliki Wiktorskiej („Anglistycznie z Angie”), lektorki angielskiego: blog, darmowe materiały PDF, sklep, o mnie, kontakt. Adres: **https://anglistycznie.pl**.
- **Aplikacja „Zadanko English”** dla jej uczniów: **https://anglistycznie.pl/aplikacja/**, panel nauczyciela pod `/aplikacja/#nauczyciel`. Trzy moduły:
  1. **Kartkówki**: słówka, zdania z luką, wybór. Każdy uczeń dostaje do wspólnej kartkówki swoje osobiste powtórki (domyślnie 5 słówek).
  2. **Ćwiczenie 2 min** po kartkówce, ułożone przez AI z błędów ucznia.
  3. **Daily Sentences**: tydzień wyrażeń B2 (FCE). Uczeń pisze po jednym zdaniu, AI sprawdza, można poprawić 2 razy.
- Właściciele: Angelika Wiktorska (nauczycielka, prowadzi stronę) i Emil Wiktorski (pomoc techniczna). Język komunikacji: **polski**.
- Repozytorium jest na koncie GitHub **angwiktorska** i tam zostaje. Angelika pracuje na swoim Claude i swoim GitHubie: Claude robi zmiany na gałęzi i otwiera pull request, Angelika klika Merge.

## Struktura repozytorium (GitHub Pages, gałąź `main`, katalog główny)
```
index.html             strona (jeden plik; treści na górze w window.STRONA, O_MNIE, WPISY, MATERIALY, PRODUKTY)
img/                   logo.png, logo-jasne.png, farm-animals.jpg (+ okładki dodawane przez właścicieli)
materialy/             darmowe PDF-y (linkowane z MATERIALY[].plik)
aplikacja/index.html   aplikacja (jeden plik, vanilla JS, bez kroku budowania)
CNAME                  "anglistycznie.pl" – NIE USUWAĆ (własna domena GitHub Pages)
supabase/schema.sql    cała baza: tabele + funkcje RPC (idempotentny skrypt)
supabase/ai-function.ts  Supabase Edge Function "ai" (Deno)
CLAUDE.md              ten plik
```
Wersja `index.html` w repozytorium (tytuł „Anglistycznie Premium”) jest źródłem prawdy. Właściciele edytowali ją ręcznie, np. dodali linki do FB i IG. Nie nadpisuj jej starszymi szablonami.

## Jak wdrażają się zmiany
- **Strona i aplikacja** (`index.html`, `aplikacja/`, `img/`): po scaleniu PR do `main` GitHub Pages publikuje zmiany w 1–2 minuty. Nic więcej nie trzeba robić.
- **`supabase/schema.sql`** NIE wdraża się sam. Po scaleniu właściciel wkleja cały plik w Supabase → SQL Editor → Run. Skrypt musi zostać **idempotentny**: `create table if not exists`, `alter table … add column if not exists`, `create or replace function`, nigdy `drop` na danych. Wywołuj go w całości.
- **`supabase/ai-function.ts`** NIE wdraża się sam. Właściciel wkleja go w Supabase → Edge Functions → `ai` → Code → Deploy. Uwaga: Windows otwiera pliki `.ts` jak wideo, więc dawaj właścicielowi kopię `.txt` albo każ otworzyć plik na GitHubie i użyć „Copy raw file”.
- W opisie każdego PR, który zmienia `supabase/`, napisz wprost: „Po scaleniu: uruchom schema.sql / wdroż funkcję ai”.

## Backend: Supabase
- Projekt: `https://fwudxfobvccoerjmwezp.supabase.co`. Klucz **publishable** (`sb_publishable_…`) jest w `aplikacja/index.html` w `window.CONFIG`. Jest publiczny z założenia, więc może być w repozytorium.
- **Żadnych tajnych kluczy w repozytorium.** `ANTHROPIC_API_KEY` siedzi tylko w Supabase → Edge Functions → Secrets.
- Bezpieczeństwo: wszystkie tabele mają RLS bez polityk i `revoke all` dla anon/authenticated. Dostęp idzie **wyłącznie przez funkcje RPC `security definer`** (`set search_path = public`).
  - Nauczyciel: konto Supabase Auth (e-mail i hasło). `claim_teacher()`: pierwsze konto zostaje nauczycielem. Funkcje `t_*` wołają `_need_teacher()`.
  - Uczeń: login i 4-cyfrowy PIN (`student_login` zwraca token sesji z `student_sessions`, ważny 60 dni). Funkcje ucznia biorą `p_token` i wołają `_sid()`. Po 8 złych PIN-ach blokada na 15 minut. PIN jest zapisany jako hash (`pin_hash`) i jako jawny `pin`, który widzi tylko nauczyciel.
  - Funkcje tylko dla `service_role` (woła je funkcja AI): `practice_store`, `sent_store`.
- Główne tabele: `teachers`, `students`, `student_sessions`, `quizzes`, `attempts`, `word_stats` (to_repeat: błąd +1, poprawna odpowiedź −1), `practices`, `sentence_weeks`, `sentence_attempts`, `sentence_progress`.
- Ocena kartkówki odbywa się po stronie serwera (`_check`, `_norm`: wielkość liter, interpunkcja, `don't` = `do not`; przy słówkach `to`, `a`, `the` są opcjonalne). Odpowiedzi nigdy nie trafiają do przeglądarki przed oddaniem.

## Funkcja AI (`supabase/ai-function.ts`)
- Model: `claude-haiku-5-5` (zmiana przez secret `CLAUDE_MODEL`). Koszt to ułamki grosza za wywołanie.
- W Supabase **„Verify JWT” jest wyłączone**, bo uczniowie nie mają JWT. Funkcja sama sprawdza uprawnienia: token ucznia przez RPC, nauczyciela przez `t_ping`.
- Akcje (`POST /functions/v1/ai`, body `{action, …}`):
  - `practice`: ćwiczenie 2 min z błędów kartkówki (`practice_begin` → Claude → `practice_store`),
  - `quiz`: zadania do kartkówki dla nauczyciela (format linii, patrz niżej),
  - `sentence`: sprawdzenie zdania w Daily Sentences (`sent_check_begin` → Claude → `sent_store`). Zwraca JSON `{verdict: correct|almost|needs work, corrected, feedback, error_types[], tip}`, walidowany przed zapisem,
  - `week`: treść tygodnia Daily Sentences dla nauczyciela.
- Klucz `service_role`: `SUPABASE_SECRET_KEYS` / `SUPABASE_SERVICE_ROLE_KEY` (Supabase podaje je funkcji sam), a zapasowo secret `ZADANKO_SECRET_KEY`.

## Formaty treści (wpisywane przez nauczyciela)
- **Kartkówka** (jedno zadanie w linii): `pies = dog / doggy`, `She ___ (go) to school. = goes # wyjaśnienie`, `Look! It ___ . = is snowing [snows | is snowing | snow]`.
- **Daily Sentences**: nazwa dnia (`Monday` albo po polsku), pod nią `wyrażenie | typ | definicja EN | po polsku | zdanie wzorcowe | revisit?`. Działa też JSON `{week, days:[{day, items:[{phrase,type,definition,polish,model,status}]}]}`.

## Konwencje kodu
- Jeden plik HTML na stronę/aplikację, vanilla JS (ES5-style, `var`), bez frameworków i bez budowania. Biblioteki tylko z CDN z przypiętą wersją (np. `qrcode-generator@1.4.4` z cdnjs).
- Każdy tekst od użytkownika przepuszczaj przez `esc()` przed wstawieniem do HTML.
- UI po polsku. Wyjątek: część ucznia w Daily Sentences jest po angielsku (z krótkimi podpowiedziami PL).
- Aplikacja: tokeny kolorów w `:root` + `prefers-color-scheme: dark`. Strona: jeden jasny motyw (róż, śliwka, czerwony londyński autobus). Fonty z Google Fonts.
- Mobile-first: uczniowie korzystają z telefonów (kody QR w panelu nauczyciela).
- Routing przez `location.hash` (`#nauczyciel`, `#kartkowka-<uuid>`, na stronie `#blog`, `#wpis-<slug>` itd.).

## Domena i DNS
- `anglistycznie.pl` kupiona w **seohost.pl** (rejestrujący: Emil Wiktorski), ważna do 11.11.2027. Zmiany DNS robi Emil na swoim koncie seohost. Projekt Supabase też prowadzi Emil, więc zmiany z folderu `supabase/` wkleja on albo Angelika, jeśli ma dostęp.
- Delegacja: `dns1.microhost.pl`, `dns2.microhost.pl`. Strefa DNS w panelu seohost → DNS:
  - A `@` → `185.199.108.153`, `185.199.109.153`, `185.199.110.153`, `185.199.111.153` (GitHub Pages),
  - CNAME `www` → `angwiktorska.github.io`,
  - rekordów MX i TXT nie ruszać.
- GitHub → Settings → Pages: Custom domain `anglistycznie.pl` + **Enforce HTTPS**.
- Stara domena `anglistycznie.com` była w Wix (nieaktywna, ignorować).

## Rzeczy otwarte / do zrobienia
- Strona: pełne treści starych wpisów (z web.archive.org), PDF „Tenses revision” w `materialy/`, e-mail kontaktowy, regulamin i polityka prywatności (sklep), linki płatności (Stripe Payment Links albo Payhip z podpiętym Stripe).
- Aplikacja przeniesiona z `<login>.github.io/angielski/` na `/aplikacja/`: uczniowie muszą raz zalogować się ponownie, a kartki z loginami trzeba wydrukować na nowo.
- Konta uczniów założone przed zapisem jawnego PIN-u pokazują „brak · nadaj nowy”, co jest poprawnym zachowaniem.

## Testowanie (zalecane przed PR zmieniającym logikę)
Brak testów w repozytorium. Sprawdzony sposób:
- **SQL**: `@electric-sql/pglite` z `pgcrypto`, z atrapami `auth.uid()` (z `request.jwt.claim.sub`) i rolami `anon`, `authenticated`, `service_role`. Wczytaj `schema.sql` i wołaj RPC.
- **E2E**: Playwright przechwytuje `https://<projekt>.supabase.co/**` i przekazuje do mostka HTTP nad pglite. Funkcja AI uruchomiona lokalnie w Deno (`ANTHROPIC_BASE_URL` wskazuje atrapę Claude).
- Zawsze sprawdź `node --check` na wyciągniętym `<script>` i widok na telefonie (390 px).
