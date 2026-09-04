# Calendário do Canvas — Plano de Implementação

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Aba Calendário no Hub de Estudos: cada aluno cola a URL do feed do Canvas, o hub importa os eventos (calendário pessoal), mostra a grade do mês, oferece botões Google/Outlook/Apple por evento e um link de assinatura `.ics` que os apps acompanham sozinhos.

**Architecture:** Duas tabelas e sete funções RPC novas em `supabase/schema.sql` (calendário pessoal por usuário, RLS por dono). Uma Edge Function `calendario` (Deno/TypeScript, arquivo único) com duas rotas: `POST /importar` (logado; baixa o feed do Canvas no servidor, interpreta o `.ics` e grava via RPC) e `GET /feed?token=…` (pública; devolve o calendário do usuário em `text/calendar`). Uma página `calendario.html` em HTML/JS puro que só chama RPC e a função.

**Tech Stack:** Postgres/Supabase (RLS, plpgsql), Supabase Edge Functions (Deno 2, `npm:@supabase/supabase-js@2`), HTML/CSS/JS puro, `deno test` para a função, Postgres 17 local (`supabase/teste/rodar.sh`) para o SQL.

**Spec:** `docs/superpowers/specs/2026-09-04-calendario-canvas-design.md`

## Global Constraints

- Sem React, framework, bundler ou npm no front. Páginas sem `<style>` nem `style=""`; cores só via `tema.css`; layout só em `css/site.css`. Ordem de scripts em toda página: CDN supabase-js, `js/config.js`, `js/util.js`, `js/supabase.js`, `js/sessao.js`, (`js/ics.js` quando a página usa), script da página.
- O front só usa `chamar('<rpc>', params)`, `chamarFuncao(rota, opcoes)`, `db.auth.*` e `db.storage.*`. Nunca consulta tabela.
- `supabase/schema.sql` continua re-executável; o bloco novo entra depois de `-- ---------- RPC de escrita ----------` e **antes** de `-- ---------- seed ----------`. Mensagens de erro do banco em português via `raise exception`.
- Calendário é pessoal: RLS de `calendario_config` e `eventos` só permite `perfil_id = auth.uid()` para `authenticated`; `anon` nada.
- `eventos_por_token` é `security definer` e só `service_role` executa.
- Padrão da URL do feed: `^https://[a-z0-9.-]+\.instructure\.com/feeds/calendars/[A-Za-z0-9_.-]+\.ics$`. Token do feed: 32 caracteres hex (`encode(extensions.gen_random_bytes(16), 'hex')`).
- Edge Function em arquivo único `supabase/functions/calendario/index.ts`, exportando as funções puras e `tratar`; `Deno.serve(tratar)` só quando a variável de ambiente `HUB_TESTE` não está definida. Testes: `HUB_TESTE=1 deno test --allow-env supabase/functions/calendario/`.
- Limites: feed até 5 MB e 20 s; título 1–300, descrição ≤ 4000, `ultimo_erro` ≤ 500.
- Textos da interface em português do Brasil. Commits na `main` (escolha do Lucas), mensagem curta no imperativo em português, terminando com `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. Nunca commitar `.superpowers/` nem `.DS_Store`.
- `tema.css`, `vendor/` e o restante do backend existente não mudam.

---

## Estrutura de arquivos

| Arquivo | Responsabilidade |
|---|---|
| `supabase/schema.sql` | + bloco `-- ---------- Calendário ----------`: tabelas, RLS, RPCs |
| `supabase/teste/teste.sql` | + cenários do calendário |
| `supabase/functions/calendario/index.ts` | Edge Function: parser/gerador `.ics` e rotas |
| `supabase/functions/calendario/index_test.ts` | testes Deno das funções puras e do roteamento |
| `js/supabase.js` | + `chamarFuncao(rota, opcoes)` e `urlFuncao(rota)` |
| `js/sessao.js` | + link "Calendário" no cabeçalho quando logado |
| `js/ics.js` | helpers puros: datas para Google/Outlook, `.ics` de um evento, formatação |
| `css/site.css` | + classes da grade e da lista |
| `calendario.html` | página nova |
| `README.md` | + seção do calendário e deploy da função |

---

### Task 1: Banco — tabelas, RLS e RPCs de configuração

**Files:**
- Modify: `supabase/schema.sql` (inserir bloco antes do seed)
- Modify: `supabase/teste/teste.sql` (acrescentar ao fim)

**Interfaces:**
- Consumes: `perfis`, `exigir_login()`, extensão `pgcrypto` em `extensions` (o stub local já a cria; o Supabase já a tem).
- Produces: tabelas `calendario_config(perfil_id, feed_url, token_feed, ultima_importacao, ultimo_erro, atualizado_em)` e `eventos(id, perfil_id, uid, titulo, descricao, inicio, fim, dia_inteiro, url, curso_codigo, curso_nome, atualizado_em)`; RPCs `calendario_config_minha() returns json` → `{feed_url, token_feed, ultima_importacao, ultimo_erro, total_eventos}`, `salvar_feed_url(url text) returns void`, `registrar_erro_importacao(msg text) returns void`, `novo_token_feed() returns text`.

- [ ] **Step 1: Escrever os testes**

Acrescente ao fim de `supabase/teste/teste.sql`:

```sql
-- ---------- Calendário: config e feed ----------
select teste.entrar('11111111-1111-1111-1111-111111111111');
set local role authenticated;
do $$
declare c json; c2 json; t1 text; t2 text;
begin
  c := calendario_config_minha();
  perform teste.confere((c ->> 'feed_url') is null and length(c ->> 'token_feed') = 32 and (c ->> 'total_eventos') = '0', 'config criada na primeira chamada');
  c2 := calendario_config_minha();
  perform teste.confere((c ->> 'token_feed') = (c2 ->> 'token_feed'), 'segunda chamada reaproveita o token');
  perform teste.espera_erro('select salvar_feed_url(''https://exemplo.com/x.ics'')', 'URL fora do Canvas é recusada');
  perform teste.espera_erro('select salvar_feed_url(''javascript:alert(1)'')', 'URL com esquema inválido é recusada');
  perform teste.espera_erro('select salvar_feed_url(''https://pucminas.instructure.com/feeds/calendars/user_abc.ics?x=1'')', 'URL com query é recusada');
  perform salvar_feed_url('  https://pucminas.instructure.com/feeds/calendars/user_abc123.ics  ');
  perform teste.confere((calendario_config_minha() ->> 'feed_url') = 'https://pucminas.instructure.com/feeds/calendars/user_abc123.ics', 'feed_url salva e aparada');
  perform registrar_erro_importacao(repeat('e', 600));
  perform teste.confere(length(calendario_config_minha() ->> 'ultimo_erro') = 500, 'erro cortado em 500');
  perform salvar_feed_url('https://pucminas.instructure.com/feeds/calendars/user_abc123.ics');
  perform teste.confere((calendario_config_minha() ->> 'ultimo_erro') is null, 'salvar feed limpa o erro');
  t1 := calendario_config_minha() ->> 'token_feed';
  t2 := novo_token_feed();
  perform teste.confere(t2 <> t1 and length(t2) = 32 and (calendario_config_minha() ->> 'token_feed') = t2, 'novo token substitui o antigo');
end $$;
reset role;

select teste.entrar('22222222-2222-2222-2222-222222222222');
set local role authenticated;
select teste.confere((select count(*) from calendario_config) = 0, 'outro usuário não vê config alheia');
select teste.confere(length(calendario_config_minha() ->> 'token_feed') = 32, 'cada usuário tem a própria config');
select teste.confere((select count(*) from calendario_config) = 1, 'e só enxerga a sua');
-- RLS filtra o update para 0 linhas sem erro; o confere depois do reset role prova que nada mudou
update calendario_config set feed_url = 'https://x.instructure.com/feeds/calendars/a.ics' where perfil_id = '11111111-1111-1111-1111-111111111111';
reset role;
select teste.confere((select feed_url from calendario_config where perfil_id = '11111111-1111-1111-1111-111111111111') = 'https://pucminas.instructure.com/feeds/calendars/user_abc123.ics', 'config da aluna intacta');

select teste.entrar(null);
set local role anon;
select teste.espera_erro($$select calendario_config_minha()$$, 'anônimo não tem config');
select teste.confere((select count(*) from calendario_config) = 0, 'anônimo não lê config');
reset role;
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `supabase/teste/rodar.sh`
Expected: falha com `function calendario_config_minha() does not exist`.

- [ ] **Step 3: Escrever tabelas, RLS e RPCs de configuração**

Insira em `supabase/schema.sql` **antes** de `-- ---------- seed ----------` (depois do bloco de RPC de escrita):

```sql
-- ---------- Calendário do Canvas ----------
-- Calendário pessoal: cada usuário importa o próprio feed do Canvas e só ele vê.
create table if not exists calendario_config (
  perfil_id uuid primary key references perfis(id) on delete cascade,
  feed_url text,                                   -- URL pessoal do Canvas (segredo do dono)
  token_feed text not null unique default encode(extensions.gen_random_bytes(16), 'hex'),
  ultima_importacao timestamptz,
  ultimo_erro text,
  atualizado_em timestamptz not null default now()
);

create table if not exists eventos (
  id bigint generated always as identity primary key,
  perfil_id uuid not null references perfis(id) on delete cascade,
  uid text not null,
  titulo text not null check (length(titulo) between 1 and 300),
  descricao text not null default '' check (length(descricao) <= 4000),
  inicio timestamptz not null,
  fim timestamptz,
  dia_inteiro boolean not null default false,
  url text check (url is null or url ~ '^https://'),
  curso_codigo text,
  curso_nome text,
  atualizado_em timestamptz not null default now(),
  unique (perfil_id, uid)
);

alter table calendario_config enable row level security;
alter table eventos enable row level security;
do $$ declare p record; begin
  for p in select policyname, tablename from pg_policies
           where schemaname = 'public' and tablename in ('calendario_config', 'eventos')
  loop execute format('drop policy %I on public.%I', p.policyname, p.tablename); end loop;
end $$;
create policy calendario_config_proprio on calendario_config for all to authenticated
  using (perfil_id = auth.uid()) with check (perfil_id = auth.uid());
create policy eventos_proprios on eventos for all to authenticated
  using (perfil_id = auth.uid()) with check (perfil_id = auth.uid());

-- Cria a config do usuário na primeira visita e devolve o estado.
create or replace function calendario_config_minha()
returns json language plpgsql set search_path = public as $$
declare c calendario_config; total int;
begin
  perform exigir_login();
  insert into calendario_config (perfil_id) values (auth.uid()) on conflict (perfil_id) do nothing;
  select * into c from calendario_config where perfil_id = auth.uid();
  select count(*) into total from eventos where perfil_id = auth.uid();
  return json_build_object(
    'feed_url', c.feed_url, 'token_feed', c.token_feed, 'ultima_importacao', c.ultima_importacao,
    'ultimo_erro', c.ultimo_erro, 'total_eventos', total);
end $$;

create or replace function salvar_feed_url(url text)
returns void language plpgsql set search_path = public as $$
begin
  perform exigir_login();
  if coalesce(btrim(url), '') !~ '^https://[a-z0-9.-]+\.instructure\.com/feeds/calendars/[A-Za-z0-9_.-]+\.ics$' then
    raise exception 'URL do feed inválida: cole o link do calendário do Canvas';
  end if;
  insert into calendario_config (perfil_id, feed_url, ultimo_erro, atualizado_em)
  values (auth.uid(), btrim(url), null, now())
  on conflict (perfil_id) do update set feed_url = excluded.feed_url, ultimo_erro = null, atualizado_em = now();
end $$;

create or replace function registrar_erro_importacao(msg text)
returns void language plpgsql set search_path = public as $$
begin
  perform exigir_login();
  insert into calendario_config (perfil_id, ultimo_erro, atualizado_em)
  values (auth.uid(), left(coalesce(msg, 'Erro desconhecido'), 500), now())
  on conflict (perfil_id) do update set ultimo_erro = excluded.ultimo_erro, atualizado_em = now();
end $$;

create or replace function novo_token_feed()
returns text language plpgsql set search_path = public as $$
declare t text;
begin
  perform exigir_login();
  perform calendario_config_minha();
  update calendario_config set token_feed = encode(extensions.gen_random_bytes(16), 'hex'), atualizado_em = now()
  where perfil_id = auth.uid() returning token_feed into t;
  return t;
end $$;
```

- [ ] **Step 4: Rodar e ver passar**

Run: `supabase/teste/rodar.sh`
Expected: `OK: schema.sql e teste.sql passaram`. Se falhar em `extensions.gen_random_bytes`, confirme que `supabase/teste/stub.sql` cria `pgcrypto` no schema `extensions` (cria) e que o role `authenticated` tem `execute` nas funções desse schema (o stub concede).

- [ ] **Step 5: Commit**

```bash
git add supabase/ && git commit -m "Calendário: tabelas, RLS e RPCs de configuração do feed

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

### Task 2: Banco — importar, listar e feed por token

**Files:**
- Modify: `supabase/schema.sql` (acrescentar ao bloco Calendário, antes do seed)
- Modify: `supabase/teste/teste.sql`

**Interfaces:**
- Consumes: tabelas e RPCs da Tarefa 1; `exigir_login()`.
- Produces: `importar_eventos(eventos json) returns integer`; `listar_eventos(de timestamptz, ate timestamptz) returns setof json` (itens `{id, uid, titulo, descricao, inicio, fim, dia_inteiro, url, curso_codigo, curso_nome}`); `eventos_por_token(token text) returns json` → `{nome, eventos: [{uid, titulo, descricao, inicio, fim, dia_inteiro, url, curso_codigo, curso_nome}]}` ou `null`, executável só por `service_role`.
- Formato aceito por `importar_eventos`: array de objetos `{uid, titulo, descricao, inicio, fim, dia_inteiro, url, curso_codigo, curso_nome}`; campos ausentes viram nulo/padrão.

- [ ] **Step 1: Escrever os testes**

Acrescente ao fim de `supabase/teste/teste.sql`:

```sql
-- ---------- Calendário: importar, listar, token ----------
select teste.entrar('11111111-1111-1111-1111-111111111111');
set local role authenticated;
do $$
declare n int;
begin
  perform teste.espera_erro('select importar_eventos(''{"a":1}''::json)', 'importar recusa objeto');
  perform teste.espera_erro('select importar_eventos(null::json)', 'importar recusa nulo');
  n := importar_eventos('[
    {"uid":"e1","titulo":"Prova 1","descricao":"d","inicio":"2026-09-10T10:00:00Z","fim":null,"dia_inteiro":false,"url":"https://pucminas.instructure.com/x","curso_codigo":"6166100","curso_nome":"Cálculo II"},
    {"uid":"e2","titulo":"Dia inteiro","descricao":"","inicio":"2026-09-12T00:00:00Z","fim":null,"dia_inteiro":true,"url":null,"curso_codigo":null,"curso_nome":null},
    {"uid":"e3","titulo":"Aula","descricao":"","inicio":"2026-10-01T12:00:00Z","fim":"2026-10-01T13:40:00Z","dia_inteiro":false,"url":"http://inseguro","curso_codigo":"","curso_nome":" "},
    {"uid":"e1","titulo":"Prova 1 (versão nova)","descricao":"","inicio":"2026-09-11T10:00:00Z","fim":"2026-09-11T09:00:00Z","dia_inteiro":false,"url":null,"curso_codigo":"6166100","curso_nome":"Cálculo II"},
    {"uid":"","titulo":"Sem uid","inicio":"2026-09-11T10:00:00Z"},
    {"uid":"e5","titulo":"Sem início"}
  ]'::json);
  perform teste.confere(n = 3, 'importa 3: uid repetido vence o último; sem uid ou sem início são ignorados');
  perform teste.confere((select titulo from eventos where uid = 'e1') = 'Prova 1 (versão nova)', 'último uid vence');
  perform teste.confere((select fim from eventos where uid = 'e1') is null, 'fim anterior ao início vira nulo');
  perform teste.confere((select url from eventos where uid = 'e3') is null, 'url http vira nula');
  perform teste.confere((select curso_codigo from eventos where uid = 'e3') is null and (select curso_nome from eventos where uid = 'e3') is null, 'curso vazio vira nulo');
  perform teste.confere((select fim from eventos where uid = 'e3') = '2026-10-01T13:40:00Z'::timestamptz, 'fim preservado');
  perform teste.confere((select dia_inteiro from eventos where uid = 'e2'), 'dia inteiro preservado');
  perform teste.confere((calendario_config_minha() ->> 'total_eventos') = '3' and (calendario_config_minha() ->> 'ultima_importacao') is not null, 'config registra a importação');
  perform teste.confere((select count(*) from listar_eventos('2026-09-01T00:00:00Z', '2026-10-01T00:00:00Z')) = 2, 'listar respeita o intervalo');
  perform teste.confere((select j ->> 'uid' from listar_eventos('2026-09-01T00:00:00Z', '2026-12-31T00:00:00Z') j limit 1) = 'e1', 'listar ordena por início');
  perform teste.confere((select j ->> 'curso_nome' from listar_eventos('2026-09-01T00:00:00Z', '2026-09-30T00:00:00Z') j limit 1) = 'Cálculo II', 'listar traz o curso');
  n := importar_eventos(('[{"uid":"e9","titulo":"' || repeat('x', 400) || '","inicio":"2026-11-01T10:00:00Z"}]')::json);
  perform teste.confere(n = 1 and (select count(*) from eventos) = 1, 'reimportar substitui tudo');
  perform teste.confere((select length(titulo) from eventos where uid = 'e9') = 300, 'título cortado em 300');
  n := importar_eventos('[{"uid":"e10","titulo":"   ","inicio":"2026-11-02T10:00:00Z","descricao":null}]'::json);
  perform teste.confere((select titulo from eventos where uid = 'e10') = '(sem título)' and (select descricao from eventos where uid = 'e10') = '', 'título vazio vira (sem título) e descrição nula vira vazia');
  n := importar_eventos('[]'::json);
  perform teste.confere(n = 0 and (select count(*) from eventos) = 0, 'array vazio limpa tudo');
  n := importar_eventos('[{"uid":"e1","titulo":"Prova 1","inicio":"2026-09-10T10:00:00Z","curso_nome":"Cálculo II"}]'::json);
  perform teste.espera_erro('select eventos_por_token(''' || (calendario_config_minha() ->> 'token_feed') || ''')', 'authenticated não executa eventos_por_token');
end $$;
reset role;

select teste.entrar('22222222-2222-2222-2222-222222222222');
set local role authenticated;
select teste.confere((select count(*) from eventos) = 0, 'outro usuário não vê eventos alheios');
select teste.confere((select count(*) from listar_eventos('2026-01-01', '2027-01-01')) = 0, 'listar só os próprios');
reset role;

select teste.entrar(null);
set local role anon;
select teste.espera_erro($$select eventos_por_token('00000000000000000000000000000000')$$, 'anon não executa eventos_por_token');
select teste.espera_erro($$select * from listar_eventos('2026-01-01', '2027-01-01')$$, 'anônimo não lista');
reset role;

set local role service_role;
select teste.confere(eventos_por_token('00000000000000000000000000000000') is null, 'token desconhecido devolve null');
select teste.confere(eventos_por_token('curto') is null, 'token com tamanho errado devolve null');
select teste.confere(
  (eventos_por_token((select token_feed from calendario_config where perfil_id = '11111111-1111-1111-1111-111111111111')) ->> 'nome') = 'Ana Silva'
  and json_array_length(eventos_por_token((select token_feed from calendario_config where perfil_id = '11111111-1111-1111-1111-111111111111')) -> 'eventos') = 1,
  'service_role lê nome e eventos pelo token');
reset role;
```

(`Ana Silva` é o nome que a Tarefa 5 do plano anterior deixou para a aluna `1111…` via `atualizar_nome`; se o teste falhar nesse ponto, confira com `select nome from perfis where id = '1111…'` e ajuste a string.)

- [ ] **Step 2: Rodar e ver falhar**

Run: `supabase/teste/rodar.sh`
Expected: falha com `function importar_eventos(json) does not exist`.

- [ ] **Step 3: Escrever as funções**

Acrescente ao bloco `-- ---------- Calendário do Canvas ----------` (ainda antes do seed):

```sql
-- Substitui todos os eventos do usuário pelos recebidos (o feed do Canvas é a fonte da verdade).
create or replace function importar_eventos(eventos json)
returns integer language plpgsql set search_path = public as $$
#variable_conflict use_variable
declare n integer;
begin
  perform exigir_login();
  if eventos is null or json_typeof(eventos) <> 'array' then raise exception 'Formato inválido: esperado um array de eventos'; end if;
  delete from public.eventos where perfil_id = auth.uid();
  with itens as (
    select r.*, o.ord
    from json_array_elements(eventos) with ordinality as o(item, ord),
         json_to_record(o.item) as r(uid text, titulo text, descricao text, inicio timestamptz, fim timestamptz,
                                     dia_inteiro boolean, url text, curso_codigo text, curso_nome text)
    where coalesce(btrim(o.item ->> 'uid'), '') <> '' and o.item ->> 'inicio' is not null
  ),
  ultimos as (
    select distinct on (uid) * from itens order by uid, ord desc
  )
  insert into public.eventos (perfil_id, uid, titulo, descricao, inicio, fim, dia_inteiro, url, curso_codigo, curso_nome)
  select auth.uid(), btrim(uid),
         left(coalesce(nullif(btrim(titulo), ''), '(sem título)'), 300),
         left(coalesce(descricao, ''), 4000),
         inicio,
         case when fim is null or fim <= inicio then null else fim end,
         coalesce(dia_inteiro, false),
         case when url ~ '^https://' then url else null end,
         nullif(btrim(curso_codigo), ''),
         nullif(btrim(curso_nome), '')
  from ultimos;
  get diagnostics n = row_count;
  update calendario_config set ultima_importacao = now(), ultimo_erro = null, atualizado_em = now() where perfil_id = auth.uid();
  if not found then insert into calendario_config (perfil_id, ultima_importacao) values (auth.uid(), now()); end if;
  return n;
end $$;

create or replace function listar_eventos(de timestamptz, ate timestamptz)
returns setof json language plpgsql stable set search_path = public as $$
begin
  perform exigir_login();
  return query
    select json_build_object('id', e.id, 'uid', e.uid, 'titulo', e.titulo, 'descricao', e.descricao,
                             'inicio', e.inicio, 'fim', e.fim, 'dia_inteiro', e.dia_inteiro, 'url', e.url,
                             'curso_codigo', e.curso_codigo, 'curso_nome', e.curso_nome)
    from eventos e
    where e.perfil_id = auth.uid() and e.inicio >= de and e.inicio < ate
    order by e.inicio, e.id;
end $$;

-- Rota pública do feed: o token é o segredo. Só a chave de serviço (dentro da Edge Function) chama.
create or replace function eventos_por_token(token text)
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'nome', p.nome,
    'eventos', coalesce((
      select json_agg(json_build_object('uid', e.uid, 'titulo', e.titulo, 'descricao', e.descricao,
                                        'inicio', e.inicio, 'fim', e.fim, 'dia_inteiro', e.dia_inteiro, 'url', e.url,
                                        'curso_codigo', e.curso_codigo, 'curso_nome', e.curso_nome)
                      order by e.inicio, e.id)
      from eventos e where e.perfil_id = c.perfil_id), '[]'::json))
  from calendario_config c
  join perfis p on p.id = c.perfil_id
  where length(token) = 32 and c.token_feed = token;
$$;
revoke execute on function eventos_por_token(text) from public, anon, authenticated;
grant execute on function eventos_por_token(text) to service_role;
```

- [ ] **Step 4: Rodar e ver passar**

Run: `supabase/teste/rodar.sh`
Expected: `OK: schema.sql e teste.sql passaram`

- [ ] **Step 5: Idempotência**

Run: `PG="$(brew --prefix postgresql@17)/bin"; LC_ALL=C $PG/psql -h localhost -p 5499 -U postgres -v ON_ERROR_STOP=1 -q -d hub_teste -f supabase/schema.sql && echo "segunda execução OK"`
Expected: `segunda execução OK`, sem erro de "already exists" (as tabelas têm `if not exists`, as políticas são derrubadas pelo laço, as funções são `or replace`, e o `revoke`/`grant` repetidos são inofensivos).

- [ ] **Step 6: Commit**

```bash
git add supabase/ && git commit -m "Calendário: importar, listar e feed por token

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

- [ ] **Step 7: Passo do Lucas (o controlador pede)** — colar o `supabase/schema.sql` inteiro de novo no SQL Editor do projeto e executar, para que as tarefas de front possam ser verificadas contra o banco real. Confirmação: `curl -s -H "apikey: <anon>" -H "Authorization: Bearer <anon>" -H "Content-Type: application/json" -d '{}' "https://qjwkwnxyifizqmomfwie.supabase.co/rest/v1/rpc/calendario_config_minha"` deve responder um erro em português ("Faça login para continuar"), e não "function not found".

### Task 3: Edge Function — leitura e escrita de `.ics` (funções puras)

**Files:**
- Create: `supabase/functions/calendario/index.ts` (só as funções puras nesta tarefa; as rotas entram na Tarefa 4)
- Create: `supabase/functions/calendario/index_test.ts`

**Interfaces:**
- Produces (exportadas de `index.ts`): `type Evento = {uid, titulo, descricao, inicio, fim, dia_inteiro, url, curso_codigo, curso_nome}` (mesmos nomes do banco; `inicio`/`fim` em ISO UTC), `desdobrar(texto: string): string`, `lerData(valor: string, params: Record<string,string>): {iso: string; diaInteiro: boolean} | null`, `extrairCurso(summary: string): {titulo, curso_codigo, curso_nome}`, `lerEventos(texto: string): Evento[]`, `escreverCalendario(nome: string, eventos: Evento[], agora?: Date): string`.
- Requer Deno 2 (`/opt/homebrew/bin/deno`, já instalado). Comando de teste: `HUB_TESTE=1 deno test --allow-env supabase/functions/calendario/`.

- [ ] **Step 1: Escrever os testes**

`supabase/functions/calendario/index_test.ts`:

```ts
import { assert, assertEquals, assertMatch } from "jsr:@std/assert@1";
import { desdobrar, escreverCalendario, extrairCurso, lerData, lerEventos } from "./index.ts";

// Amostra no formato do feed do Canvas (linhas dobradas, \, e \n escapados, prazo sem duração,
// evento com duração, dia inteiro, TZID, evento sem UID).
const FIXTURE = [
  "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:icalendar-ruby", "X-WR-CALNAME:Lucas (Canvas)",
  "BEGIN:VEVENT", "UID:event-assignment-1", "DTSTART:20260807T100000Z", "DTEND:20260807T100000Z",
  "SUMMARY:Atividade 02 (Preparação para a aula – não pontuada) [(6166100", " ) Cálculo II]",
  "DESCRIPTION:Linha 1\\, com vírgula\\nLinha 2", "URL;VALUE=URI:https://pucminas.instructure.com/calendar?x=1", "END:VEVENT",
  "BEGIN:VEVENT", "UID:event-assignment-2", "DTSTART:20261001T120000Z", "DTEND:20261001T134000Z",
  "SUMMARY:Aula [(6161100) AEDS II]", "END:VEVENT",
  "BEGIN:VEVENT", "UID:event-3", "DTSTART;VALUE=DATE:20260912", "DTEND;VALUE=DATE:20260913", "SUMMARY:Feriado", "END:VEVENT",
  "BEGIN:VEVENT", "UID:event-4", "DTSTART;TZID=America/Sao_Paulo:20260910T090000",
  "SUMMARY:Prova [(6166100) Cálculo II]", "URL:http://inseguro", "END:VEVENT",
  "BEGIN:VEVENT", "SUMMARY:Sem UID", "DTSTART:20260910T090000Z", "END:VEVENT",
  "END:VCALENDAR", "",
].join("\r\n");

Deno.test("desdobrar junta linhas de continuação e normaliza quebras", () => {
  assertEquals(desdobrar("A:um\r\n dois\r\nB:x\n\ty"), "A:umdois\nB:xy");
});

Deno.test("lerData: UTC, dia inteiro, TZID e inválida", () => {
  assertEquals(lerData("20260807T100000Z", {}), { iso: "2026-08-07T10:00:00.000Z", diaInteiro: false });
  assertEquals(lerData("20260912", { VALUE: "DATE" }), { iso: "2026-09-12T00:00:00.000Z", diaInteiro: true });
  assertEquals(lerData("20260910T090000", { TZID: "America/Sao_Paulo" }), { iso: "2026-09-10T12:00:00.000Z", diaInteiro: false });
  assertEquals(lerData("20260910T090000", {}), { iso: "2026-09-10T09:00:00.000Z", diaInteiro: false });
  assertEquals(lerData("ontem", {}), null);
});

Deno.test("extrairCurso separa o sufixo [(código) curso]", () => {
  assertEquals(extrairCurso("Prova 1 [(6166100) Cálculo II]"), { titulo: "Prova 1", curso_codigo: "6166100", curso_nome: "Cálculo II" });
  assertEquals(extrairCurso("Feriado"), { titulo: "Feriado", curso_codigo: null, curso_nome: null });
});

Deno.test("lerEventos lê o feed do Canvas", () => {
  const ev = lerEventos(FIXTURE);
  assertEquals(ev.length, 4, "o evento sem UID é ignorado");
  const [e1, e2, e3, e4] = ev;
  assertEquals(e1.uid, "event-assignment-1");
  assertEquals(e1.titulo, "Atividade 02 (Preparação para a aula – não pontuada)");
  assertEquals(e1.curso_codigo, "6166100");
  assertEquals(e1.curso_nome, "Cálculo II");
  assertEquals(e1.inicio, "2026-08-07T10:00:00.000Z");
  assertEquals(e1.fim, null, "DTEND igual ao DTSTART vira nulo");
  assertEquals(e1.dia_inteiro, false);
  assertEquals(e1.descricao, "Linha 1, com vírgula\nLinha 2");
  assertEquals(e1.url, "https://pucminas.instructure.com/calendar?x=1");
  assertEquals(e2.fim, "2026-10-01T13:40:00.000Z");
  assertEquals(e3.dia_inteiro, true);
  assertEquals(e3.inicio, "2026-09-12T00:00:00.000Z");
  assertEquals(e3.fim, null);
  assertEquals(e3.curso_nome, null);
  assertEquals(e4.inicio, "2026-09-10T12:00:00.000Z", "TZID convertido para UTC");
  assertEquals(e4.url, null, "URL http é descartada");
});

Deno.test("lerEventos não quebra com texto vazio ou sem eventos", () => {
  assertEquals(lerEventos(""), []);
  assertEquals(lerEventos("BEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n"), []);
});

Deno.test("escreverCalendario gera um .ics válido e relegível", () => {
  const originais = lerEventos(FIXTURE);
  const ics = escreverCalendario("Ana", originais, new Date("2026-09-04T12:00:00Z"));
  assert(ics.startsWith("BEGIN:VCALENDAR\r\n"));
  assert(ics.endsWith("END:VCALENDAR\r\n"));
  assertMatch(ics, /X-WR-CALNAME:Hub de Estudos · Ana/);
  assertMatch(ics, /DTSTART;VALUE=DATE:20260912\r\nDTEND;VALUE=DATE:20260913/);
  assertMatch(ics, /DTSTART:20260807T100000Z\r\nDTEND:20260807T103000Z/, "prazo sem fim ganha 30 min");
  assertMatch(ics, /DTSTAMP:20260904T120000Z/);
  assertMatch(ics, /DESCRIPTION:Linha 1\\, com vírgula\\nLinha 2/);
  for (const linha of ics.split("\r\n")) assert(new TextEncoder().encode(linha).length <= 75, "linha dobrada: " + linha);
  const relidos = lerEventos(ics);
  assertEquals(relidos.length, originais.length);
  relidos.forEach((r, i) => {
    assertEquals(r.uid, originais[i].uid + "@hub-estudos");
    assertEquals(r.inicio, originais[i].inicio);
    assertEquals(r.descricao, originais[i].descricao);
    assertEquals(r.dia_inteiro, originais[i].dia_inteiro);
    const sufixo = originais[i].curso_nome ? " (" + originais[i].curso_nome + ")" : "";
    assertEquals(r.titulo, originais[i].titulo + sufixo);
  });
});
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `HUB_TESTE=1 deno test --allow-env supabase/functions/calendario/`
Expected: falha ao resolver `./index.ts` (arquivo não existe).

- [ ] **Step 3: Escrever as funções puras**

`supabase/functions/calendario/index.ts`:

```ts
// Edge Function "calendario" do Hub de Estudos.
//   POST /calendario/importar        usuário logado: baixa o feed do Canvas e grava os eventos
//   GET  /calendario/feed?token=…    pública: devolve o calendário do usuário em .ics
// Arquivo único de propósito: dá para colar inteiro no editor do painel do Supabase.
// As rotas entram na próxima tarefa; esta parte é só leitura e escrita de .ics.

export type Evento = {
  uid: string;
  titulo: string;
  descricao: string;
  inicio: string;          // ISO em UTC
  fim: string | null;      // nulo = prazo sem duração
  dia_inteiro: boolean;
  url: string | null;
  curso_codigo: string | null;
  curso_nome: string | null;
};

// ---------- leitura ----------

// Junta linhas de continuação (RFC 5545: a continuação começa com espaço ou tab) e normaliza \r\n.
export function desdobrar(texto: string): string {
  return texto.replace(/\r\n?/g, "\n").replace(/\n[ \t]/g, "");
}

function desescapar(s: string): string {
  return s.replace(/\\n/gi, "\n").replace(/\\,/g, ",").replace(/\\;/g, ";").replace(/\\\\/g, "\\");
}

// "DTSTART;VALUE=DATE:20260807" → { params: { VALUE: "DATE" }, valor: "20260807" }
function propriedade(bloco: string, nome: string): { params: Record<string, string>; valor: string } | null {
  const m = new RegExp("^" + nome + "((?:;[^:\\n]*)?):(.*)$", "m").exec(bloco);
  if (!m) return null;
  const params: Record<string, string> = {};
  for (const p of m[1].split(";").filter(Boolean)) {
    const [k, v] = p.split("=");
    params[k.toUpperCase()] = (v ?? "").replace(/^"|"$/g, "");
  }
  return { params, valor: m[2] };
}

// Diferença (ms) entre a hora de parede numa zona e o UTC, naquele instante.
function deslocamento(zona: string, instante: number): number {
  try {
    const f = new Intl.DateTimeFormat("en-US", {
      timeZone: zona, hour12: false, year: "numeric", month: "2-digit", day: "2-digit",
      hour: "2-digit", minute: "2-digit", second: "2-digit",
    });
    const p = Object.fromEntries(f.formatToParts(new Date(instante)).map((x) => [x.type, x.value]));
    const parede = Date.UTC(+p.year, +p.month - 1, +p.day, +p.hour % 24, +p.minute, +p.second);
    return parede - instante;
  } catch {
    return 0;
  }
}

// Valor de data do .ics → ISO em UTC. Dia inteiro vira meia-noite UTC daquele dia.
export function lerData(valor: string, params: Record<string, string>): { iso: string; diaInteiro: boolean } | null {
  const v = valor.trim();
  const soDia = /^(\d{4})(\d{2})(\d{2})$/.exec(v);
  if (soDia || params.VALUE === "DATE") {
    const m = soDia ?? /^(\d{4})(\d{2})(\d{2})/.exec(v);
    if (!m) return null;
    return { iso: `${m[1]}-${m[2]}-${m[3]}T00:00:00.000Z`, diaInteiro: true };
  }
  const m = /^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})?(Z?)$/.exec(v);
  if (!m) return null;
  const parede = Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +(m[6] ?? "0"));
  if (Number.isNaN(parede)) return null;
  const utc = m[7] === "Z" || !params.TZID ? parede : parede - deslocamento(params.TZID, parede);
  return { iso: new Date(utc).toISOString(), diaInteiro: false };
}

// "Prova 1 [(6166100) Cálculo II]" → título sem o sufixo + código e nome do curso
export function extrairCurso(summary: string): { titulo: string; curso_codigo: string | null; curso_nome: string | null } {
  const m = /\[\((\d+)\)\s*([^\]]+)\]\s*$/.exec(summary);
  if (!m) return { titulo: summary.trim(), curso_codigo: null, curso_nome: null };
  return { titulo: summary.slice(0, m.index).trim(), curso_codigo: m[1], curso_nome: m[2].trim() };
}

export function lerEventos(texto: string): Evento[] {
  const plano = desdobrar(texto);
  const eventos: Evento[] = [];
  const re = /BEGIN:VEVENT\n([\s\S]*?)\nEND:VEVENT/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(plano))) {
    const bloco = m[1];
    const uid = propriedade(bloco, "UID")?.valor.trim();
    const ini = propriedade(bloco, "DTSTART");
    if (!uid || !ini) continue;
    const inicio = lerData(ini.valor, ini.params);
    if (!inicio) continue;
    const fimProp = propriedade(bloco, "DTEND");
    const fimData = fimProp ? lerData(fimProp.valor, fimProp.params) : null;
    const fim = fimData && !inicio.diaInteiro && fimData.iso > inicio.iso ? fimData.iso : null;
    const curso = extrairCurso(desescapar(propriedade(bloco, "SUMMARY")?.valor ?? ""));
    const url = (propriedade(bloco, "URL")?.valor ?? "").trim();
    eventos.push({
      uid,
      titulo: curso.titulo || "(sem título)",
      descricao: desescapar(propriedade(bloco, "DESCRIPTION")?.valor ?? "").trim(),
      inicio: inicio.iso,
      fim,
      dia_inteiro: inicio.diaInteiro,
      url: /^https:\/\//.test(url) ? url : null,
      curso_codigo: curso.curso_codigo,
      curso_nome: curso.curso_nome,
    });
  }
  return eventos;
}

// ---------- escrita ----------

function escapar(s: string): string {
  return s.replace(/\\/g, "\\\\").replace(/;/g, "\\;").replace(/,/g, "\\,").replace(/\r?\n/g, "\\n");
}

// Dobra em 75 octetos (a continuação começa com espaço e conta 1 octeto).
function dobrar(linha: string): string {
  const enc = new TextEncoder();
  if (enc.encode(linha).length <= 75) return linha;
  const partes: string[] = [];
  let atual = "";
  let tam = 0;
  for (const ch of linha) {
    const b = enc.encode(ch).length;
    const limite = partes.length ? 74 : 75;
    if (tam + b > limite) { partes.push(atual); atual = ""; tam = 0; }
    atual += ch;
    tam += b;
  }
  partes.push(atual);
  return partes.join("\r\n ");
}

const dataIcs = (iso: string) => iso.replace(/[-:]/g, "").replace(/\.\d{3}/, "");   // 20260807T100000Z
const diaIcs = (iso: string) => iso.slice(0, 10).replace(/-/g, "");                  // 20260807
function diaSeguinte(iso: string): string {
  const d = new Date(iso.slice(0, 10) + "T00:00:00Z");
  d.setUTCDate(d.getUTCDate() + 1);
  return diaIcs(d.toISOString());
}

export function escreverCalendario(nome: string, eventos: Evento[], agora: Date = new Date()): string {
  const stamp = dataIcs(agora.toISOString());
  const linhas = [
    "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Hub de Estudos//PT-BR", "CALSCALE:GREGORIAN", "METHOD:PUBLISH",
    "X-WR-CALNAME:" + escapar("Hub de Estudos · " + nome),
  ];
  for (const e of eventos) {
    linhas.push("BEGIN:VEVENT", "UID:" + e.uid + "@hub-estudos", "DTSTAMP:" + stamp);
    if (e.dia_inteiro) {
      linhas.push("DTSTART;VALUE=DATE:" + diaIcs(e.inicio), "DTEND;VALUE=DATE:" + diaSeguinte(e.inicio));
    } else {
      const fim = e.fim ?? new Date(new Date(e.inicio).getTime() + 30 * 60000).toISOString();
      linhas.push("DTSTART:" + dataIcs(e.inicio), "DTEND:" + dataIcs(fim));
    }
    const sufixo = e.curso_nome ? " (" + e.curso_nome + ")" : "";
    linhas.push("SUMMARY:" + escapar(e.titulo + sufixo));
    if (e.descricao) linhas.push("DESCRIPTION:" + escapar(e.descricao));
    if (e.url) linhas.push("URL:" + e.url);
    linhas.push("END:VEVENT");
  }
  linhas.push("END:VCALENDAR");
  return linhas.map(dobrar).join("\r\n") + "\r\n";
}
```

- [ ] **Step 4: Rodar e ver passar**

Run: `HUB_TESTE=1 deno test --allow-env supabase/functions/calendario/`
Expected: `ok | 6 passed | 0 failed`. (Na primeira execução o Deno baixa `jsr:@std/assert`; precisa de rede.)

- [ ] **Step 5: Commit**

```bash
git add supabase/functions/ && git commit -m "Calendário: leitura e escrita de .ics na Edge Function, com testes

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

### Task 4: Edge Function — rotas `importar` e `feed`

**Files:**
- Modify: `supabase/functions/calendario/index.ts` (acrescentar ao fim)
- Modify: `supabase/functions/calendario/index_test.ts` (acrescentar testes de roteamento)

**Interfaces:**
- Consumes: `lerEventos`, `escreverCalendario`, `Evento` da Tarefa 3; RPCs `calendario_config_minha`, `importar_eventos`, `registrar_erro_importacao`, `eventos_por_token` (Tarefas 1–2); variáveis de ambiente `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` (injetadas pelo Supabase).
- Produces: `tratar(req: Request, fabrica?: Fabrica): Promise<Response>` exportada; `type Fabrica = (jwt?: string) => SupabaseClient` (com JWT = cliente do usuário; sem JWT = cliente de serviço). Contrato HTTP: `OPTIONS` → 204 com CORS; `POST …/importar` → 401 sem `Authorization`, 400 sem feed salvo, 200 `{importados}`, 502 `{erro}` em falha de download/parse; `GET …/feed?token=` → 400 token ausente/inválido, 404 token desconhecido, 200 `text/calendar`; outra rota → 404 `{erro}`.

- [ ] **Step 1: Escrever os testes de roteamento**

Acrescente ao fim de `supabase/functions/calendario/index_test.ts`:

```ts
import { tratar } from "./index.ts";

// Fábrica que explode se alguma rota tentar falar com o Supabase nos casos que devem parar antes.
const semSupabase = () => { throw new Error("não deveria criar cliente"); };
const BASE = "https://proj.supabase.co/functions/v1/calendario";

Deno.test("tratar: OPTIONS responde 204 com CORS", async () => {
  const r = await tratar(new Request(BASE + "/importar", { method: "OPTIONS" }), semSupabase);
  assertEquals(r.status, 204);
  assertEquals(r.headers.get("Access-Control-Allow-Origin"), "*");
});

Deno.test("tratar: importar sem Authorization dá 401", async () => {
  const r = await tratar(new Request(BASE + "/importar", { method: "POST" }), semSupabase);
  assertEquals(r.status, 401);
  assertEquals((await r.json()).erro, "Faça login");
});

Deno.test("tratar: feed sem token ou com token inválido dá 400", async () => {
  const r1 = await tratar(new Request(BASE + "/feed"), semSupabase);
  assertEquals(r1.status, 400);
  const r2 = await tratar(new Request(BASE + "/feed?token=abc"), semSupabase);
  assertEquals(r2.status, 400);
});

Deno.test("tratar: rota desconhecida dá 404", async () => {
  const r = await tratar(new Request(BASE + "/outra"), semSupabase);
  assertEquals(r.status, 404);
});

Deno.test("tratar: feed com token válido devolve text/calendar", async () => {
  const token = "0123456789abcdef0123456789abcdef";
  const falso = () => ({
    rpc: (nome: string, args: Record<string, unknown>) => {
      assertEquals(nome, "eventos_por_token");
      assertEquals(args.token, token);
      return Promise.resolve({ data: { nome: "Ana", eventos: [{ uid: "e1", titulo: "Prova", descricao: "", inicio: "2026-09-10T10:00:00+00:00", fim: null, dia_inteiro: false, url: null, curso_codigo: null, curso_nome: "Cálculo II" }] }, error: null });
    },
  });
  // deno-lint-ignore no-explicit-any
  const r = await tratar(new Request(BASE + "/feed?token=" + token), falso as any);
  assertEquals(r.status, 200);
  assertMatch(r.headers.get("Content-Type") ?? "", /text\/calendar/);
  const corpo = await r.text();
  assertMatch(corpo, /SUMMARY:Prova \(Cálculo II\)/);
  assertMatch(corpo, /DTSTART:20260910T100000Z/);
});

Deno.test("tratar: feed com token desconhecido dá 404", async () => {
  const falso = () => ({ rpc: () => Promise.resolve({ data: null, error: null }) });
  // deno-lint-ignore no-explicit-any
  const r = await tratar(new Request(BASE + "/feed?token=0123456789abcdef0123456789abcdef"), falso as any);
  assertEquals(r.status, 404);
});
```

Atenção: `assertMatch` já está importado no topo do arquivo; a linha `import { tratar }` pode ser fundida com o import existente de `./index.ts`.

- [ ] **Step 2: Rodar e ver falhar**

Run: `HUB_TESTE=1 deno test --allow-env supabase/functions/calendario/`
Expected: erro de compilação: `tratar` não é exportado por `./index.ts`.

- [ ] **Step 3: Escrever as rotas**

Acrescente ao fim de `supabase/functions/calendario/index.ts`:

```ts
// ---------- rotas ----------
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";

export type Fabrica = (jwt?: string) => SupabaseClient;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

// Com JWT: age como o usuário (RLS vale). Sem JWT: chave de serviço, só para a rota pública do feed.
function cliente(jwt?: string): SupabaseClient {
  const url = Deno.env.get("SUPABASE_URL") ?? "";
  const chave = jwt ? Deno.env.get("SUPABASE_ANON_KEY") ?? "" : Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  return createClient(url, chave, {
    global: { headers: jwt ? { Authorization: "Bearer " + jwt } : {} },
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

function json(status: number, corpo: unknown): Response {
  return new Response(JSON.stringify(corpo), { status, headers: { ...CORS, "Content-Type": "application/json; charset=utf-8" } });
}

export async function tratar(req: Request, fabrica: Fabrica = cliente): Promise<Response> {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
  const url = new URL(req.url);
  const rota = url.pathname.replace(/\/+$/, "").split("/").pop();
  if (rota === "importar" && req.method === "POST") return importar(req, fabrica);
  if (rota === "feed" && req.method === "GET") return feed(url, fabrica);
  return json(404, { erro: "Rota não encontrada" });
}

async function baixar(url: string): Promise<string> {
  const LIMITE = 5 * 1024 * 1024;
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), 20000);
  try {
    const r = await fetch(url, { signal: ctrl.signal, headers: { "User-Agent": "hub-estudos/1.0" } });
    if (r.status !== 200) throw new Error("O Canvas respondeu " + r.status + " ao baixar o feed");
    if (Number(r.headers.get("content-length") ?? 0) > LIMITE) throw new Error("Feed maior que 5 MB");
    const texto = await r.text();
    if (texto.length > LIMITE) throw new Error("Feed maior que 5 MB");
    if (!/BEGIN:VCALENDAR/.test(texto)) throw new Error("A URL não devolveu um calendário (.ics)");
    return texto;
  } catch (e) {
    if (e instanceof Error && e.name === "AbortError") throw new Error("O Canvas demorou mais de 20 s para responder");
    throw e;
  } finally {
    clearTimeout(timer);
  }
}

async function importar(req: Request, fabrica: Fabrica): Promise<Response> {
  const jwt = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "").trim();
  if (!jwt) return json(401, { erro: "Faça login" });
  const db = fabrica(jwt);
  const { data: usuario, error: erroAuth } = await db.auth.getUser();
  if (erroAuth || !usuario?.user) return json(401, { erro: "Faça login" });
  const { data: config, error: erroConfig } = await db.rpc("calendario_config_minha");
  if (erroConfig) return json(500, { erro: erroConfig.message });
  const feedUrl = (config as { feed_url?: string | null } | null)?.feed_url ?? null;
  if (!feedUrl) return json(400, { erro: "Salve a URL do feed primeiro" });
  try {
    const eventos = lerEventos(await baixar(feedUrl));
    const { data: n, error } = await db.rpc("importar_eventos", { eventos });
    if (error) throw new Error(error.message);
    return json(200, { importados: n });
  } catch (e) {
    const msg = (e instanceof Error ? e.message : String(e)).slice(0, 500);
    await db.rpc("registrar_erro_importacao", { msg });
    return json(502, { erro: msg });
  }
}

async function feed(url: URL, fabrica: Fabrica): Promise<Response> {
  const token = (url.searchParams.get("token") ?? "").trim();
  if (!/^[a-f0-9]{32}$/.test(token)) return json(400, { erro: "Token ausente ou inválido" });
  const db = fabrica();
  const { data, error } = await db.rpc("eventos_por_token", { token });
  if (error) return json(500, { erro: error.message });
  if (!data) return new Response("Calendário não encontrado", { status: 404, headers: { ...CORS, "Content-Type": "text/plain; charset=utf-8" } });
  const dados = data as { nome?: string; eventos?: Evento[] };
  const ics = escreverCalendario(dados.nome ?? "", dados.eventos ?? []);
  return new Response(ics, {
    status: 200,
    headers: {
      ...CORS,
      "Content-Type": "text/calendar; charset=utf-8",
      "Content-Disposition": 'inline; filename="hub-estudos.ics"',
      "Cache-Control": "public, max-age=300",
    },
  });
}

// Em produção o Supabase executa este arquivo e a função sobe aqui.
// Nos testes, HUB_TESTE=1 evita abrir servidor.
if (!Deno.env.get("HUB_TESTE")) Deno.serve(tratar);
```

Nota: o `import` no meio do arquivo é válido em módulos ES (imports são içados), mas por clareza mova-o para o topo do arquivo junto do cabeçalho de comentários.

- [ ] **Step 4: Rodar e ver passar**

Run: `HUB_TESTE=1 deno test --allow-env supabase/functions/calendario/`
Expected: `ok | 12 passed | 0 failed`. Na primeira execução o Deno baixa `npm:@supabase/supabase-js@2`.

- [ ] **Step 5: Conferir que o arquivo compila como a função de produção**

Run: `deno check supabase/functions/calendario/index.ts`
Expected: sem erros de tipo.

- [ ] **Step 6: Commit**

```bash
git add supabase/functions/ && git commit -m "Calendário: rotas importar e feed na Edge Function

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

### Task 5: Front compartilhado — `chamarFuncao`, link no cabeçalho, `js/ics.js` e CSS

**Files:**
- Modify: `js/supabase.js` (acrescentar `chamarFuncao` e `urlFuncao` dentro do IIFE, antes do bloco `if (!window.db)`)
- Modify: `js/sessao.js` (link "Calendário" no cabeçalho)
- Create: `js/ics.js`
- Modify: `css/site.css` (acrescentar bloco `/* ---------- calendário ---------- */` antes de `/* ---------- telas pequenas ---------- */`, e duas regras dentro da media query)

**Interfaces:**
- Consumes: `window.CONFIG`, `window.db`, `traduzirErro`, `slug` (Task 6 do plano anterior).
- Produces (globais): `chamarFuncao(rota, opcoes)` → JSON da Edge Function (lança `Error` em português); `urlFuncao(rota)` → `CONFIG.SUPABASE_URL + '/functions/v1/calendario/' + rota`; em `js/ics.js`: `dataCompacta(iso)`, `diaCompacto(iso)`, `diaSeguinte(iso)`, `fimEfetivo(e)`, `tituloComCurso(e)`, `linkGoogle(e)`, `linkOutlook(e)`, `eventoParaIcs(e)`, `baixarIcs(e)`, `formatarHora(e)`, `chaveData(d)`, `chaveDia(e)`. Classes CSS: `.calendario-topo`, `.grade-mes`, `.dia-semana`, `.dia`, `.dia-fora`, `.dia-hoje`, `.dia-numero`, `.chip-evento`, `.chip-evento-mais`, `.dia-grupo`, `.evento`, `.evento-topo`, `.evento-hora`, `.evento-titulo`, `.link-feed`.

- [ ] **Step 1: `js/supabase.js` — chamar a Edge Function com o JWT da sessão**

Dentro do IIFE, logo depois da definição de `window.chamar`, acrescente:

```js
  // urlFuncao('feed') → endereço da rota na Edge Function "calendario".
  window.urlFuncao = function (rota) {
    return (cfg.SUPABASE_URL || '') + '/functions/v1/calendario/' + rota;
  };

  // chamarFuncao('importar') → JSON da Edge Function, autenticado com o JWT da sessão.
  // opcoes: { method: 'POST' | 'GET', body: objeto }. Erro vira Error em português.
  window.chamarFuncao = async function (rota, opcoes) {
    if (!window.db) throw new Error('Backend não configurado: preencha js/config.js');
    var s = await db.auth.getSession();
    var token = s.data && s.data.session ? s.data.session.access_token : null;
    if (!token) throw new Error('Faça login para continuar');
    var r;
    try {
      r = await fetch(urlFuncao(rota), {
        method: (opcoes && opcoes.method) || 'POST',
        headers: { Authorization: 'Bearer ' + token, apikey: cfg.SUPABASE_ANON_KEY, 'Content-Type': 'application/json' },
        body: opcoes && opcoes.body ? JSON.stringify(opcoes.body) : undefined
      });
    } catch (e) {
      throw new Error('Sem conexão com a função do calendário. Ela já foi publicada no Supabase?');
    }
    var corpo = null;
    try { corpo = await r.json(); } catch (e) { corpo = null; }
    if (!r.ok) throw new Error((corpo && corpo.erro) || ('A função do calendário respondeu ' + r.status));
    return corpo;
  };
```

- [ ] **Step 2: `js/sessao.js` — link no cabeçalho**

Em `montarCabecalho`, troque a linha `var links = '<a href="index.html">Início</a>';` e a seguinte por:

```js
    var links = '<a href="index.html">Início</a>';
    if (s.usuario) links += '<a href="calendario.html">Calendário</a>';
    if (ehEquipe(s.perfil)) links += '<a href="publicar.html">Publicar</a>';
```

- [ ] **Step 3: `js/ics.js`**

```js
// Helpers puros do calendário: formatos de data que Google, Outlook e .ics esperam,
// e um .ics de um evento só para o Apple Calendar. Sem chamadas ao backend.
(function () {
  function pad(n) { return String(n).padStart(2, '0'); }

  // '2026-08-07T10:00:00+00:00' → '20260807T100000Z'
  window.dataCompacta = function (iso) {
    var d = new Date(iso);
    return d.getUTCFullYear() + pad(d.getUTCMonth() + 1) + pad(d.getUTCDate()) + 'T' +
      pad(d.getUTCHours()) + pad(d.getUTCMinutes()) + pad(d.getUTCSeconds()) + 'Z';
  };
  // '2026-08-07T00:00:00+00:00' → '20260807' (eventos de dia inteiro ficam à meia-noite UTC)
  window.diaCompacto = function (iso) { return iso.slice(0, 10).replace(/-/g, ''); };
  window.diaSeguinte = function (iso) {
    var d = new Date(iso.slice(0, 10) + 'T00:00:00Z');
    d.setUTCDate(d.getUTCDate() + 1);
    return d.toISOString();
  };
  // Prazo sem duração vira 30 minutos, que é o que os apps exigem para mostrar algo.
  window.fimEfetivo = function (e) {
    return e.fim || new Date(new Date(e.inicio).getTime() + 30 * 60000).toISOString();
  };
  window.tituloComCurso = function (e) { return e.titulo + (e.curso_nome ? ' (' + e.curso_nome + ')' : ''); };

  window.linkGoogle = function (e) {
    var datas = e.dia_inteiro
      ? diaCompacto(e.inicio) + '/' + diaCompacto(diaSeguinte(e.inicio))
      : dataCompacta(e.inicio) + '/' + dataCompacta(fimEfetivo(e));
    return 'https://calendar.google.com/calendar/render?action=TEMPLATE' +
      '&text=' + encodeURIComponent(tituloComCurso(e)) +
      '&dates=' + datas +
      '&details=' + encodeURIComponent((e.descricao || '') + (e.url ? '\n' + e.url : ''));
  };

  window.linkOutlook = function (e) {
    var ini = e.dia_inteiro ? e.inicio.slice(0, 10) : new Date(e.inicio).toISOString();
    var fim = e.dia_inteiro ? diaSeguinte(e.inicio).slice(0, 10) : new Date(fimEfetivo(e)).toISOString();
    return 'https://outlook.live.com/calendar/0/deeplink/compose?path=/calendar/action/compose&rru=addevent' +
      '&subject=' + encodeURIComponent(tituloComCurso(e)) +
      '&startdt=' + ini + '&enddt=' + fim + (e.dia_inteiro ? '&allday=true' : '') +
      '&body=' + encodeURIComponent((e.descricao || '') + (e.url ? '\n' + e.url : ''));
  };

  function escaparIcs(s) {
    return String(s).replace(/\\/g, '\\\\').replace(/;/g, '\\;').replace(/,/g, '\\,').replace(/\r?\n/g, '\\n');
  }

  window.eventoParaIcs = function (e) {
    var l = ['BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//Hub de Estudos//PT-BR', 'BEGIN:VEVENT',
      'UID:' + e.uid + '@hub-estudos', 'DTSTAMP:' + dataCompacta(new Date().toISOString())];
    if (e.dia_inteiro) l.push('DTSTART;VALUE=DATE:' + diaCompacto(e.inicio), 'DTEND;VALUE=DATE:' + diaCompacto(diaSeguinte(e.inicio)));
    else l.push('DTSTART:' + dataCompacta(e.inicio), 'DTEND:' + dataCompacta(fimEfetivo(e)));
    l.push('SUMMARY:' + escaparIcs(tituloComCurso(e)));
    if (e.descricao) l.push('DESCRIPTION:' + escaparIcs(e.descricao));
    if (e.url) l.push('URL:' + e.url);
    l.push('END:VEVENT', 'END:VCALENDAR');
    return l.join('\r\n') + '\r\n';
  };

  // Baixa um .ics de um evento (Apple Calendar abre direto).
  window.baixarIcs = function (e) {
    var blob = new Blob([eventoParaIcs(e)], { type: 'text/calendar' });
    var a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = slug(e.titulo) + '.ics';
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(function () { URL.revokeObjectURL(a.href); }, 1000);
  };

  window.formatarHora = function (e) {
    if (e.dia_inteiro) return 'dia inteiro';
    return new Date(e.inicio).toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' });
  };
  // Chave 'AAAA-MM-DD' no fuso do navegador (para agrupar por dia).
  window.chaveData = function (d) { return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()); };
  window.chaveDia = function (e) { return e.dia_inteiro ? e.inicio.slice(0, 10) : chaveData(new Date(e.inicio)); };
})();
```

- [ ] **Step 4: CSS**

Em `css/site.css`, antes de `/* ---------- telas pequenas ---------- */`:

```css
/* ---------- calendário ---------- */
.calendario-topo{display:flex;flex-wrap:wrap;align-items:center;gap:10px;margin-bottom:12px}
.calendario-topo h2{margin:0;font-size:20px;flex:1;min-width:160px;text-transform:capitalize}
.grade-mes{display:grid;grid-template-columns:repeat(7,1fr);gap:4px}
.dia-semana{font-family:var(--mono);font-size:11px;letter-spacing:.08em;text-transform:uppercase;color:var(--fg-faint);text-align:center;padding:4px 0}
.dia{min-height:88px;background:var(--panel);border:1px solid var(--line-soft);border-radius:var(--radius-sm);padding:6px;display:flex;flex-direction:column;gap:3px;min-width:0}
.dia-fora{opacity:.45}
.dia-hoje{border-color:var(--bean);box-shadow:0 0 0 2px var(--bean-soft)}
.dia-numero{font-family:var(--mono);font-size:12px;color:var(--fg-dim)}
.dia-hoje .dia-numero{color:var(--bean);font-weight:700}
.chip-evento{display:block;font-size:11px;line-height:1.3;background:var(--steam-soft);border-left:2px solid var(--steam);color:var(--fg);padding:2px 5px;border-radius:4px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.chip-evento:hover{background:var(--bean-soft);border-left-color:var(--bean)}
.chip-evento-mais{font-size:11px;color:var(--fg-faint)}
.dia-grupo{margin-top:18px}
.dia-grupo h3{font-size:14px;margin:0 0 8px;color:var(--crema);font-family:var(--mono);text-transform:capitalize}
.evento{background:var(--panel);border:1px solid var(--line);border-radius:var(--radius-sm);padding:12px 14px;margin-bottom:8px}
.evento-topo{display:flex;flex-wrap:wrap;align-items:baseline;gap:8px}
.evento-hora{font-family:var(--mono);font-size:12px;color:var(--fg-faint);min-width:56px}
.evento-titulo{font-weight:600;flex:1;min-width:200px}
.evento details{margin-top:6px;font-size:13.5px;color:var(--fg-dim);white-space:pre-wrap}
.evento details summary{cursor:pointer;color:var(--fg-faint);font-size:12.5px;white-space:normal}
.evento .botoes{margin-top:8px}
.link-feed{display:flex;gap:8px;align-items:center;margin-bottom:8px}
.link-feed code{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-family:var(--mono);font-size:12px;background:var(--code-bg);border:1px solid var(--line);border-radius:6px;padding:8px 10px;color:var(--code-fg)}
```

E dentro de `@media (max-width:640px){ … }` acrescente:

```css
  .grade-mes{gap:2px}
  .dia{min-height:52px;padding:4px}
  .chip-evento{font-size:0;height:4px;padding:0;border-left:0;background:var(--steam);border-radius:2px}
```

- [ ] **Step 5: Verificar no navegador**

Servidor de preview em `http://localhost:8000`. Abrir `index.html` logado (a sessão do painel pode estar deslogada: basta conferir que sem login o cabeçalho não mostra "Calendário", e que `js/ics.js` carrega sem erro). Checagens via `javascript_tool` em qualquer página que carregue os scripts (adicione temporariamente `<script src="js/ics.js"></script>` no console com `var s=document.createElement('script');s.src='js/ics.js';document.body.appendChild(s)`):

```js
JSON.stringify({
  a: dataCompacta('2026-08-07T10:00:00+00:00'),               // "20260807T100000Z"
  b: diaSeguinte('2026-09-12T00:00:00+00:00'),                 // "2026-09-13T00:00:00.000Z"
  c: linkGoogle({titulo:'Prova', curso_nome:'Cálculo II', inicio:'2026-09-10T10:00:00+00:00', fim:null, dia_inteiro:false, descricao:'', url:null}).indexOf('dates=20260910T100000Z/20260910T103000Z') > 0,
  d: eventoParaIcs({uid:'x', titulo:'A;B', inicio:'2026-09-12T00:00:00+00:00', fim:null, dia_inteiro:true, descricao:'', url:null}).indexOf('DTSTART;VALUE=DATE:20260912\r\nDTEND;VALUE=DATE:20260913') > 0,
  e: eventoParaIcs({uid:'x', titulo:'A;B', inicio:'2026-09-12T00:00:00+00:00', fim:null, dia_inteiro:true, descricao:'', url:null}).indexOf('SUMMARY:A\\;B') > 0,
  f: typeof chamarFuncao === 'function' && urlFuncao('feed').indexOf('/functions/v1/calendario/feed') > 0
})
```
Expected: todos verdadeiros / os valores indicados; console sem erros.

- [ ] **Step 6: Commit**

```bash
git add js/ css/site.css && git commit -m "Calendário: chamada à Edge Function, helpers de .ics e estilos da grade

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

### Task 6: Página `calendario.html`

**Files:**
- Create: `calendario.html`

**Interfaces:**
- Consumes: RPCs `calendario_config_minha`, `salvar_feed_url`, `listar_eventos`, `novo_token_feed`; `chamarFuncao('importar')`, `urlFuncao('feed')`; globais de `js/ics.js`; `exigirLogin`, `montarCabecalho`, `mostrarAviso`, `esc`, `chamar`.
- Comportamentos exigidos pela spec §5.3: importação automática ao abrir se houver `feed_url` e a última importação for nula ou tiver mais de 6 h; grade começa na segunda; até 3 chips por dia e "+n"; lista do mês agrupada por dia; botões Google/Outlook/Apple por evento; bloco de assinatura com os links `https` e `webcal`, copiar e "Gerar novo link" com `confirm`.

- [ ] **Step 1: Escrever `calendario.html`**

```html
<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Calendário · Hub de Estudos</title>
<link rel="stylesheet" href="tema.css">
<link rel="stylesheet" href="css/site.css">
</head>
<body>
<header class="cabecalho" id="cabecalho"></header>

<main class="conteudo">
  <h1 class="titulo-pagina">Calendário</h1>
  <p class="subtitulo">Seus prazos do Canvas, aqui no hub e no seu app de calendário.</p>
  <div class="aviso" id="aviso" hidden></div>

  <section class="secao">
    <h2>Fonte: feed do Canvas</h2>
    <form id="form-feed">
      <div class="campo">
        <label for="feed">URL do feed do Canvas</label>
        <input id="feed" type="url" placeholder="https://pucminas.instructure.com/feeds/calendars/user_….ics" required>
        <details class="dica"><summary>Onde acho essa URL?</summary>No Canvas: Calendário → botão "Feed do calendário" (canto inferior direito) → copie o link que termina em .ics. Ele é pessoal: não compartilhe.</details>
      </div>
      <div class="botoes">
        <button class="botao" type="submit" id="salvar">Salvar e importar</button>
        <button class="botao botao-secundario" type="button" id="atualizar">Atualizar agora</button>
        <span class="discreto" id="estado"></span>
      </div>
    </form>
  </section>

  <p class="vazio" id="sem-feed" hidden>Cole a URL do feed do Canvas para começar.</p>

  <section class="secao" id="secao-mes" hidden>
    <div class="calendario-topo">
      <button class="botao botao-secundario botao-pequeno" type="button" id="anterior" title="Mês anterior">‹</button>
      <h2 id="titulo-mes"></h2>
      <button class="botao botao-secundario botao-pequeno" type="button" id="proximo" title="Próximo mês">›</button>
      <button class="botao botao-secundario botao-pequeno" type="button" id="hoje">Hoje</button>
    </div>
    <div class="chips" id="cursos"></div>
    <div class="grade-mes" id="grade"></div>
  </section>

  <section class="secao" id="secao-lista" hidden>
    <h2>Eventos do mês</h2>
    <div id="lista"></div>
  </section>

  <section class="secao" id="secao-assinar" hidden>
    <h2>Assinar no seu app</h2>
    <p class="discreto">Google Agenda, Apple Calendar e Outlook atualizam sozinhos a partir deste link. Ele é pessoal: quem tiver o link vê seus eventos.</p>
    <div class="link-feed"><code id="link-https"></code><button class="botao botao-secundario botao-pequeno" type="button" data-copiar="link-https">Copiar</button></div>
    <div class="link-feed"><code id="link-webcal"></code><button class="botao botao-secundario botao-pequeno" type="button" data-copiar="link-webcal">Copiar</button></div>
    <ul class="lista">
      <li>Google Agenda: Outras agendas → + → Por URL → cole o link https.</li>
      <li>Apple Calendar: Arquivo → Nova assinatura de calendário → cole o link webcal.</li>
      <li>Outlook: Adicionar calendário → Assinar da Web → cole o link https.</li>
    </ul>
    <p><button class="botao botao-perigo botao-pequeno" type="button" id="novo-link">Gerar novo link</button></p>
  </section>
</main>

<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
<script src="js/config.js"></script>
<script src="js/util.js"></script>
<script src="js/supabase.js"></script>
<script src="js/sessao.js"></script>
<script src="js/ics.js"></script>
<script>
// Calendário pessoal: config e eventos vêm do banco; a importação roda na Edge Function.
(async function () {
  var aviso = document.getElementById('aviso'), estado = document.getElementById('estado');
  var SEIS_HORAS = 6 * 60 * 60 * 1000;
  var config = null, eventos = [], curso = '', atual = inicioDoMes(new Date());

  var s = await exigirLogin();
  if (!s) return;
  montarCabecalho();

  function inicioDoMes(d) { return new Date(d.getFullYear(), d.getMonth(), 1); }
  function avisar(msg, tipo) { mostrarAviso(aviso, msg, tipo); }
  function mostrarBlocos(temFeed) {
    document.getElementById('secao-mes').hidden = !temFeed;
    document.getElementById('secao-lista').hidden = !temFeed;
    document.getElementById('secao-assinar').hidden = !temFeed;
    document.getElementById('sem-feed').hidden = temFeed;
  }

  // ---------- config e importação ----------
  async function carregarConfig() {
    config = await chamar('calendario_config_minha');
    document.getElementById('feed').value = config.feed_url || '';
    mostrarBlocos(!!config.feed_url);
    desenharEstado();
    desenharLinks();
  }
  function desenharEstado() {
    if (config.ultimo_erro) {
      estado.textContent = '';
      avisar('A última importação falhou: ' + config.ultimo_erro);
      return;
    }
    estado.textContent = config.ultima_importacao
      ? 'Última importação: ' + new Date(config.ultima_importacao).toLocaleString('pt-BR') + ' · ' + config.total_eventos + ' evento(s)'
      : 'Nenhuma importação ainda.';
  }
  function desenharLinks() {
    var https = urlFuncao('feed') + '?token=' + config.token_feed;
    document.getElementById('link-https').textContent = https;
    document.getElementById('link-webcal').textContent = https.replace(/^https:/, 'webcal:');
  }
  async function importar() {
    estado.textContent = 'Atualizando…';
    avisar('');
    document.getElementById('atualizar').disabled = true;
    try {
      var r = await chamarFuncao('importar');
      await carregarConfig();
      await carregarMes();
      avisar(r.importados + ' evento(s) importados do Canvas.', 'ok');
    } catch (e) {
      try { await carregarConfig(); } catch (e2) { /* o aviso abaixo cobre */ }
      if (!config || !config.ultimo_erro) avisar(e.message);
      await carregarMes();
    }
    document.getElementById('atualizar').disabled = false;
  }

  document.getElementById('form-feed').addEventListener('submit', async function (ev) {
    ev.preventDefault();
    try {
      await chamar('salvar_feed_url', { url: document.getElementById('feed').value.trim() });
      await carregarConfig();
      await importar();
    } catch (e) { avisar(e.message); }
  });
  document.getElementById('atualizar').addEventListener('click', function () { if (config && config.feed_url) importar(); else avisar('Salve a URL do feed primeiro.'); });
  document.getElementById('novo-link').addEventListener('click', async function () {
    if (!confirm('Gerar um novo link? O antigo deixa de funcionar nos apps que o assinaram.')) return;
    try { await chamar('novo_token_feed'); await carregarConfig(); avisar('Novo link gerado. Atualize a assinatura nos seus apps.', 'ok'); }
    catch (e) { avisar(e.message); }
  });
  document.querySelectorAll('[data-copiar]').forEach(function (b) {
    b.addEventListener('click', function () {
      var texto = document.getElementById(b.dataset.copiar).textContent;
      navigator.clipboard.writeText(texto).then(function () {
        b.textContent = 'Copiado';
        setTimeout(function () { b.textContent = 'Copiar'; }, 1500);
      }, function () { avisar('Não consegui copiar; selecione o link e copie à mão.'); });
    });
  });

  // ---------- mês ----------
  // A grade começa na segunda-feira anterior (ou igual) ao dia 1 e tem 5 ou 6 semanas.
  function limitesGrade(mes) {
    var ini = new Date(mes);
    ini.setDate(ini.getDate() - ((ini.getDay() + 6) % 7));
    var ultimo = new Date(mes.getFullYear(), mes.getMonth() + 1, 0);
    var dias = Math.round((ultimo - ini) / 86400000) + 1;
    var semanas = dias > 35 ? 6 : 5;
    var fim = new Date(ini);
    fim.setDate(fim.getDate() + semanas * 7);
    return { ini: ini, fim: fim, semanas: semanas };
  }
  async function carregarMes() {
    if (!config || !config.feed_url) return;
    var lim = limitesGrade(atual);
    try { eventos = await chamar('listar_eventos', { de: lim.ini.toISOString(), ate: lim.fim.toISOString() }); }
    catch (e) { avisar(e.message); eventos = []; }
    desenharCursos();
    desenharGrade();
    desenharLista();
  }
  function filtrados() { return eventos.filter(function (e) { return !curso || (e.curso_nome || '') === curso; }); }
  function desenharCursos() {
    var nomes = [];
    eventos.forEach(function (e) { if (e.curso_nome && nomes.indexOf(e.curso_nome) < 0) nomes.push(e.curso_nome); });
    nomes.sort();
    if (curso && nomes.indexOf(curso) < 0) curso = '';
    document.getElementById('cursos').innerHTML =
      '<button class="chip' + (curso ? '' : ' chip-ativo') + '" type="button" data-curso="">todos</button>' +
      nomes.map(function (n) { return '<button class="chip' + (curso === n ? ' chip-ativo' : '') + '" type="button" data-curso="' + esc(n) + '">' + esc(n) + '</button>'; }).join('');
  }
  function desenharGrade() {
    var lim = limitesGrade(atual), hoje = chaveData(new Date());
    var porDia = {};
    filtrados().forEach(function (e) { var k = chaveDia(e); (porDia[k] = porDia[k] || []).push(e); });
    var html = ['Seg', 'Ter', 'Qua', 'Qui', 'Sex', 'Sáb', 'Dom'].map(function (n) { return '<div class="dia-semana">' + n + '</div>'; }).join('');
    var d = new Date(lim.ini);
    for (var i = 0; i < lim.semanas * 7; i++) {
      var k = chaveData(d), lista = porDia[k] || [], fora = d.getMonth() !== atual.getMonth();
      html += '<div class="dia' + (fora ? ' dia-fora' : '') + (k === hoje ? ' dia-hoje' : '') + '">' +
        '<span class="dia-numero">' + d.getDate() + '</span>' +
        lista.slice(0, 3).map(function (e) { return '<a class="chip-evento" href="#ev-' + e.id + '" title="' + esc(tituloComCurso(e)) + '">' + esc(e.titulo) + '</a>'; }).join('') +
        (lista.length > 3 ? '<span class="chip-evento-mais">+' + (lista.length - 3) + '</span>' : '') +
        '</div>';
      d.setDate(d.getDate() + 1);
    }
    document.getElementById('grade').innerHTML = html;
    document.getElementById('titulo-mes').textContent = atual.toLocaleDateString('pt-BR', { month: 'long', year: 'numeric' });
  }
  function eventoHtml(e) {
    var selo = e.curso_nome ? '<span class="selo selo-disciplina">' + esc(e.curso_nome) + '</span>' : '';
    var desc = e.descricao ? '<details><summary>descrição</summary>' + esc(e.descricao) + '</details>' : '';
    var canvas = e.url ? '<a class="botao botao-secundario botao-pequeno" href="' + esc(e.url) + '" target="_blank" rel="noopener">abrir no Canvas</a>' : '';
    return '<div class="evento" id="ev-' + e.id + '">' +
      '<div class="evento-topo"><span class="evento-hora">' + esc(formatarHora(e)) + '</span><span class="evento-titulo">' + esc(e.titulo) + '</span>' + selo + '</div>' + desc +
      '<div class="botoes">' + canvas +
      '<a class="botao botao-secundario botao-pequeno" href="' + esc(linkGoogle(e)) + '" target="_blank" rel="noopener">Google</a>' +
      '<a class="botao botao-secundario botao-pequeno" href="' + esc(linkOutlook(e)) + '" target="_blank" rel="noopener">Outlook</a>' +
      '<button class="botao botao-secundario botao-pequeno" type="button" data-ics="' + e.id + '">Apple / .ics</button>' +
      '</div></div>';
  }
  function desenharLista() {
    var mesChave = chaveData(atual).slice(0, 7);
    var doMes = filtrados().filter(function (e) { return chaveDia(e).slice(0, 7) === mesChave; });
    if (!doMes.length) { document.getElementById('lista').innerHTML = '<p class="vazio">Nenhum evento neste mês.</p>'; return; }
    var grupos = {}, ordem = [];
    doMes.forEach(function (e) { var k = chaveDia(e); if (!grupos[k]) { grupos[k] = []; ordem.push(k); } grupos[k].push(e); });
    document.getElementById('lista').innerHTML = ordem.map(function (k) {
      var titulo = new Date(k + 'T12:00:00').toLocaleDateString('pt-BR', { weekday: 'long', day: '2-digit', month: 'long' });
      return '<div class="dia-grupo"><h3>' + esc(titulo) + '</h3>' + grupos[k].map(eventoHtml).join('') + '</div>';
    }).join('');
  }

  document.getElementById('lista').addEventListener('click', function (ev) {
    var b = ev.target.closest('[data-ics]');
    if (!b) return;
    var e = eventos.filter(function (x) { return String(x.id) === b.dataset.ics; })[0];
    if (e) baixarIcs(e);
  });
  document.getElementById('cursos').addEventListener('click', function (ev) {
    var c = ev.target.closest('.chip');
    if (!c) return;
    curso = c.dataset.curso;
    desenharCursos(); desenharGrade(); desenharLista();
  });
  document.getElementById('anterior').addEventListener('click', function () { atual = new Date(atual.getFullYear(), atual.getMonth() - 1, 1); carregarMes(); });
  document.getElementById('proximo').addEventListener('click', function () { atual = new Date(atual.getFullYear(), atual.getMonth() + 1, 1); carregarMes(); });
  document.getElementById('hoje').addEventListener('click', function () { atual = inicioDoMes(new Date()); carregarMes(); });

  // ---------- início ----------
  try {
    await carregarConfig();
    if (config.feed_url) {
      var velha = !config.ultima_importacao || (Date.now() - new Date(config.ultima_importacao).getTime()) > SEIS_HORAS;
      if (velha) await importar(); else await carregarMes();
    }
  } catch (e) { avisar(e.message); }
})();
</script>
</body>
</html>
```

- [ ] **Step 2: Verificar no navegador (contra o banco real, sem a Edge Function ainda)**

Pré-requisito: o Lucas já rodou o `schema.sql` novo no projeto (Tarefa 2, passo 7) e está logado no painel do navegador (a sessão do painel pode ter sido encerrada no teste anterior; se `calendario.html` redirecionar para `entrar.html`, o controlador pede ao Lucas para entrar de novo no painel).

1. Abrir `http://localhost:8000/calendario.html`. Expected: bloco Fonte com campo vazio, "Nenhuma importação ainda.", aviso "Cole a URL do feed do Canvas para começar.", blocos de mês/lista/assinar escondidos; console sem erros.
2. Enviar o formulário com `https://exemplo.com/x.ics`. Expected: aviso vermelho "URL do feed inválida…".
3. Enviar com `https://pucminas.instructure.com/feeds/calendars/user_teste.ics` (falsa, só para o fluxo). Expected: a URL é salva (campo mantém o valor após recarregar); a importação falha com "Sem conexão com a função do calendário…" ou erro 404/… da função (ainda não publicada) e a mensagem aparece em vermelho; os blocos de mês, lista e assinatura aparecem; a grade mostra o mês atual começando na segunda; a lista diz "Nenhum evento neste mês."; os dois links de assinatura mostram `…/functions/v1/calendario/feed?token=<32 hex>` e `webcal://…`.
4. Clicar "Copiar" → botão vira "Copiado" por 1,5 s. Clicar "Gerar novo link" → confirmar → o token nos dois links muda.
5. Setas ‹ › mudam o título do mês e a grade; "Hoje" volta. Redimensionar para 375 px: grade cabe na largura, chips viram barrinhas.
6. Depois, para não deixar a URL falsa: o controlador anota que o Lucas vai colar a URL real na Tarefa 7.

- [ ] **Step 3: Commit**

```bash
git add calendario.html && git commit -m "Calendário: página com grade do mês, lista, botões por evento e assinatura

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

### Task 7: README, deploy da função e teste ponta a ponta

**Files:**
- Modify: `README.md` (nova seção "Calendário do Canvas" depois de "Cargos"; acrescentar `calendario.html`, `js/ics.js` e `supabase/functions/calendario/` na "Estrutura"; acrescentar o comando de teste do Deno em "Testar o backend localmente")

- [ ] **Step 1: README**

Na "Estrutura", acrescente as linhas (na ordem do bloco):

```
calendario.html     feed do Canvas, grade do mês, botões por evento e assinatura
js/ics.js           helpers de data e .ics para Google/Outlook/Apple
supabase/functions/calendario/  Edge Function: importa o feed do Canvas e serve o .ics de assinatura
```

Depois de "Cargos", a seção:

```markdown
## Calendário do Canvas

Cada aluno cola a URL do próprio feed do Canvas (Calendário → *Feed do calendário* → link `.ics`) na aba **Calendário**. O hub baixa o feed, guarda os eventos como calendário pessoal (só o dono vê), mostra a grade do mês e oferece:

- botões **Google**, **Outlook** e **Apple / .ics** em cada evento;
- um **link de assinatura** (`…/functions/v1/calendario/feed?token=…`) que Google Agenda, Apple Calendar e Outlook acompanham sozinhos. O link contém só um token aleatório; "Gerar novo link" invalida o antigo.

A importação roda ao abrir a aba quando a última tem mais de 6 horas, ou pelo botão *Atualizar agora*.

### Publicar a Edge Function

O download do feed e o link de assinatura precisam de um trecho de servidor: a função `calendario` em `supabase/functions/calendario/index.ts`.

1. Rode o `supabase/schema.sql` de novo no SQL Editor (o bloco do calendário é re-executável).
2. No painel: **Edge Functions → Deploy a new function → Via Editor**, nome `calendario`, cole o conteúdo de `index.ts`, **desligue "Verify JWT"** (a rota do feed é pública; a rota de importar confere o login sozinha) e publique.
3. Alternativa pela CLI: `brew install supabase/tap/supabase`, `supabase login`, `supabase functions deploy calendario --project-ref <ref> --no-verify-jwt`.

Nenhum segredo novo: a função recebe `SUPABASE_URL`, `SUPABASE_ANON_KEY` e `SUPABASE_SERVICE_ROLE_KEY` do próprio Supabase. A URL do feed do Canvas fica só na linha do dono em `calendario_config`.
```

Em "Testar o backend localmente", acrescente:

```
HUB_TESTE=1 deno test --allow-env supabase/functions/calendario/   # parser/gerador de .ics e rotas (precisa do Deno 2)
```

Commit:

```bash
git add README.md && git commit -m "README: seção do calendário do Canvas e deploy da função

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

- [ ] **Step 2: Passo do Lucas (o controlador pede)** — publicar a função pelo painel conforme o README (ou pela CLI). Confirmação pelo controlador: `curl -s -i "https://qjwkwnxyifizqmomfwie.supabase.co/functions/v1/calendario/feed"` deve responder `400` com `{"erro":"Token ausente ou inválido"}`; `curl -s -i -X POST …/calendario/importar` deve responder `401`.

- [ ] **Step 3: Ponta a ponta no navegador (controlador, com o Lucas logado no painel)**

1. `calendario.html`: o Lucas cola a URL real do feed dele no campo (é um segredo pessoal; ele digita) e clica **Salvar e importar**. Expected: "68 evento(s) importados do Canvas." e "Última importação: … · 68 evento(s)".
2. Grade: navegar até setembro e outubro de 2026 e ver chips nos dias com prazo; filtrar por "Cálculo II" reduz os chips; "todos" volta. Lista do mês agrupada por dia, hora ou "dia inteiro", selo do curso, "descrição" colapsada nos que têm.
3. Botões: "Google" abre `calendar.google.com/calendar/render?action=TEMPLATE&text=…&dates=…` numa aba nova com título e horário certos; "Outlook" abre o compose do Outlook; "Apple / .ics" baixa um arquivo `.ics` (no navegador do painel pode só aparecer o download).
4. Assinatura: `curl -s "<link https>" | head -20` mostra `BEGIN:VCALENDAR`, `X-WR-CALNAME:Hub de Estudos · <nome>` e `curl -s "<link>" | grep -c BEGIN:VEVENT` dá 68; o cabeçalho `Content-Type` é `text/calendar`. O Lucas assina no Google Agenda ou Apple Calendar e vê os prazos.
5. "Gerar novo link": o link antigo passa a responder 404; o novo responde 200.
6. Recarregar a página logo depois: não reimporta (última importação recente); "Atualizar agora" reimporta e mostra o mesmo total.
7. Publicar: `git push origin main` (o Lucas já autorizou publicar este trabalho) e conferir `https://lucascoelho74.github.io/hub-estudos/calendario.html` logado.

---

## Cobertura da spec (auto-revisão)

| Spec | Tarefa |
|---|---|
| 3.1 tabelas, 3.2 RLS, 3.3 `calendario_config_minha`, `salvar_feed_url`, `registrar_erro_importacao`, `novo_token_feed` | 1 |
| 3.3 `importar_eventos`, `listar_eventos`, `eventos_por_token` (+ revoke/grant) | 2 |
| 4.2 funções puras (`desdobrar`, `lerData`, `extrairCurso`, `lerEventos`, `escreverCalendario`) | 3 |
| 4.1 rotas, CORS, limites de download, `HUB_TESTE` | 4 |
| 5.1 arquivos, 5.2 `chamarFuncao`, cabeçalho, `js/ics.js`, CSS | 5 |
| 5.3 página (fonte, mês, lista, assinar), 5.4 erros | 6 |
| 6 deploy/README, 7.3 ponta a ponta | 7 |
| 7.1 testes SQL | 1–2 |
| 7.2 testes Deno | 3–4 |
