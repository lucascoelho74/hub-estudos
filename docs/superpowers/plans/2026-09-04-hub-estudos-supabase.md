# Hub de Estudos · Plataforma com Supabase — Plano de Implementação

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Transformar o site estático `hub-estudos` em uma plataforma de estudo com login, cargos, catálogo, favoritos, progresso, comentários e publicação de estudos, com toda a lógica no Supabase.

**Architecture:** Front em HTML/CSS/JS puro (cinco páginas + três JS compartilhados + um CSS de componentes) que só chama funções RPC, Auth e Storage do Supabase via `supabase-js` pelo CDN. Todo o backend está em `supabase/schema.sql` (tipos, tabelas, gatilhos, RLS, Storage, funções RPC, seed). O SQL é validado localmente num Postgres do Homebrew com um stub dos schemas `auth` e `storage`.

**Tech Stack:** HTML5, CSS3, JavaScript (ES2017, sem build), `@supabase/supabase-js@2` (CDN jsDelivr), Supabase (Postgres 17, Auth, Storage), Postgres 17 local via Homebrew só para testes, `python3 -m http.server` para servir.

**Spec:** `docs/superpowers/specs/2026-09-04-hub-estudos-supabase-design.md`

## Global Constraints

- Sem React, sem framework, sem bundler, sem npm. Só HTML, CSS e JS carregados por `<script src>`.
- O front nunca consulta tabela: só `chamar('<rpc>', params)`, `db.auth.*` e `db.storage.*`.
- Páginas não têm `<style>` nem `style=""`. Cores só via variáveis de `tema.css`; forma e layout só em `css/site.css`.
- Cargos: `aluno` | `monitor` | `professor`. Só `monitor` e `professor` publicam, revisam e excluem estudos.
- Domínios de e-mail aceitos: `sga.pucminas.br` e `pucminas.br` (tabela `dominios_permitidos`).
- Bucket do Storage: `estudos`, público para leitura, `text/html`, 5 MB.
- Mensagens de erro do backend em português, via `raise exception`.
- Textos da interface em português do Brasil.
- Commits em português, mensagem curta no imperativo, terminando com `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- `tema.css`, `estudos/` e `vendor/` não são alterados.

---

## Estrutura de arquivos

| Arquivo | Responsabilidade |
|---|---|
| `supabase/schema.sql` | Todo o backend. Colado no SQL Editor do Supabase. Idempotente. |
| `supabase/teste/stub.sql` | Stub local dos schemas `auth`, `storage` e `extensions` para testar fora do Supabase. |
| `supabase/teste/teste.sql` | Testes do backend: cada bloco levanta exceção se algo divergir. |
| `supabase/teste/rodar.sh` | Sobe Postgres local, recria o banco, roda stub + schema + teste. |
| `tema.css` | Paleta (já existe, não muda). |
| `css/site.css` | Componentes compartilhados do site. |
| `js/config.js` | URL e chave anon do projeto. |
| `js/util.js` | `esc`, `parametro`, `formatarData`, `slug`, `mostrarAviso`. |
| `js/supabase.js` | Cria `window.db`, `chamar()`, `traduzirErro()`, faixa de "não configurado". |
| `js/sessao.js` | `sessao()`, `limparSessao()`, `ehEquipe()`, `montarCabecalho()`, `exigirLogin()`, `exigirEquipe()`, `sair()`. |
| `index.html` | Catálogo com busca, chips de disciplina, favoritar. |
| `entrar.html` | Login e cadastro. |
| `estudo.html` | Painel do estudo, iframe, comentários, ações de equipe. |
| `publicar.html` | Publicar com upload; importar estudos do repositório. |
| `perfil.html` | Nome, cargo, favoritos, progresso, sair. |
| `README.md` | Configuração e uso. |
| `.gitignore` | `.DS_Store`. |
| `estudos.js` | **Removido** (lista vem do banco). |

Ordem de carga de scripts em toda página (sempre igual):

```html
<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
<script src="js/config.js"></script>
<script src="js/util.js"></script>
<script src="js/supabase.js"></script>
<script src="js/sessao.js"></script>
<script> /* script da página */ </script>
```

---

### Task 1: Postgres local com stub do Supabase

**Files:**
- Create: `supabase/teste/stub.sql`
- Create: `supabase/teste/rodar.sh`
- Create: `supabase/schema.sql` (vazio por enquanto, só o cabeçalho)
- Create: `supabase/teste/teste.sql` (só os helpers de teste)

**Interfaces:**
- Produces: `auth.users(id, email, raw_user_meta_data)`, `auth.uid()`, `auth.role()`, `storage.buckets`, `storage.objects`, roles `anon`/`authenticated`/`service_role`, schema `extensions`; helpers `teste.entrar(uuid)`, `teste.confere(boolean, text)`, `teste.espera_erro(text, text)`, `teste.id_estudo(text)`.
- O runner `supabase/teste/rodar.sh` é o comando de teste de todas as tarefas de backend.

- [ ] **Step 1: Instalar Postgres 17 pelo Homebrew**

Run: `brew install postgresql@17`
Expected: termina sem erro; `ls /opt/homebrew/opt/postgresql@17/bin/psql` existe. (Não precisa de `brew services`; o runner sobe o servidor sozinho numa porta própria.)

- [ ] **Step 2: Escrever o stub**

`supabase/teste/stub.sql`:

```sql
-- Stub mínimo do que o Supabase já traz pronto (auth, storage, extensions, roles).
-- Só para rodar schema.sql num Postgres local. Nunca colar isto no Supabase.
create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin bypassrls; end if;
end $$;

create schema if not exists auth;
create table if not exists auth.users (
  id uuid primary key default gen_random_uuid(),
  email text unique,
  raw_user_meta_data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
-- No Supabase, auth.uid() e auth.role() leem o JWT da requisição.
-- Aqui leem variáveis de sessão que o teste.sql define com set_config.
create or replace function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid
$$;
create or replace function auth.role() returns text language sql stable as $$
  select nullif(current_setting('request.jwt.claim.role', true), '')
$$;

create schema if not exists storage;
create table if not exists storage.buckets (
  id text primary key,
  name text not null,
  public boolean not null default false,
  file_size_limit bigint,
  allowed_mime_types text[],
  created_at timestamptz not null default now()
);
create table if not exists storage.objects (
  id uuid primary key default gen_random_uuid(),
  bucket_id text references storage.buckets(id),
  name text,
  owner uuid,
  created_at timestamptz not null default now()
);
alter table storage.objects enable row level security;

-- O Supabase concede tudo em public para os roles da API; replicamos.
grant usage on schema public, storage, extensions to anon, authenticated, service_role;
grant all on all tables in schema public to anon, authenticated, service_role;
grant all on all sequences in schema public to anon, authenticated, service_role;
grant execute on all functions in schema extensions to anon, authenticated, service_role;
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
grant all on storage.objects, storage.buckets to anon, authenticated, service_role;
```

- [ ] **Step 3: Escrever o runner**

`supabase/teste/rodar.sh`:

```bash
#!/bin/bash
# Roda schema.sql + teste.sql num Postgres local (Homebrew), com stub do Supabase.
# Uso: supabase/teste/rodar.sh          → roda os testes
#      supabase/teste/rodar.sh parar    → desliga o Postgres local
set -euo pipefail
cd "$(dirname "$0")/../.."
PG="$(brew --prefix postgresql@17)/bin"
DADOS="${TMPDIR:-/tmp}/hub-estudos-pg"
PORTA=5499

if [ "${1:-}" = "parar" ]; then "$PG/pg_ctl" -D "$DADOS" stop >/dev/null 2>&1 || true; echo "Postgres parado"; exit 0; fi

if [ ! -d "$DADOS" ]; then "$PG/initdb" -D "$DADOS" -U postgres --auth=trust -E UTF8 --locale=C >/dev/null; fi
"$PG/pg_isready" -h localhost -p $PORTA >/dev/null 2>&1 || \
  "$PG/pg_ctl" -D "$DADOS" -o "-p $PORTA -k $DADOS" -l "$DADOS/log" start >/dev/null
for _ in $(seq 1 30); do "$PG/pg_isready" -h localhost -p $PORTA >/dev/null 2>&1 && break; sleep 0.3; done

PSQL="$PG/psql -h localhost -p $PORTA -U postgres -v ON_ERROR_STOP=1 -q"
$PSQL -d postgres -c "drop database if exists hub_teste" -c "create database hub_teste"
$PSQL -d hub_teste -f supabase/teste/stub.sql
$PSQL -d hub_teste -f supabase/schema.sql
$PSQL -d hub_teste -1 -f supabase/teste/teste.sql
echo "OK: schema.sql e teste.sql passaram"
```

Run: `chmod +x supabase/teste/rodar.sh`

- [ ] **Step 4: Cabeçalho do schema e helpers do teste**

`supabase/schema.sql` (só isto por enquanto):

```sql
-- ============================================================
-- Hub de Estudos · backend completo (Supabase)
-- Cole este arquivo inteiro no SQL Editor do projeto e execute.
-- Pode ser executado de novo: tudo é "if not exists" / "or replace".
-- Ordem: extensões → tipos → tabelas → auxiliares → gatilhos →
--        RLS → Storage → funções RPC (a API do site) → seed
-- ============================================================
create schema if not exists extensions;
create extension if not exists unaccent with schema extensions;
```

`supabase/teste/teste.sql` (só os helpers; os cenários entram nas próximas tarefas):

```sql
-- Testes do backend. Roda dentro de UMA transação (psql -1).
-- Cada bloco levanta exceção quando algo diverge; o runner para no primeiro erro.
create schema if not exists teste;

-- Simula o JWT: usuário logado (authenticated) ou anônimo (null → anon).
create or replace function teste.entrar(usuario uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(usuario::text, ''), true);
  perform set_config('request.jwt.claim.role', case when usuario is null then 'anon' else 'authenticated' end, true);
end $$;

create or replace function teste.confere(condicao boolean, msg text) returns void language plpgsql as $$
begin
  if condicao is distinct from true then raise exception 'FALHOU: %', msg; end if;
end $$;

-- Executa um SQL e exige que ele dê erro.
create or replace function teste.espera_erro(sql text, msg text) returns void language plpgsql as $$
begin
  begin
    execute sql;
  exception when others then
    return;
  end;
  raise exception 'FALHOU (era para dar erro): %', msg;
end $$;

create or replace function teste.id_estudo(arquivo text) returns bigint language sql stable as $$
  select id from estudos where arquivo_url = 'estudos/' || arquivo
$$;

grant usage on schema teste to anon, authenticated;
grant execute on all functions in schema teste to anon, authenticated;

select teste.confere(true, 'helpers carregados');
```

- [ ] **Step 5: Rodar e ver falhar do jeito certo**

Run: `supabase/teste/rodar.sh`
Expected: falha em `teste.sql` com `relation "estudos" does not exist` (o helper `id_estudo` referencia a tabela que a Tarefa 2 cria). Isso prova que o Postgres sobe, o stub roda e o schema é aceito. Se falhar antes disso, o problema é o ambiente.

- [ ] **Step 6: Trocar o helper por uma versão que ainda não depende da tabela e ver passar**

Troque, em `teste.sql`, o corpo de `teste.id_estudo` por `select null::bigint` temporariamente. Run: `supabase/teste/rodar.sh`. Expected: `OK: schema.sql e teste.sql passaram`. Volte o corpo original (`select id from estudos where ...`) — a Tarefa 2 cria a tabela.

- [ ] **Step 7: Commit**

```bash
git add supabase/ && git commit -m "Adiciona Postgres local com stub do Supabase para testar o schema

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

### Task 2: Tipos, tabelas, auxiliares, gatilhos e seed

**Files:**
- Modify: `supabase/schema.sql` (acrescentar após o cabeçalho)
- Modify: `supabase/teste/teste.sql` (acrescentar cenários)

**Interfaces:**
- Consumes: stub da Tarefa 1.
- Produces: tipos `cargo`, `status_progresso`; tabelas `dominios_permitidos`, `perfis`, `disciplinas`, `estudos`, `favoritos`, `progresso`, `comentarios`; funções `email_permitido(text)`, `meu_cargo()`, `sou_equipe()`, `exigir_login()`, `exigir_equipe()`, `exigir_estudo(bigint)`; gatilhos em `auth.users` (validar e-mail, criar perfil) e `perfis` (proteger cargo); seed de domínios, disciplinas e 8 estudos.

- [ ] **Step 1: Escrever os testes do cadastro e do cargo**

Acrescente ao fim de `supabase/teste/teste.sql`:

```sql
-- ---------- Tarefa 2: cadastro, perfil, cargo, seed ----------
select teste.espera_erro($$insert into auth.users (email) values ('fulano@gmail.com')$$,
  'e-mail fora da PUC deve ser recusado no cadastro');
select teste.espera_erro($$insert into auth.users (email) values ('fulano@sga.pucminas.br.evil.com')$$,
  'domínio parecido deve ser recusado');

insert into auth.users (id, email, raw_user_meta_data) values
  ('11111111-1111-1111-1111-111111111111', 'ana@sga.pucminas.br', '{"nome":"Ana Aluna"}'),
  ('22222222-2222-2222-2222-222222222222', 'caio@sga.pucminas.br', '{"nome":"Caio Monitor"}'),
  ('33333333-3333-3333-3333-333333333333', 'Prof@PUCMINAS.BR', '{}');

select teste.confere((select nome from perfis where id = '11111111-1111-1111-1111-111111111111') = 'Ana Aluna', 'perfil criado com o nome do cadastro');
select teste.confere((select nome from perfis where id = '33333333-3333-3333-3333-333333333333') = 'Prof', 'sem nome, usa a parte antes do @');
select teste.confere((select cargo from perfis where id = '11111111-1111-1111-1111-111111111111') = 'aluno', 'cargo inicial é aluno');
select teste.confere((select count(*) from perfis) = 3, 'um perfil por usuário');

-- Promoção "pelo painel": sem JWT, auth.role() é nulo e o gatilho deixa passar.
update perfis set cargo = 'monitor' where id = '22222222-2222-2222-2222-222222222222';
update perfis set cargo = 'professor' where id = '33333333-3333-3333-3333-333333333333';
select teste.confere((select cargo from perfis where id = '22222222-2222-2222-2222-222222222222') = 'monitor', 'painel promove a monitor');

-- Usuário logado tentando mudar o próprio cargo: bloqueado pelo gatilho.
select teste.entrar('11111111-1111-1111-1111-111111111111');
select teste.espera_erro($$update perfis set cargo = 'professor' where id = '11111111-1111-1111-1111-111111111111'$$,
  'usuário logado não muda o próprio cargo');
update perfis set nome = 'Ana A.' where id = '11111111-1111-1111-1111-111111111111';
select teste.confere((select nome from perfis where id = '11111111-1111-1111-1111-111111111111') = 'Ana A.', 'logado pode mudar o nome');

-- Auxiliares
select teste.confere(meu_cargo() = 'aluno', 'meu_cargo do aluno');
select teste.confere(not sou_equipe(), 'aluno não é equipe');
select teste.espera_erro($$select exigir_equipe()$$, 'exigir_equipe barra aluno');
select teste.entrar('22222222-2222-2222-2222-222222222222');
select teste.confere(sou_equipe(), 'monitor é equipe');
select teste.entrar(null);
select teste.confere(meu_cargo() is null, 'anônimo não tem cargo');
select teste.espera_erro($$select exigir_login()$$, 'exigir_login barra anônimo');
select teste.confere(email_permitido('x@pucminas.br') and not email_permitido('x@gmail.com'), 'email_permitido');

-- Seed
select teste.confere((select count(*) from disciplinas) = 8, 'seed: 8 disciplinas');
select teste.confere((select count(*) from estudos) = 8, 'seed: 8 estudos');
select teste.confere((select count(*) from estudos where revisado) = 8, 'seed: estudos vêm revisados');
select teste.confere(teste.id_estudo('guia-integrais.html') is not null, 'seed: guia de integrais existe');
select teste.confere((select d.sigla from estudos e join disciplinas d on d.id = e.disciplina_id where e.id = teste.id_estudo('guia-integrais.html')) = 'CALC2', 'seed: guia está em CALC2');
select teste.espera_erro($$select exigir_estudo(999999)$$, 'exigir_estudo com id inexistente');
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `supabase/teste/rodar.sh`
Expected: falha em `teste.sql` (a primeira inserção em `auth.users` com e-mail do gmail **não** dá erro ainda → "FALHOU (era para dar erro)").

- [ ] **Step 3: Escrever tipos, tabelas, auxiliares, gatilhos e seed**

Acrescente ao fim de `supabase/schema.sql`:

```sql
-- ---------- tipos ----------
do $$ begin create type cargo as enum ('aluno', 'monitor', 'professor');
exception when duplicate_object then null; end $$;
do $$ begin create type status_progresso as enum ('estudando', 'concluido');
exception when duplicate_object then null; end $$;

-- ---------- tabelas ----------
create table if not exists dominios_permitidos (
  dominio text primary key
);

create table if not exists perfis (
  id uuid primary key references auth.users(id) on delete cascade,
  nome text not null,
  email text not null unique,
  cargo cargo not null default 'aluno',
  criado_em timestamptz not null default now()
);

create table if not exists disciplinas (
  id serial primary key,
  sigla text not null unique,
  nome text not null,
  periodo smallint
);

create table if not exists estudos (
  id bigint generated always as identity primary key,
  titulo text not null check (length(btrim(titulo)) between 1 and 140),
  descricao text not null default '' check (length(descricao) <= 1000),
  disciplina_id int references disciplinas(id),
  autor_id uuid references perfis(id) on delete set null,
  arquivo_url text not null check (arquivo_url <> ''),
  revisado boolean not null default false,
  publicado_em timestamptz not null default now()
);

create table if not exists favoritos (
  perfil_id uuid not null references perfis(id) on delete cascade,
  estudo_id bigint not null references estudos(id) on delete cascade,
  criado_em timestamptz not null default now(),
  primary key (perfil_id, estudo_id)
);

create table if not exists progresso (
  perfil_id uuid not null references perfis(id) on delete cascade,
  estudo_id bigint not null references estudos(id) on delete cascade,
  status status_progresso not null,
  atualizado_em timestamptz not null default now(),
  primary key (perfil_id, estudo_id)
);

create table if not exists comentarios (
  id bigint generated always as identity primary key,
  estudo_id bigint not null references estudos(id) on delete cascade,
  perfil_id uuid not null references perfis(id) on delete cascade,
  texto text not null check (length(btrim(texto)) between 1 and 2000),
  criado_em timestamptz not null default now()
);

-- ---------- auxiliares ----------
-- "security definer" = roda com os poderes do dono (postgres), ignorando RLS.
-- Usamos só em leituras pontuais que precisam ver perfis/domínios de outros.
create or replace function email_permitido(email text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from dominios_permitidos d where d.dominio = lower(split_part(email, '@', 2)));
$$;

create or replace function meu_cargo()
returns cargo language sql stable security definer set search_path = public as $$
  select cargo from perfis where id = auth.uid();
$$;

create or replace function sou_equipe()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(meu_cargo() in ('monitor', 'professor'), false);
$$;

create or replace function exigir_login()
returns void language plpgsql stable as $$
begin
  if auth.uid() is null then raise exception 'Faça login para continuar'; end if;
end $$;

create or replace function exigir_equipe()
returns void language plpgsql stable as $$
begin
  perform exigir_login();
  if not sou_equipe() then raise exception 'Só monitor ou professor pode fazer isso'; end if;
end $$;

create or replace function exigir_estudo(estudo bigint)
returns void language plpgsql stable security definer set search_path = public as $$
begin
  if not exists (select 1 from estudos where id = estudo) then raise exception 'Estudo não encontrado'; end if;
end $$;

-- ---------- gatilhos ----------
-- Antes de criar o usuário no Auth: só e-mail de domínio permitido.
create or replace function auth_validar_email()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if not email_permitido(new.email) then
    raise exception 'E-mail fora dos domínios permitidos';
  end if;
  return new;
end $$;
drop trigger if exists validar_email on auth.users;
create trigger validar_email before insert on auth.users
  for each row execute function auth_validar_email();

-- Depois de criar o usuário: cria o perfil com o nome informado no cadastro.
create or replace function auth_criar_perfil()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into perfis (id, nome, email)
  values (
    new.id,
    coalesce(nullif(btrim(new.raw_user_meta_data ->> 'nome'), ''), split_part(new.email, '@', 1)),
    lower(new.email)
  );
  return new;
end $$;
drop trigger if exists criar_perfil on auth.users;
create trigger criar_perfil after insert on auth.users
  for each row execute function auth_criar_perfil();

-- Cargo só muda pelo painel do Supabase (sem JWT). Sessão autenticada não pode.
create or replace function perfis_proteger_cargo()
returns trigger language plpgsql as $$
begin
  if new.cargo is distinct from old.cargo and auth.role() = 'authenticated' then
    raise exception 'O cargo só pode ser alterado pelo painel do Supabase';
  end if;
  return new;
end $$;
drop trigger if exists proteger_cargo on perfis;
create trigger proteger_cargo before update on perfis
  for each row execute function perfis_proteger_cargo();

-- ---------- seed ----------
insert into dominios_permitidos (dominio) values ('sga.pucminas.br'), ('pucminas.br')
on conflict do nothing;

insert into disciplinas (sigla, nome, periodo) values
  ('AEDS1', 'Algoritmos e Estruturas de Dados I', 1),
  ('CALC1', 'Cálculo I', 1),
  ('TI1',   'Trabalho Interdisciplinar I', 1),
  ('AEDS2', 'Algoritmos e Estruturas de Dados II', 2),
  ('CALC2', 'Cálculo II', 2),
  ('DIW',   'Desenvolvimento de Interfaces Web', 2),
  ('BD1',   'Banco de Dados I', 2),
  ('ES',    'Engenharia de Software', 2)
on conflict (sigla) do nothing;

-- Os 8 estudos que já existiam no site. arquivo_url relativa: a página
-- "Publicar → Importar" sobe cada um para o Storage e troca pela URL absoluta.
insert into estudos (titulo, descricao, disciplina_id, arquivo_url, revisado)
select v.titulo, v.descricao, d.id, v.arquivo, true
from (values
  ('Java · Primeiros passos',
   'O chão antes da POO: o que cada palavra do esqueleto faz, o que um import realmente é (e por que MyIO não é um), entrada e saída com Scanner e printf — incluindo o Locale que faz o juiz recusar código certo —, limites dos tipos, divisão inteira, == contra equals e StringBuilder.',
   'AEDS2', 'estudos/java-primeiros-passos.html'),
  ('Java · Resumo POO — AEDS II',
   'Resumo de programação orientada a objetos em Java: classes, encapsulamento, herança, polimorfismo, interfaces e coleções, com exemplos interativos.',
   'AEDS2', 'estudos/resumo-java-interativo.html'),
  ('Java · Conceitos Interativos',
   'Cinco mecanismos que confundem porque acontecem na memória. Aqui você opera cada um — clica, executa, avança passo a passo — e vê as setas mudarem de destino.',
   'AEDS2', 'estudos/conceitos-java-interativo.html'),
  ('Java · Para quem já sabe C/C++',
   'Só o que muda ao sair de C/C++ para Java: JVM e bytecode, tipos fixos, referências no lugar de ponteiros, strings, exceções e estruturas prontas.',
   'AEDS2', 'estudos/java-para-quem-sabe-c-cpp.html'),
  ('C e C++ · Resumo AEDS I (ED00–ED15)',
   'Revisão completa da disciplina seguindo os 16 estudos dirigidos: fundamentos de C, funções, recursão, arquivos, arranjos, structs e ponteiros, templates, classes/OO, exceções e estruturas encadeadas (pilha e fila). Com flashcards e quiz.',
   'AEDS1', 'estudos/resumo-c-cpp.html'),
  ('C/C++ · Simulado Geral (Verificações 01–03)',
   '60 questões no formato das provas, divididas em três blocos: abstrações de controle, abstrações de dados e orientação a objetos com estruturas encadeadas. Gabarito comentado ao final.',
   'AEDS1', 'estudos/questoes-de-c.html'),
  ('beecrowd · Trilha de treino em C e Java',
   'Quatro listas de problemas separadas por eixo: linguagem (sintaxe e API) e algoritmo (sacada e complexidade), em C e em Java. Cada problema abre aqui mesmo com enunciado, formato de entrada e saída e exemplo, além do que ele treina e da dificuldade — com progresso salvo no navegador.',
   'AEDS2', 'estudos/trilha-beecrowd-c-java.html'),
  ('Cálculo 2 · Guia de Integrais (Stewart)',
   'Seções 4.9 a 8.5 na ordem da lista de exercícios: primitivas, integral definida e TFC, substituição, áreas e volumes, técnicas de integração, aplicações e modelagem por soma de Riemann.',
   'CALC2', 'estudos/guia-integrais.html')
) as v(titulo, descricao, sigla, arquivo)
join disciplinas d on d.sigla = v.sigla
where not exists (select 1 from estudos e where e.arquivo_url = v.arquivo);
```

Observação: o seed fica no fim do arquivo depois que as Tarefas 3, 4 e 5 acrescentarem RLS, Storage e RPC **antes** dele. Mantenha o bloco `-- ---------- seed ----------` sempre como último bloco do arquivo (mova-o se necessário).

- [ ] **Step 4: Rodar e ver passar**

Run: `supabase/teste/rodar.sh`
Expected: `OK: schema.sql e teste.sql passaram`

- [ ] **Step 5: Commit**

```bash
git add supabase/ && git commit -m "Backend: tipos, tabelas, gatilhos de cadastro e cargo, seed

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

### Task 3: RLS e Storage

**Files:**
- Modify: `supabase/schema.sql` (inserir bloco RLS + Storage **antes** do seed)
- Modify: `supabase/teste/teste.sql` (acrescentar cenários)

**Interfaces:**
- Consumes: tabelas e `sou_equipe()` da Tarefa 2.
- Produces: RLS ligado nas 7 tabelas com as políticas da spec (seção 3.6); bucket `estudos` e políticas em `storage.objects`.

- [ ] **Step 1: Escrever os testes de acesso direto**

Acrescente ao fim de `supabase/teste/teste.sql`:

```sql
-- ---------- Tarefa 3: RLS e Storage (acesso direto às tabelas) ----------
-- "set local role" faz a sessão agir como o role da API; RLS passa a valer.
select teste.entrar('11111111-1111-1111-1111-111111111111');
set local role authenticated;
select teste.confere((select count(*) from perfis) = 1, 'aluno só enxerga o próprio perfil');
select teste.confere((select count(*) from dominios_permitidos) = 0, 'ninguém lê domínios direto');
select teste.confere((select count(*) from estudos) = 8, 'aluno lê todos os estudos');
select teste.confere((select count(*) from disciplinas) = 8, 'aluno lê disciplinas');
select teste.espera_erro($$insert into estudos (titulo, arquivo_url) values ('x', 'y')$$, 'aluno não insere estudo direto');
select teste.espera_erro($$delete from estudos where id = 1$$, 'aluno não apaga estudo direto');
insert into favoritos (perfil_id, estudo_id) values ('11111111-1111-1111-1111-111111111111', teste.id_estudo('questoes-de-c.html'));
select teste.espera_erro($$insert into favoritos (perfil_id, estudo_id) values ('22222222-2222-2222-2222-222222222222', 1)$$, 'aluno não favorita em nome de outro');
insert into comentarios (estudo_id, perfil_id, texto) values (teste.id_estudo('questoes-de-c.html'), '11111111-1111-1111-1111-111111111111', 'comentário direto da aluna');
select teste.espera_erro($$insert into comentarios (estudo_id, perfil_id, texto) values (1, '22222222-2222-2222-2222-222222222222', 'x')$$, 'aluno não comenta em nome de outro');
select teste.espera_erro($$insert into storage.objects (bucket_id, name) values ('estudos', 'x.html')$$, 'aluno não sobe arquivo no bucket');
reset role;

select teste.entrar('22222222-2222-2222-2222-222222222222');
set local role authenticated;
insert into estudos (titulo, descricao, arquivo_url) values ('Direto do monitor', '', 'https://x/estudos/m.html');
select teste.confere((select count(*) from estudos) = 9, 'monitor insere estudo direto');
delete from estudos where titulo = 'Direto do monitor';
insert into storage.objects (bucket_id, name) values ('estudos', 'm.html');
select teste.confere((select count(*) from storage.objects) = 1, 'monitor sobe arquivo no bucket');
delete from storage.objects where name = 'm.html';
delete from comentarios where texto = 'comentário direto da aluna';
select teste.confere((select count(*) from comentarios) = 0, 'equipe apaga comentário alheio direto');
reset role;

select teste.entrar(null);
set local role anon;
select teste.confere((select count(*) from estudos) = 8, 'anônimo lê estudos');
select teste.confere((select count(*) from perfis) = 0, 'anônimo não lê perfis');
select teste.confere((select count(*) from favoritos) = 0, 'anônimo não lê favoritos');
select teste.espera_erro($$insert into comentarios (estudo_id, perfil_id, texto) values (1, '11111111-1111-1111-1111-111111111111', 'x')$$, 'anônimo não comenta');
select teste.confere((select public from storage.buckets where id = 'estudos'), 'bucket estudos é público');
reset role;
delete from favoritos;  -- limpa para as próximas tarefas
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `supabase/teste/rodar.sh`
Expected: falha em "aluno só enxerga o próprio perfil" (sem RLS, o aluno vê os 3).

- [ ] **Step 3: Escrever RLS e Storage**

Insira em `supabase/schema.sql` **antes** do bloco `-- ---------- seed ----------`:

```sql
-- ---------- RLS (defesa em profundidade para acesso direto) ----------
-- O caminho oficial do site são as funções RPC. Estas políticas limitam o que
-- a chave anon consegue fazer direto nas tabelas.
alter table dominios_permitidos enable row level security;
alter table perfis enable row level security;
alter table disciplinas enable row level security;
alter table estudos enable row level security;
alter table favoritos enable row level security;
alter table progresso enable row level security;
alter table comentarios enable row level security;

-- Apaga políticas antigas para o arquivo poder ser rodado de novo.
do $$ declare p record; begin
  for p in select policyname, tablename from pg_policies
           where schemaname = 'public'
             and tablename in ('dominios_permitidos','perfis','disciplinas','estudos','favoritos','progresso','comentarios')
  loop execute format('drop policy %I on public.%I', p.policyname, p.tablename); end loop;
end $$;

-- dominios_permitidos: sem política = ninguém acessa direto (só via funções definer).

create policy perfis_ler_proprio on perfis for select to authenticated using (id = auth.uid());
create policy perfis_editar_proprio on perfis for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

create policy disciplinas_ler on disciplinas for select to anon, authenticated using (true);
create policy disciplinas_equipe_inserir on disciplinas for insert to authenticated with check (sou_equipe());
create policy disciplinas_equipe_editar on disciplinas for update to authenticated using (sou_equipe()) with check (sou_equipe());
create policy disciplinas_equipe_apagar on disciplinas for delete to authenticated using (sou_equipe());

create policy estudos_ler on estudos for select to anon, authenticated using (true);
create policy estudos_equipe_inserir on estudos for insert to authenticated with check (sou_equipe());
create policy estudos_equipe_editar on estudos for update to authenticated using (sou_equipe()) with check (sou_equipe());
create policy estudos_equipe_apagar on estudos for delete to authenticated using (sou_equipe());

create policy favoritos_ler_proprios on favoritos for select to authenticated using (perfil_id = auth.uid());
create policy favoritos_inserir_proprios on favoritos for insert to authenticated with check (perfil_id = auth.uid());
create policy favoritos_apagar_proprios on favoritos for delete to authenticated using (perfil_id = auth.uid());

create policy progresso_ler_proprio on progresso for select to authenticated using (perfil_id = auth.uid());
create policy progresso_inserir_proprio on progresso for insert to authenticated with check (perfil_id = auth.uid());
create policy progresso_editar_proprio on progresso for update to authenticated using (perfil_id = auth.uid()) with check (perfil_id = auth.uid());
create policy progresso_apagar_proprio on progresso for delete to authenticated using (perfil_id = auth.uid());

create policy comentarios_ler on comentarios for select to anon, authenticated using (true);
create policy comentarios_inserir_proprio on comentarios for insert to authenticated with check (perfil_id = auth.uid());
create policy comentarios_apagar on comentarios for delete to authenticated using (perfil_id = auth.uid() or sou_equipe());

-- ---------- Storage ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('estudos', 'estudos', true, 5242880, array['text/html'])
on conflict (id) do update
  set public = excluded.public, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists estudos_storage_ler on storage.objects;
drop policy if exists estudos_storage_inserir on storage.objects;
drop policy if exists estudos_storage_editar on storage.objects;
drop policy if exists estudos_storage_apagar on storage.objects;
create policy estudos_storage_ler on storage.objects for select to anon, authenticated using (bucket_id = 'estudos');
create policy estudos_storage_inserir on storage.objects for insert to authenticated with check (bucket_id = 'estudos' and public.sou_equipe());
create policy estudos_storage_editar on storage.objects for update to authenticated using (bucket_id = 'estudos' and public.sou_equipe()) with check (bucket_id = 'estudos' and public.sou_equipe());
create policy estudos_storage_apagar on storage.objects for delete to authenticated using (bucket_id = 'estudos' and public.sou_equipe());
```

- [ ] **Step 4: Rodar e ver passar**

Run: `supabase/teste/rodar.sh`
Expected: `OK: schema.sql e teste.sql passaram`

- [ ] **Step 5: Commit**

```bash
git add supabase/ && git commit -m "Backend: políticas RLS e bucket de estudos no Storage

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

### Task 4: Funções RPC de leitura

**Files:**
- Modify: `supabase/schema.sql` (inserir bloco **antes** do seed, depois do Storage)
- Modify: `supabase/teste/teste.sql`

**Interfaces:**
- Consumes: tabelas, `sou_equipe()`, `exigir_equipe()`.
- Produces (o front chama por `chamar(nome, params)`):
  - `estudo_json(estudo_id bigint) returns json` (interno, usado pelas outras)
  - `comentario_json(comentario_id bigint) returns json` (interno)
  - `listar_disciplinas() returns setof disciplinas`
  - `listar_dominios() returns setof text`
  - `buscar_estudos(texto text default '', disciplina text default null) returns setof json`
  - `painel_estudo(estudo bigint) returns json` → `{estudo, comentarios}` ou `null`
  - `meu_perfil() returns json` → `{id, nome, email, cargo, favoritos, progresso}` ou `null`
  - `estudos_para_importar() returns setof json` → `{id, titulo, arquivo_url}` (equipe)

Formato de `estudo_json`: `{id, titulo, descricao, disciplina_sigla, disciplina_nome, autor_nome, autor_cargo, revisado, publicado_em, arquivo_url, total_favoritos, total_comentarios, favoritado, progresso}`.
Formato de `comentario_json`: `{id, texto, criado_em, autor_nome, autor_cargo, meu}`.

- [ ] **Step 1: Escrever os testes de leitura**

Acrescente ao fim de `supabase/teste/teste.sql`:

```sql
-- ---------- Tarefa 4: RPC de leitura ----------
-- Dados de apoio: aluna favorita e comenta o guia; monitor comenta também.
insert into favoritos (perfil_id, estudo_id) values ('11111111-1111-1111-1111-111111111111', teste.id_estudo('guia-integrais.html'));
insert into progresso (perfil_id, estudo_id, status) values ('11111111-1111-1111-1111-111111111111', teste.id_estudo('guia-integrais.html'), 'estudando');
insert into comentarios (estudo_id, perfil_id, texto) values
  (teste.id_estudo('guia-integrais.html'), '11111111-1111-1111-1111-111111111111', 'Dúvida na seção 5.5'),
  (teste.id_estudo('guia-integrais.html'), '22222222-2222-2222-2222-222222222222', 'Respondi: veja o exemplo 3');

select teste.entrar(null);
set local role anon;
select teste.confere((select count(*) from buscar_estudos()) = 8, 'busca vazia lista os 8');
select teste.confere((select count(*) from buscar_estudos('calculo')) = 1, 'busca ignora acento (calculo acha Cálculo)');
select teste.confere((select count(*) from buscar_estudos('JAVA')) = 5, 'busca ignora maiúsculas (4 títulos Java + trilha beecrowd)');
select teste.confere((select count(*) from buscar_estudos('', 'AEDS1')) = 2, 'filtro por disciplina');
select teste.confere((select count(*) from buscar_estudos('java', 'AEDS1')) = 0, 'busca e filtro juntos');
select teste.confere((select count(*) from listar_disciplinas()) = 8, 'listar_disciplinas');
select teste.confere((select count(*) from listar_dominios()) = 2, 'listar_dominios traz os 2 domínios');
select teste.confere(meu_perfil() is null, 'anônimo não tem perfil');
select teste.confere(painel_estudo(999999) is null, 'painel de estudo inexistente é nulo');
select teste.espera_erro($$select * from estudos_para_importar()$$, 'anônimo não lista importação');
reset role;

-- Um estudo pela busca, do ponto de vista da aluna
select teste.entrar('11111111-1111-1111-1111-111111111111');
set local role authenticated;
select teste.confere((select j ->> 'favoritado' from buscar_estudos('integrais') j) = 'true', 'busca marca favoritado');
select teste.confere((select j ->> 'progresso' from buscar_estudos('integrais') j) = 'estudando', 'busca mostra progresso');
select teste.confere((select (j ->> 'total_comentarios')::int from buscar_estudos('integrais') j) = 2, 'busca conta comentários');
select teste.confere((select (j ->> 'total_favoritos')::int from buscar_estudos('integrais') j) = 1, 'busca conta favoritos');
select teste.confere((select j ->> 'disciplina_sigla' from buscar_estudos('integrais') j) = 'CALC2', 'busca traz a sigla');
select teste.confere((select j ->> 'favoritado' from buscar_estudos('simulado') j) = 'false', 'não favoritado vem false');

-- Painel do estudo
select teste.confere((painel_estudo(teste.id_estudo('guia-integrais.html')) -> 'estudo' ->> 'titulo') like 'Cálculo 2%', 'painel traz o estudo');
select teste.confere(json_array_length(painel_estudo(teste.id_estudo('guia-integrais.html')) -> 'comentarios') = 2, 'painel traz os comentários');
select teste.confere((painel_estudo(teste.id_estudo('guia-integrais.html')) -> 'comentarios' -> 0 ->> 'meu') = 'true', 'primeiro comentário é meu');
select teste.confere((painel_estudo(teste.id_estudo('guia-integrais.html')) -> 'comentarios' -> 1 ->> 'autor_cargo') = 'monitor', 'comentário do monitor traz o cargo');
select teste.confere((painel_estudo(teste.id_estudo('guia-integrais.html')) -> 'comentarios' -> 1 ->> 'meu') = 'false', 'comentário do monitor não é meu');

-- Meu perfil
select teste.confere((meu_perfil() ->> 'cargo') = 'aluno', 'meu_perfil traz o cargo');
select teste.confere(json_array_length(meu_perfil() -> 'favoritos') = 1, 'meu_perfil lista favoritos');
select teste.confere((meu_perfil() -> 'progresso' -> 0 ->> 'status') = 'estudando', 'meu_perfil lista progresso');
select teste.espera_erro($$select * from estudos_para_importar()$$, 'aluno não lista importação');
reset role;

select teste.entrar('22222222-2222-2222-2222-222222222222');
set local role authenticated;
select teste.confere((select count(*) from estudos_para_importar()) = 8, 'monitor lista os 8 para importar');
reset role;
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `supabase/teste/rodar.sh`
Expected: falha com `function buscar_estudos() does not exist`.

- [ ] **Step 3: Escrever as funções de leitura**

Insira em `supabase/schema.sql` depois do bloco Storage e **antes** do seed:

```sql
-- ---------- RPC de leitura (a API do site) ----------
-- Todas "security definer": precisam juntar perfis (nome/cargo do autor) sem
-- expor a tabela inteira. Devolvem JSON já no formato que a página desenha.

create or replace function estudo_json(estudo_id bigint)
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'id', e.id,
    'titulo', e.titulo,
    'descricao', e.descricao,
    'disciplina_sigla', d.sigla,
    'disciplina_nome', d.nome,
    'autor_nome', p.nome,
    'autor_cargo', p.cargo,
    'revisado', e.revisado,
    'publicado_em', e.publicado_em,
    'arquivo_url', e.arquivo_url,
    'total_favoritos', (select count(*) from favoritos f where f.estudo_id = e.id),
    'total_comentarios', (select count(*) from comentarios c where c.estudo_id = e.id),
    'favoritado', exists (select 1 from favoritos f where f.estudo_id = e.id and f.perfil_id = auth.uid()),
    'progresso', (select pr.status from progresso pr where pr.estudo_id = e.id and pr.perfil_id = auth.uid())
  )
  from estudos e
  left join disciplinas d on d.id = e.disciplina_id
  left join perfis p on p.id = e.autor_id
  where e.id = estudo_id;
$$;

create or replace function comentario_json(comentario_id bigint)
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'id', c.id,
    'texto', c.texto,
    'criado_em', c.criado_em,
    'autor_nome', p.nome,
    'autor_cargo', p.cargo,
    'meu', coalesce(c.perfil_id = auth.uid(), false)
  )
  from comentarios c
  left join perfis p on p.id = c.perfil_id
  where c.id = comentario_id;
$$;

create or replace function listar_disciplinas()
returns setof disciplinas language sql stable security definer set search_path = public as $$
  select * from disciplinas order by periodo nulls last, sigla;
$$;

create or replace function listar_dominios()
returns setof text language sql stable security definer set search_path = public as $$
  select dominio from dominios_permitidos order by dominio;
$$;

-- Busca sem acento e sem maiúsculas, com filtro opcional por sigla da disciplina.
create or replace function buscar_estudos(texto text default '', disciplina text default null)
returns setof json language sql stable security definer set search_path = public, extensions as $$
  select estudo_json(e.id)
  from estudos e
  left join disciplinas d on d.id = e.disciplina_id
  where (coalesce(btrim(texto), '') = ''
         or unaccent(e.titulo || ' ' || e.descricao) ilike '%' || unaccent(btrim(texto)) || '%')
    and (coalesce(disciplina, '') = '' or d.sigla = disciplina)
  order by e.publicado_em desc, e.id desc;
$$;

create or replace function painel_estudo(estudo bigint)
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'estudo', estudo_json(e.id),
    'comentarios', coalesce(
      (select json_agg(comentario_json(c.id) order by c.criado_em, c.id) from comentarios c where c.estudo_id = e.id),
      '[]'::json)
  )
  from estudos e where e.id = estudo;
$$;

create or replace function meu_perfil()
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'id', p.id,
    'nome', p.nome,
    'email', p.email,
    'cargo', p.cargo,
    'favoritos', coalesce((
      select json_agg(json_build_object('id', e.id, 'titulo', e.titulo, 'disciplina_sigla', d.sigla) order by f.criado_em desc)
      from favoritos f join estudos e on e.id = f.estudo_id left join disciplinas d on d.id = e.disciplina_id
      where f.perfil_id = p.id), '[]'::json),
    'progresso', coalesce((
      select json_agg(json_build_object('id', e.id, 'titulo', e.titulo, 'disciplina_sigla', d.sigla, 'status', pr.status) order by pr.atualizado_em desc)
      from progresso pr join estudos e on e.id = pr.estudo_id left join disciplinas d on d.id = e.disciplina_id
      where pr.perfil_id = p.id), '[]'::json)
  )
  from perfis p where p.id = auth.uid();
$$;

create or replace function estudos_para_importar()
returns setof json language plpgsql stable security definer set search_path = public as $$
begin
  perform exigir_equipe();
  return query
    select json_build_object('id', e.id, 'titulo', e.titulo, 'arquivo_url', e.arquivo_url)
    from estudos e where e.arquivo_url not ilike 'http%' order by e.id;
end $$;
```

- [ ] **Step 4: Rodar e ver passar**

Run: `supabase/teste/rodar.sh`
Expected: `OK: schema.sql e teste.sql passaram`

- [ ] **Step 5: Commit**

```bash
git add supabase/ && git commit -m "Backend: funções RPC de leitura (busca, painel, perfil)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

### Task 5: Funções RPC de escrita

**Files:**
- Modify: `supabase/schema.sql` (inserir bloco depois das leituras, **antes** do seed)
- Modify: `supabase/teste/teste.sql`

**Interfaces:**
- Consumes: `exigir_login()`, `exigir_equipe()`, `exigir_estudo()`, `sou_equipe()`, `comentario_json()`.
- Produces (todas rodam como o chamador, então RLS também vale):
  - `alternar_favorito(estudo bigint) returns boolean` — novo estado
  - `marcar_progresso(estudo bigint, novo_status status_progresso) returns status_progresso` — `null` remove
  - `comentar(estudo bigint, texto text) returns json` — formato `comentario_json`
  - `excluir_comentario(comentario bigint) returns void`
  - `publicar_estudo(titulo text, descricao text, disciplina_sigla text, arquivo_url text) returns bigint`
  - `atualizar_arquivo(estudo bigint, nova_url text) returns void`
  - `marcar_revisado(estudo bigint, valor boolean) returns void`
  - `excluir_estudo(estudo bigint) returns text` — caminho do objeto no bucket, ou `null`
  - `atualizar_nome(novo_nome text) returns void`

- [ ] **Step 1: Escrever os testes de escrita**

Acrescente ao fim de `supabase/teste/teste.sql`:

```sql
-- ---------- Tarefa 5: RPC de escrita ----------
delete from favoritos; delete from progresso; delete from comentarios;  -- começa limpo

select teste.entrar(null);
set local role anon;
select teste.espera_erro($$select alternar_favorito(1)$$, 'anônimo não favorita');
select teste.espera_erro($$select comentar(1, 'oi')$$, 'anônimo não comenta');
select teste.espera_erro($$select atualizar_nome('x')$$, 'anônimo não muda nome');
reset role;

-- Aluna
select teste.entrar('11111111-1111-1111-1111-111111111111');
set local role authenticated;
do $$
declare guia bigint := teste.id_estudo('guia-integrais.html'); c json;
begin
  perform teste.confere(alternar_favorito(guia) = true, 'favoritar liga');
  perform teste.confere(alternar_favorito(guia) = false, 'favoritar de novo desliga');
  perform teste.confere(alternar_favorito(guia) = true, 'favoritar liga outra vez');
  perform teste.confere((select count(*) from favoritos) = 1, 'um favorito só');
  perform teste.espera_erro('select alternar_favorito(999999)', 'favoritar estudo inexistente');

  perform teste.confere(marcar_progresso(guia, 'estudando') = 'estudando', 'progresso estudando');
  perform teste.confere(marcar_progresso(guia, 'concluido') = 'concluido', 'progresso concluído (upsert)');
  perform teste.confere((select count(*) from progresso) = 1, 'upsert não duplica');
  perform teste.confere((select status from progresso where estudo_id = guia) = 'concluido', 'status atualizado');
  perform teste.confere(marcar_progresso(guia, null) is null, 'progresso nulo remove');
  perform teste.confere((select count(*) from progresso) = 0, 'linha removida');
  perform teste.espera_erro('select marcar_progresso(999999, ''estudando'')', 'progresso em estudo inexistente');

  c := comentar(guia, '  Ótimo material!  ');
  perform teste.confere((c ->> 'texto') = 'Ótimo material!', 'comentar apara espaços');
  perform teste.confere((c ->> 'meu') = 'true', 'comentário devolvido é meu');
  perform teste.confere((c ->> 'autor_nome') = 'Ana A.', 'comentário traz o autor');
  perform teste.espera_erro('select comentar(' || guia || ', ''   '')', 'comentário vazio é recusado');
  perform teste.espera_erro('select comentar(' || guia || ', repeat(''x'', 2001))', 'comentário longo é recusado');

  perform teste.espera_erro('select publicar_estudo(''T'', ''D'', ''AEDS1'', ''https://x/y.html'')', 'aluno não publica');
  perform teste.espera_erro('select marcar_revisado(' || guia || ', true)', 'aluno não revisa');
  perform teste.espera_erro('select excluir_estudo(' || guia || ')', 'aluno não exclui estudo');
  perform teste.espera_erro('select atualizar_arquivo(' || guia || ', ''https://x'')', 'aluno não troca arquivo');

  perform teste.espera_erro('select atualizar_nome(''  '')', 'nome vazio é recusado');
  perform atualizar_nome('Ana Silva');
  perform teste.confere((meu_perfil() ->> 'nome') = 'Ana Silva', 'nome atualizado');
end $$;
reset role;

-- Monitor
select teste.entrar('22222222-2222-2222-2222-222222222222');
set local role authenticated;
do $$
declare novo bigint; caminho text; guia bigint := teste.id_estudo('guia-integrais.html');
begin
  perform teste.espera_erro('select publicar_estudo('''', ''D'', ''AEDS1'', ''https://x/y.html'')', 'título vazio é recusado');
  perform teste.espera_erro('select publicar_estudo(''T'', ''D'', ''NAOEXISTE'', ''https://x/y.html'')', 'disciplina inválida é recusada');
  perform teste.espera_erro('select publicar_estudo(''T'', ''D'', ''AEDS1'', '''')', 'arquivo vazio é recusado');

  novo := publicar_estudo('  Novo estudo  ', 'Descrição', 'DIW',
    'https://proj.supabase.co/storage/v1/object/public/estudos/123-novo.html');
  perform teste.confere((select titulo from estudos where id = novo) = 'Novo estudo', 'publicar apara o título');
  perform teste.confere((select autor_id from estudos where id = novo) = auth.uid(), 'autor é quem publicou');
  perform teste.confere((select revisado from estudos where id = novo) = false, 'novo estudo começa sem revisão');

  perform marcar_revisado(novo, true);
  perform teste.confere((select revisado from estudos where id = novo), 'marcar_revisado liga');
  perform atualizar_arquivo(novo, 'https://proj.supabase.co/storage/v1/object/public/estudos/123-novo-v2.html');
  perform teste.espera_erro('select atualizar_arquivo(999999, ''https://x'')', 'atualizar_arquivo de inexistente');

  perform comentar(guia, 'Comentário do monitor');
  -- equipe apaga comentário alheio
  perform excluir_comentario((select id from comentarios where perfil_id = '11111111-1111-1111-1111-111111111111'));
  perform teste.confere((select count(*) from comentarios where perfil_id = '11111111-1111-1111-1111-111111111111') = 0, 'equipe apaga comentário alheio');

  caminho := excluir_estudo(novo);
  perform teste.confere(caminho = '123-novo-v2.html', 'excluir devolve o caminho no bucket');
  perform teste.confere(not exists (select 1 from estudos where id = novo), 'estudo apagado');
  perform teste.confere(excluir_estudo(teste.id_estudo('questoes-de-c.html')) is null, 'estudo do repositório devolve null');
  perform teste.espera_erro('select excluir_estudo(999999)', 'excluir inexistente dá erro');
  perform teste.confere((select count(*) from estudos_para_importar()) = 7, 'sobraram 7 para importar');
end $$;
reset role;

-- Aluna não apaga comentário do monitor
select teste.entrar('11111111-1111-1111-1111-111111111111');
set local role authenticated;
select teste.espera_erro($$select excluir_comentario((select id from comentarios where perfil_id = '22222222-2222-2222-2222-222222222222'))$$,
  'aluna não apaga comentário do monitor');
select teste.confere((select count(*) from comentarios) = 1, 'comentário do monitor continua lá');
reset role;
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `supabase/teste/rodar.sh`
Expected: falha com `function alternar_favorito(integer) does not exist`.

- [ ] **Step 3: Escrever as funções de escrita**

Insira em `supabase/schema.sql` depois das leituras e **antes** do seed:

```sql
-- ---------- RPC de escrita ----------
-- Rodam como o chamador (security invoker, o padrão): a checagem de cargo é
-- explícita aqui E as políticas RLS valem por baixo.
-- "#variable_conflict use_variable": se um parâmetro tiver o mesmo nome de uma
-- coluna, vale o parâmetro.

create or replace function alternar_favorito(estudo bigint)
returns boolean language plpgsql as $$
begin
  perform exigir_login();
  perform exigir_estudo(estudo);
  delete from favoritos where perfil_id = auth.uid() and estudo_id = estudo;
  if found then return false; end if;
  insert into favoritos (perfil_id, estudo_id) values (auth.uid(), estudo);
  return true;
end $$;

create or replace function marcar_progresso(estudo bigint, novo_status status_progresso)
returns status_progresso language plpgsql as $$
begin
  perform exigir_login();
  perform exigir_estudo(estudo);
  if novo_status is null then
    delete from progresso where perfil_id = auth.uid() and estudo_id = estudo;
    return null;
  end if;
  insert into progresso (perfil_id, estudo_id, status, atualizado_em)
  values (auth.uid(), estudo, novo_status, now())
  on conflict (perfil_id, estudo_id) do update set status = excluded.status, atualizado_em = now();
  return novo_status;
end $$;

create or replace function comentar(estudo bigint, texto text)
returns json language plpgsql as $$
#variable_conflict use_variable
declare novo_id bigint;
begin
  perform exigir_login();
  perform exigir_estudo(estudo);
  if length(btrim(coalesce(texto, ''))) < 1 then raise exception 'Escreva algo antes de enviar'; end if;
  if length(btrim(texto)) > 2000 then raise exception 'Comentário muito longo (máximo 2000 caracteres)'; end if;
  insert into comentarios (estudo_id, perfil_id, texto) values (estudo, auth.uid(), btrim(texto))
  returning id into novo_id;
  return comentario_json(novo_id);
end $$;

create or replace function excluir_comentario(comentario bigint)
returns void language plpgsql as $$
begin
  perform exigir_login();
  delete from comentarios where id = comentario and (perfil_id = auth.uid() or sou_equipe());
  if not found then raise exception 'Comentário não encontrado ou sem permissão para excluir'; end if;
end $$;

create or replace function publicar_estudo(titulo text, descricao text, disciplina_sigla text, arquivo_url text)
returns bigint language plpgsql as $$
#variable_conflict use_variable
declare did int; novo_id bigint;
begin
  perform exigir_equipe();
  if length(btrim(coalesce(titulo, ''))) not between 1 and 140 then raise exception 'O título deve ter entre 1 e 140 caracteres'; end if;
  if length(coalesce(descricao, '')) > 1000 then raise exception 'A descrição deve ter no máximo 1000 caracteres'; end if;
  if coalesce(btrim(arquivo_url), '') = '' then raise exception 'Informe o arquivo do estudo'; end if;
  select id into did from disciplinas where sigla = disciplina_sigla;
  if did is null then raise exception 'Disciplina inválida'; end if;
  insert into estudos (titulo, descricao, disciplina_id, autor_id, arquivo_url)
  values (btrim(titulo), btrim(coalesce(descricao, '')), did, auth.uid(), btrim(arquivo_url))
  returning id into novo_id;
  return novo_id;
end $$;

create or replace function atualizar_arquivo(estudo bigint, nova_url text)
returns void language plpgsql as $$
begin
  perform exigir_equipe();
  if coalesce(btrim(nova_url), '') = '' then raise exception 'URL vazia'; end if;
  update estudos set arquivo_url = btrim(nova_url) where id = estudo;
  if not found then raise exception 'Estudo não encontrado'; end if;
end $$;

create or replace function marcar_revisado(estudo bigint, valor boolean)
returns void language plpgsql as $$
begin
  perform exigir_equipe();
  update estudos set revisado = coalesce(valor, false) where id = estudo;
  if not found then raise exception 'Estudo não encontrado'; end if;
end $$;

-- Devolve o caminho do objeto no bucket (a página apaga o arquivo pela API do
-- Storage; apagar direto em storage.objects deixaria o arquivo órfão).
create or replace function excluir_estudo(estudo bigint)
returns text language plpgsql as $$
declare url text;
begin
  perform exigir_equipe();
  delete from estudos where id = estudo returning arquivo_url into url;
  if url is null then raise exception 'Estudo não encontrado'; end if;
  return substring(url from '/storage/v1/object/public/estudos/(.+)$');
end $$;

create or replace function atualizar_nome(novo_nome text)
returns void language plpgsql as $$
begin
  perform exigir_login();
  if length(btrim(coalesce(novo_nome, ''))) not between 1 and 80 then raise exception 'O nome deve ter entre 1 e 80 caracteres'; end if;
  update perfis set nome = btrim(novo_nome) where id = auth.uid();
end $$;
```

- [ ] **Step 4: Rodar e ver passar**

Run: `supabase/teste/rodar.sh`
Expected: `OK: schema.sql e teste.sql passaram`

- [ ] **Step 5: Rodar o schema duas vezes seguidas (idempotência)**

Run: `PG="$(brew --prefix postgresql@17)/bin"; $PG/psql -h localhost -p 5499 -U postgres -v ON_ERROR_STOP=1 -q -d hub_teste -f supabase/schema.sql && echo "segunda execução OK"`
Expected: `segunda execução OK` (nenhum erro de "already exists"). Depois, `select count(*) from estudos` deve dar 8: o seed repõe só o estudo que o teste apagou (a checagem é por `arquivo_url`) e não duplica os outros 7.

- [ ] **Step 6: Commit**

```bash
git add supabase/ && git commit -m "Backend: funções RPC de escrita (favoritos, progresso, comentários, publicação)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: CSS, JS compartilhado e página inicial

**Files:**
- Create: `css/site.css`
- Create: `js/config.js`, `js/util.js`, `js/supabase.js`, `js/sessao.js`
- Modify: `index.html` (substituir inteiro)
- Delete: `estudos.js`
- Create: `.gitignore`, `.claude/launch.json`

**Interfaces:**
- Consumes: RPCs `buscar_estudos`, `listar_disciplinas`, `alternar_favorito`, `meu_perfil`.
- Produces (globais em `window`): `esc(s)`, `parametro(nome)`, `formatarData(iso)`, `slug(s)`, `mostrarAviso(el, msg, tipo)`, `db`, `chamar(nome, params)`, `traduzirErro(erro)`, `sessao()`, `limparSessao()`, `ehEquipe(perfil)`, `montarCabecalho()`, `exigirLogin()`, `exigirEquipe()`, `sair()`. Classes CSS listadas em `css/site.css`.

Teste desta e das próximas tarefas de front: servir a pasta e abrir no navegador. Sem `js/config.js` preenchido, toda página deve renderizar com a faixa "Backend não configurado" no topo e **nenhum erro no console** além dessa mensagem.

- [ ] **Step 1: Servidor local para o navegador**

`.claude/launch.json`:

```json
{
  "version": "0.0.1",
  "configurations": [
    { "name": "hub", "runtimeExecutable": "python3", "runtimeArgs": ["-m", "http.server", "8000"], "port": 8000 }
  ]
}
```

`.gitignore`:

```
.DS_Store
```

- [ ] **Step 2: `js/config.js`**

```js
// Dados do projeto Supabase (Project Settings → API).
// A chave "anon" é pública por desenho: vai para o navegador de todo mundo.
// A segurança está nas políticas RLS do banco, não nesta chave.
window.CONFIG = {
  SUPABASE_URL: 'COLE_AQUI_A_URL_DO_PROJETO',
  SUPABASE_ANON_KEY: 'COLE_AQUI_A_CHAVE_ANON'
};
```

- [ ] **Step 3: `js/util.js`**

```js
// Funções pequenas usadas por todas as páginas.

// Escapa texto para colocar dentro de innerHTML sem risco de injeção.
window.esc = function (s) {
  var d = document.createElement('div');
  d.textContent = s == null ? '' : String(s);
  return d.innerHTML;
};

// parametro('id') → valor de ?id=... na URL, ou null.
window.parametro = function (nome) {
  return new URLSearchParams(location.search).get(nome);
};

window.formatarData = function (iso) {
  var d = new Date(iso);
  return isNaN(d) ? '' : d.toLocaleDateString('pt-BR', { day: '2-digit', month: 'short', year: 'numeric' });
};

// slug('Cálculo 2 · Guia') → 'calculo-2-guia' (para nome de arquivo no Storage).
window.slug = function (s) {
  return String(s).normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase()
    .replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 60) || 'estudo';
};

// mostrarAviso(el, 'mensagem', 'ok' | 'erro'); mensagem vazia esconde.
window.mostrarAviso = function (el, msg, tipo) {
  el.textContent = msg || '';
  el.className = 'aviso ' + (tipo === 'ok' ? 'aviso-ok' : 'aviso-erro');
  el.hidden = !msg;
};
```

- [ ] **Step 4: `js/supabase.js`**

```js
// Cria o cliente do Supabase (window.db) e chamar(): a única forma de o site
// falar com o backend. Carregar depois do CDN, de config.js e de util.js.
(function () {
  var cfg = window.CONFIG || {};
  var configurado = /^https?:\/\//.test(cfg.SUPABASE_URL || '') && (cfg.SUPABASE_ANON_KEY || '').indexOf('COLE_') !== 0;
  window.db = configurado ? supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_ANON_KEY) : null;

  var TRADUCOES = {
    'Invalid login credentials': 'E-mail ou senha incorretos',
    'Database error saving new user': 'E-mail fora dos domínios permitidos (use o e-mail da PUC)',
    'User already registered': 'Este e-mail já tem cadastro',
    'Password should be at least 6 characters': 'A senha precisa ter pelo menos 6 caracteres',
    'Email not confirmed': 'Confirme o e-mail antes de entrar',
    'The resource already exists': 'Já existe um arquivo com esse nome no Storage',
    'mime type': 'O arquivo precisa ser HTML',
    'exceeded the maximum allowed size': 'Arquivo maior que 5 MB',
    'Failed to fetch': 'Sem conexão com o servidor'
  };

  window.traduzirErro = function (erro) {
    var msg = (erro && erro.message) || String(erro);
    for (var chave in TRADUCOES) if (msg.indexOf(chave) >= 0) return TRADUCOES[chave];
    return msg;
  };

  // chamar('buscar_estudos', {texto: 'java'}) → dados; erro vira Error em português.
  window.chamar = async function (nome, params) {
    if (!window.db) throw new Error('Backend não configurado: preencha js/config.js');
    var r = await db.rpc(nome, params || {});
    if (r.error) throw new Error(traduzirErro(r.error));
    return r.data;
  };

  if (!window.db) {
    document.addEventListener('DOMContentLoaded', function () {
      var faixa = document.createElement('div');
      faixa.className = 'aviso aviso-erro aviso-topo';
      faixa.textContent = 'Backend não configurado: preencha js/config.js com a URL e a chave anon do projeto Supabase.';
      document.body.prepend(faixa);
    });
  }
})();
```

- [ ] **Step 5: `js/sessao.js`**

```js
// Sessão: quem está logado, seu perfil (com cargo), cabeçalho e guardas de página.
(function () {
  var XICARA = '<svg class="cabecalho-xicara" viewBox="0 0 48 44" aria-hidden="true">' +
    '<path d="M8 15 h26 v13 a11 11 0 0 1 -11 11 h-4 a11 11 0 0 1 -11 -11 z" fill="none" stroke="var(--bean)" stroke-width="2.4"/>' +
    '<path d="M34 18 h4 a6 6 0 0 1 0 12 h-3" fill="none" stroke="var(--bean)" stroke-width="2.4"/>' +
    '<path d="M15 4 c-2 3 2 5 0 8 M21 3 c-2 3 2 5 0 8 M27 4 c-2 3 2 5 0 8" fill="none" stroke="var(--steam)" stroke-width="2" stroke-linecap="round" opacity=".8"/></svg>';
  var promessa = null;

  // sessao() → {usuario, perfil}. Ambos null se anônimo. Uma consulta por página.
  window.sessao = function () {
    if (!promessa) promessa = carregar();
    return promessa;
  };
  async function carregar() {
    if (!window.db) return { usuario: null, perfil: null };
    var r = await db.auth.getSession();
    var usuario = r.data && r.data.session ? r.data.session.user : null;
    var perfil = null;
    if (usuario) { try { perfil = await chamar('meu_perfil'); } catch (e) { perfil = null; } }
    return { usuario: usuario, perfil: perfil };
  }
  window.limparSessao = function () { promessa = null; };
  window.ehEquipe = function (perfil) { return !!perfil && (perfil.cargo === 'monitor' || perfil.cargo === 'professor'); };

  window.montarCabecalho = async function () {
    var el = document.getElementById('cabecalho');
    if (!el) return;
    var s = await sessao();
    var links = '<a href="index.html">Início</a>';
    if (ehEquipe(s.perfil)) links += '<a href="publicar.html">Publicar</a>';
    if (s.usuario) links += '<a href="perfil.html" class="cabecalho-usuario">' + esc(s.perfil ? s.perfil.nome : s.usuario.email) + '</a>';
    else links += '<a href="entrar.html" class="botao botao-pequeno">Entrar</a>';
    el.innerHTML = '<a class="cabecalho-marca" href="index.html">' + XICARA + '<span>Hub de Estudos</span></a>' +
      '<nav class="cabecalho-links">' + links + '</nav>';
  };

  // Nome da página atual + query, para voltar depois do login.
  function paginaAtual() { return location.pathname.split('/').pop() + location.search; }

  window.exigirLogin = async function () {
    var s = await sessao();
    if (!s.usuario) { location.href = 'entrar.html?voltar=' + encodeURIComponent(paginaAtual()); return null; }
    return s;
  };
  window.exigirEquipe = async function () {
    var s = await exigirLogin();
    if (s && !ehEquipe(s.perfil)) { location.href = 'index.html?aviso=so-equipe'; return null; }
    return s;
  };
  window.sair = async function () {
    if (window.db) await db.auth.signOut();
    limparSessao();
    location.href = 'index.html';
  };
})();
```

- [ ] **Step 6: `css/site.css`**

```css
/* ============================================================
   site.css — componentes compartilhados do Hub de Estudos.
   Cores vêm SÓ do tema.css (variáveis). Aqui ficam forma, espaçamento
   e layout. As páginas não têm <style> nem style="".
   ============================================================ */

*{box-sizing:border-box}
html{scroll-behavior:smooth}
body{margin:0;background:var(--ink);color:var(--fg);font-family:var(--sans);font-size:16px;line-height:1.6;-webkit-font-smoothing:antialiased;min-height:100vh}
a{color:inherit;text-decoration:none}
button{font:inherit}
[hidden]{display:none!important}

/* ---------- cabeçalho ---------- */
.cabecalho{display:flex;align-items:center;justify-content:space-between;gap:16px;padding:16px 22px;border-bottom:1px solid var(--line);background:var(--ink-2)}
.cabecalho-marca{display:flex;align-items:center;gap:10px;font-weight:700;letter-spacing:.12em;text-transform:uppercase;font-size:14px}
.cabecalho-xicara{width:34px;height:34px}
.cabecalho-links{display:flex;align-items:center;gap:18px;font-size:14px;color:var(--fg-dim)}
.cabecalho-links a:hover{color:var(--fg-strong)}
.cabecalho-usuario{color:var(--crema);font-weight:600}

/* ---------- área de conteúdo ---------- */
.conteudo{max-width:1080px;margin:0 auto;padding:28px 22px 90px}
.conteudo-estreito{max-width:560px}
.titulo-pagina{font-size:clamp(26px,4vw,38px);line-height:1.1;margin:0 0 8px;font-weight:800;letter-spacing:-.02em}
.titulo-pagina .destaque{background:linear-gradient(120deg,var(--crema),var(--bean) 55%,var(--steam));-webkit-background-clip:text;background-clip:text;color:transparent}
.subtitulo{color:var(--fg-dim);margin:0 0 24px}
.secao{margin-top:36px}
.secao h2{font-size:18px;margin:0 0 12px}
.discreto{color:var(--fg-faint);font-size:13px}

/* ---------- botões ---------- */
.botao{display:inline-flex;align-items:center;gap:8px;background:var(--bean);color:var(--ink);border:1px solid var(--bean);border-radius:var(--radius-sm);padding:10px 16px;font-weight:600;font-size:14px;cursor:pointer;transition:filter .15s,transform .15s}
.botao:hover{filter:brightness(1.08);transform:translateY(-1px)}
.botao:disabled{opacity:.5;cursor:not-allowed;transform:none}
.botao-secundario{background:var(--panel-2);color:var(--fg);border-color:var(--line-2)}
.botao-perigo{background:transparent;color:var(--red);border-color:var(--red)}
.botao-pequeno{padding:6px 12px;font-size:13px}
.botao-ativo{background:var(--steam);border-color:var(--steam);color:var(--ink)}
.botoes{display:flex;flex-wrap:wrap;gap:10px;align-items:center}

/* ---------- formulários ---------- */
.campo{display:flex;flex-direction:column;gap:6px;margin-bottom:16px}
.campo label{font-size:13px;color:var(--fg-dim);letter-spacing:.04em}
.campo input,.campo textarea,.campo select{width:100%;background:var(--panel);border:1px solid var(--line);color:var(--fg);border-radius:var(--radius-sm);padding:11px 13px;font:inherit;font-size:14.5px;outline:none;transition:border-color .18s,box-shadow .18s}
.campo input:focus,.campo textarea:focus,.campo select:focus{border-color:var(--bean);box-shadow:0 0 0 3px var(--bean-soft)}
.campo textarea{min-height:110px;resize:vertical}
.campo input[type=file]{padding:9px}
.dica{font-size:12px;color:var(--fg-faint)}

/* ---------- avisos ---------- */
.aviso{border-radius:var(--radius-sm);padding:12px 14px;font-size:14px;margin:0 0 16px;border:1px solid var(--line)}
.aviso-erro{background:var(--red-soft);border-color:var(--red);color:var(--fg-strong)}
.aviso-ok{background:var(--leaf-soft);border-color:var(--leaf);color:var(--fg-strong)}
.aviso-topo{margin:0;border-radius:0;text-align:center}
.aviso a{color:var(--crema);text-decoration:underline}

/* ---------- busca e filtros ---------- */
.barra{display:flex;flex-wrap:wrap;gap:12px;align-items:center;margin-bottom:14px}
.busca{position:relative;flex:1;min-width:220px}
.busca input{width:100%;background:var(--panel);border:1px solid var(--line);color:var(--fg);border-radius:12px;padding:12px 14px 12px 40px;font:inherit;font-size:14.5px;outline:none}
.busca input:focus{border-color:var(--bean);box-shadow:0 0 0 3px var(--bean-soft)}
.busca svg{position:absolute;left:13px;top:50%;transform:translateY(-50%);width:16px;height:16px;stroke:var(--fg-faint);fill:none;stroke-width:2}
.chips{display:flex;flex-wrap:wrap;gap:8px;margin-bottom:22px}
.chip{background:var(--panel);border:1px solid var(--line);color:var(--fg-dim);border-radius:999px;padding:6px 13px;font-size:13px;cursor:pointer;font-family:var(--mono)}
.chip:hover{border-color:var(--line-2);color:var(--fg)}
.chip-ativo{background:var(--bean-soft);border-color:var(--bean);color:var(--crema)}
.contagem{font-family:var(--mono);font-size:13px;color:var(--fg-faint)}
.contagem b{color:var(--crema)}

/* ---------- cards ---------- */
.grade{display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));gap:18px}
.card{display:flex;flex-direction:column;background:var(--panel);border:1px solid var(--line);border-radius:var(--radius);padding:20px;transition:transform .16s,border-color .16s,box-shadow .16s}
.card:hover{transform:translateY(-3px);border-color:var(--bean);box-shadow:var(--shadow)}
.card-topo{display:flex;align-items:center;justify-content:space-between;gap:8px;margin-bottom:12px}
.card-selos{display:flex;gap:6px;flex-wrap:wrap}
.card-titulo{font-size:17px;font-weight:700;margin:0 0 6px;line-height:1.25}
.card-titulo a:hover{color:var(--crema)}
.card-descricao{font-size:13.5px;color:var(--fg-dim);margin:0 0 14px;flex:1;display:-webkit-box;-webkit-line-clamp:3;-webkit-box-orient:vertical;overflow:hidden}
.card-rodape{display:flex;align-items:center;justify-content:space-between;gap:8px;font-size:12.5px;color:var(--fg-faint);font-family:var(--mono)}
.card-rodape a:hover{color:var(--crema)}

/* ---------- selos ---------- */
.selo{display:inline-block;font-family:var(--mono);font-size:10.5px;letter-spacing:.08em;text-transform:uppercase;padding:3px 8px;border-radius:6px;border:1px solid var(--line-2);color:var(--fg-dim);background:var(--panel-2)}
.selo-disciplina{color:var(--bean);border-color:var(--bean);background:var(--bean-soft)}
.selo-revisado{color:var(--leaf);border-color:var(--leaf);background:var(--leaf-soft)}
.selo-monitor{color:var(--steam);border-color:var(--steam);background:var(--steam-soft)}
.selo-professor{color:var(--rose);border-color:var(--rose);background:var(--rose-soft)}
.selo-progresso{color:var(--crema);border-color:var(--crema);background:var(--crema-soft)}

/* ---------- favoritar ---------- */
.coracao{background:none;border:1px solid var(--line);color:var(--fg-faint);border-radius:8px;padding:4px 9px;cursor:pointer;font-size:14px;line-height:1;font-family:var(--mono)}
.coracao:hover{border-color:var(--rose);color:var(--rose)}
.coracao-ativo{color:var(--rose);border-color:var(--rose);background:var(--rose-soft)}

/* ---------- página do estudo ---------- */
.barra-estudo{display:flex;flex-wrap:wrap;align-items:center;gap:12px;padding:12px 22px;border-bottom:1px solid var(--line);background:var(--ink-2)}
.barra-estudo h1{font-size:17px;margin:0;flex:1;min-width:200px}
.quadro-estudo{display:block;width:100%;height:calc(100vh - 150px);min-height:480px;border:0;background:var(--ink)}
.comentarios{max-width:860px;margin:0 auto;padding:30px 22px 90px}
.comentario{background:var(--panel);border:1px solid var(--line);border-radius:var(--radius-sm);padding:14px 16px;margin-bottom:10px}
.comentario-topo{display:flex;align-items:center;gap:8px;font-size:13px;color:var(--fg-dim);margin-bottom:6px;flex-wrap:wrap}
.comentario-topo b{color:var(--fg)}
.comentario-topo .discreto{margin-left:auto}
.comentario p{margin:0;white-space:pre-wrap}
.comentario .botao{margin-top:8px}

/* ---------- abas (página entrar) ---------- */
.abas{display:flex;border-bottom:1px solid var(--line);margin-bottom:22px}
.aba{background:none;border:0;border-bottom:2px solid transparent;color:var(--fg-dim);padding:10px 16px;cursor:pointer;font-size:14px}
.aba-ativa{color:var(--crema);border-bottom-color:var(--bean)}

/* ---------- listas do perfil ---------- */
.lista{list-style:none;margin:0;padding:0}
.lista li{display:flex;align-items:center;gap:10px;padding:10px 0;border-bottom:1px solid var(--line-soft)}
.lista li a{flex:1}
.lista li a:hover{color:var(--crema)}
.vazio{color:var(--fg-faint);padding:20px 0;text-align:center}

/* ---------- registro da importação ---------- */
.registro{font-family:var(--mono);font-size:13px;background:var(--code-bg);border:1px solid var(--line);border-radius:var(--radius-sm);padding:12px 14px;max-height:260px;overflow:auto;white-space:pre-wrap;color:var(--code-fg);margin:12px 0 0}

/* ---------- telas pequenas ---------- */
@media (max-width:640px){
  .cabecalho{flex-direction:column;align-items:flex-start}
  .grade{grid-template-columns:1fr}
  .quadro-estudo{height:70vh}
}
@media (prefers-reduced-motion:reduce){*{animation:none!important;transition:none!important}}
```

- [ ] **Step 7: `index.html` (substituir o arquivo inteiro)**

```html
<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Hub de Estudos · PUC Minas</title>
<link rel="stylesheet" href="tema.css">
<link rel="stylesheet" href="css/site.css">
</head>
<body>
<header class="cabecalho" id="cabecalho"></header>

<main class="conteudo">
  <h1 class="titulo-pagina">Resumos e <span class="destaque">ferramentas</span> de estudo, num lugar só</h1>
  <p class="subtitulo">Materiais feitos por alunos, monitores e professores de Ciência da Computação da PUC Minas.</p>
  <div class="aviso" id="aviso" hidden></div>

  <div class="barra">
    <div class="busca">
      <svg viewBox="0 0 24 24"><circle cx="11" cy="11" r="7"/><path d="m20 20-3-3"/></svg>
      <input id="busca" type="search" placeholder="Buscar estudo… (atalho: /)" autocomplete="off">
    </div>
    <div class="contagem"><b id="contador">0</b> estudo(s)</div>
  </div>
  <div class="chips" id="chips"></div>

  <div class="grade" id="grade"></div>
  <div class="vazio" id="vazio" hidden>Nenhum estudo encontrado.</div>
</main>

<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
<script src="js/config.js"></script>
<script src="js/util.js"></script>
<script src="js/supabase.js"></script>
<script src="js/sessao.js"></script>
<script>
// Catálogo: chama buscar_estudos no backend e desenha os cards.
(async function () {
  var grade = document.getElementById('grade'), vazio = document.getElementById('vazio');
  var contador = document.getElementById('contador'), busca = document.getElementById('busca');
  var chips = document.getElementById('chips'), aviso = document.getElementById('aviso');
  var disciplina = '', temporizador = null;

  montarCabecalho();
  var s = await sessao();
  if (parametro('aviso') === 'so-equipe') mostrarAviso(aviso, 'Só monitor ou professor pode publicar estudos.');

  function cardHtml(e) {
    var selos = '<span class="selo selo-disciplina">' + esc(e.disciplina_sigla || 'geral') + '</span>';
    if (e.revisado) selos += '<span class="selo selo-revisado">revisado</span>';
    if (e.progresso) selos += '<span class="selo selo-progresso">' + (e.progresso === 'concluido' ? 'concluído' : 'estudando') + '</span>';
    var autor = e.autor_nome ? esc(e.autor_nome) + (e.autor_cargo !== 'aluno' ? ' · ' + esc(e.autor_cargo) : '') : 'equipe do hub';
    return '<article class="card">' +
      '<div class="card-topo"><div class="card-selos">' + selos + '</div>' +
      '<button class="coracao' + (e.favoritado ? ' coracao-ativo' : '') + '" data-favoritar="' + e.id + '" title="Favoritar">♥ ' + e.total_favoritos + '</button></div>' +
      '<h3 class="card-titulo"><a href="estudo.html?id=' + e.id + '">' + esc(e.titulo) + '</a></h3>' +
      '<p class="card-descricao">' + esc(e.descricao || 'Material de estudo.') + '</p>' +
      '<div class="card-rodape"><span>' + autor + '</span>' +
      '<span>' + e.total_comentarios + ' comentário(s) · <a href="estudo.html?id=' + e.id + '">abrir →</a></span></div>' +
      '</article>';
  }

  async function carregar() {
    try {
      var lista = await chamar('buscar_estudos', { texto: busca.value.trim(), disciplina: disciplina || null });
      grade.innerHTML = lista.map(cardHtml).join('');
      contador.textContent = lista.length;
      vazio.hidden = lista.length > 0;
    } catch (e) { mostrarAviso(aviso, e.message); }
  }

  async function carregarDisciplinas() {
    try {
      var lista = await chamar('listar_disciplinas');
      chips.innerHTML = '<button class="chip chip-ativo" data-sigla="">todas</button>' + lista.map(function (d) {
        return '<button class="chip" data-sigla="' + esc(d.sigla) + '" title="' + esc(d.nome) + '">' + esc(d.sigla) + '</button>';
      }).join('');
    } catch (e) { /* o aviso da busca já mostra o problema */ }
  }

  chips.addEventListener('click', function (ev) {
    var chip = ev.target.closest('.chip');
    if (!chip) return;
    disciplina = chip.dataset.sigla;
    chips.querySelectorAll('.chip').forEach(function (c) { c.classList.toggle('chip-ativo', c === chip); });
    carregar();
  });

  grade.addEventListener('click', async function (ev) {
    var botao = ev.target.closest('[data-favoritar]');
    if (!botao) return;
    if (!s.usuario) { location.href = 'entrar.html?voltar=index.html'; return; }
    try {
      var ligado = await chamar('alternar_favorito', { estudo: Number(botao.dataset.favoritar) });
      var total = parseInt(botao.textContent.replace(/\D/g, ''), 10) + (ligado ? 1 : -1);
      botao.classList.toggle('coracao-ativo', ligado);
      botao.textContent = '♥ ' + total;
    } catch (e) { mostrarAviso(aviso, e.message); }
  });

  busca.addEventListener('input', function () { clearTimeout(temporizador); temporizador = setTimeout(carregar, 250); });
  document.addEventListener('keydown', function (e) {
    if (e.key === '/' && document.activeElement !== busca) { e.preventDefault(); busca.focus(); }
    if (e.key === 'Escape') { busca.value = ''; carregar(); busca.blur(); }
  });

  carregarDisciplinas();
  carregar();
})();
</script>
</body>
</html>
```

- [ ] **Step 8: Apagar `estudos.js`**

Run: `git rm -q estudos.js`

- [ ] **Step 9: Verificar no navegador**

Abrir o servidor `hub` (preview_start) e carregar `http://localhost:8000/index.html`. Expected: cabeçalho com "Hub de Estudos" e botão "Entrar"; faixa vermelha no topo "Backend não configurado…"; título e campo de busca; aviso vermelho "Backend não configurado: preencha js/config.js" na área de conteúdo; console sem erros (o CDN do supabase carrega; `db` é null). Testar `?aviso=so-equipe` mostra o aviso de equipe. Redimensionar para 375 px: cabeçalho empilha, grade em uma coluna.

- [ ] **Step 10: Commit**

```bash
git add -A && git commit -m "Front: CSS de componentes, JS compartilhado e catálogo lendo do backend

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

### Task 7: Página entrar.html

**Files:**
- Create: `entrar.html`

**Interfaces:**
- Consumes: `db.auth.signInWithPassword`, `db.auth.signUp`, RPC `listar_dominios`, `sessao()`, `limparSessao()`, `parametro()`, `mostrarAviso()`, `traduzirErro()`.
- Produces: fluxo de login; `?voltar=<página>` respeitado só para nomes relativos.

- [ ] **Step 1: Escrever `entrar.html`**

```html
<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Entrar · Hub de Estudos</title>
<link rel="stylesheet" href="tema.css">
<link rel="stylesheet" href="css/site.css">
</head>
<body>
<header class="cabecalho" id="cabecalho"></header>

<main class="conteudo conteudo-estreito">
  <h1 class="titulo-pagina">Entrar</h1>
  <p class="subtitulo">Use o e-mail da PUC. Quem ainda não tem conta cria uma na aba ao lado.</p>

  <div class="abas">
    <button class="aba aba-ativa" data-aba="entrar" type="button">Entrar</button>
    <button class="aba" data-aba="cadastrar" type="button">Criar conta</button>
  </div>
  <div class="aviso" id="aviso" hidden></div>

  <form id="form-entrar">
    <div class="campo"><label for="email-entrar">E-mail</label><input id="email-entrar" type="email" required autocomplete="email"></div>
    <div class="campo"><label for="senha-entrar">Senha</label><input id="senha-entrar" type="password" required autocomplete="current-password"></div>
    <button class="botao" type="submit">Entrar</button>
  </form>

  <form id="form-cadastrar" hidden>
    <div class="campo"><label for="nome">Nome</label><input id="nome" type="text" required maxlength="80" autocomplete="name"></div>
    <div class="campo"><label for="email-cadastrar">E-mail da PUC</label><input id="email-cadastrar" type="email" required autocomplete="email"><span class="dica" id="dica-dominios">Só sga.pucminas.br e pucminas.br</span></div>
    <div class="campo"><label for="senha-cadastrar">Senha</label><input id="senha-cadastrar" type="password" required minlength="6" autocomplete="new-password"><span class="dica">Mínimo de 6 caracteres</span></div>
    <button class="botao" type="submit">Criar conta</button>
  </form>
</main>

<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
<script src="js/config.js"></script>
<script src="js/util.js"></script>
<script src="js/supabase.js"></script>
<script src="js/sessao.js"></script>
<script>
// Login e cadastro. O domínio do e-mail é conferido aqui (mensagem amigável)
// e de novo no banco (gatilho em auth.users), que é a garantia de verdade.
(async function () {
  var dominios = ['sga.pucminas.br', 'pucminas.br'];  // reserva; o backend manda a lista real
  var aviso = document.getElementById('aviso');
  var formEntrar = document.getElementById('form-entrar'), formCadastrar = document.getElementById('form-cadastrar');

  montarCabecalho();
  var s = await sessao();
  if (s.usuario) { voltar(); return; }

  try { var lista = await chamar('listar_dominios'); if (lista && lista.length) dominios = lista; } catch (e) { /* fica a reserva */ }
  document.getElementById('dica-dominios').textContent = 'Só ' + dominios.join(' e ');

  // Só aceita voltar para uma página relativa do próprio site.
  function voltar() {
    var destino = parametro('voltar') || 'index.html';
    if (destino.indexOf('//') >= 0 || destino.indexOf(':') >= 0) destino = 'index.html';
    location.href = destino;
  }
  function dominioOk(email) { return dominios.indexOf((email.split('@')[1] || '').toLowerCase()) >= 0; }

  document.querySelectorAll('.aba').forEach(function (aba) {
    aba.addEventListener('click', function () {
      document.querySelectorAll('.aba').forEach(function (a) { a.classList.toggle('aba-ativa', a === aba); });
      formEntrar.hidden = aba.dataset.aba !== 'entrar';
      formCadastrar.hidden = aba.dataset.aba !== 'cadastrar';
      mostrarAviso(aviso, '');
    });
  });

  formEntrar.addEventListener('submit', async function (ev) {
    ev.preventDefault();
    if (!window.db) return mostrarAviso(aviso, 'Backend não configurado: preencha js/config.js');
    var r = await db.auth.signInWithPassword({
      email: document.getElementById('email-entrar').value.trim(),
      password: document.getElementById('senha-entrar').value
    });
    if (r.error) return mostrarAviso(aviso, traduzirErro(r.error));
    limparSessao();
    voltar();
  });

  formCadastrar.addEventListener('submit', async function (ev) {
    ev.preventDefault();
    var nome = document.getElementById('nome').value.trim();
    var email = document.getElementById('email-cadastrar').value.trim();
    var senha = document.getElementById('senha-cadastrar').value;
    if (!dominioOk(email)) return mostrarAviso(aviso, 'Use um e-mail da PUC: ' + dominios.join(' ou '));
    if (!window.db) return mostrarAviso(aviso, 'Backend não configurado: preencha js/config.js');
    var r = await db.auth.signUp({ email: email, password: senha, options: { data: { nome: nome } } });
    if (r.error) return mostrarAviso(aviso, traduzirErro(r.error));
    if (!r.data.session) return mostrarAviso(aviso, 'Conta criada. Confira seu e-mail para confirmar o cadastro e depois entre.', 'ok');
    limparSessao();
    voltar();
  });
})();
</script>
</body>
</html>
```

- [ ] **Step 2: Verificar no navegador**

Abrir `http://localhost:8000/entrar.html`. Expected: duas abas; clicar em "Criar conta" troca o formulário; enviar o cadastro com `x@gmail.com` mostra "Use um e-mail da PUC…" sem chamar o backend; enviar o login mostra "Backend não configurado…"; console sem erros. `entrar.html?voltar=https://evil.com` seguido de login (quando houver backend) volta para `index.html`.

- [ ] **Step 3: Commit**

```bash
git add entrar.html && git commit -m "Front: página de entrar e cadastrar

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

### Task 8: Página estudo.html

**Files:**
- Create: `estudo.html`

**Interfaces:**
- Consumes: RPCs `painel_estudo`, `alternar_favorito`, `marcar_progresso`, `comentar`, `excluir_comentario`, `marcar_revisado`, `excluir_estudo`; `db.storage.from('estudos').remove([caminho])`; `sessao()`, `ehEquipe()`.

- [ ] **Step 1: Escrever `estudo.html`**

```html
<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Estudo · Hub de Estudos</title>
<link rel="stylesheet" href="tema.css">
<link rel="stylesheet" href="css/site.css">
</head>
<body>
<header class="cabecalho" id="cabecalho"></header>

<div class="barra-estudo" id="barra" hidden>
  <a class="botao botao-secundario botao-pequeno" href="index.html">← voltar</a>
  <h1 id="titulo"></h1>
  <span class="selo selo-disciplina" id="disciplina"></span>
  <span class="selo selo-revisado" id="selo-revisado" hidden>revisado</span>
  <span class="discreto" id="autor"></span>
  <div class="botoes">
    <button class="coracao" id="favoritar" type="button" title="Favoritar">♥ 0</button>
    <button class="botao botao-secundario botao-pequeno" id="estudando" type="button">Estudando</button>
    <button class="botao botao-secundario botao-pequeno" id="concluido" type="button">Concluído</button>
    <button class="botao botao-secundario botao-pequeno" id="revisar" type="button" hidden>Marcar revisado</button>
    <button class="botao botao-perigo botao-pequeno" id="excluir" type="button" hidden>Excluir</button>
  </div>
</div>

<main>
  <div class="conteudo" id="area-aviso" hidden><div class="aviso" id="aviso" hidden></div></div>
  <iframe class="quadro-estudo" id="quadro" title="Conteúdo do estudo" hidden></iframe>

  <section class="comentarios" id="secao-comentarios" hidden>
    <h2>Comentários e dúvidas</h2>
    <div id="lista-comentarios"></div>
    <form id="form-comentario" hidden>
      <div class="campo"><label for="texto">Sua dúvida ou comentário</label><textarea id="texto" maxlength="2000" required></textarea></div>
      <button class="botao" type="submit">Enviar</button>
    </form>
    <p class="discreto" id="entrar-para-comentar" hidden><a id="link-entrar" href="entrar.html">Entre</a> para comentar.</p>
  </section>
</main>

<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
<script src="js/config.js"></script>
<script src="js/util.js"></script>
<script src="js/supabase.js"></script>
<script src="js/sessao.js"></script>
<script>
// Página do estudo: painel_estudo traz tudo numa chamada; o HTML do estudo é
// buscado (repositório ou Storage) e mostrado num iframe via srcdoc.
(async function () {
  var id = Number(parametro('id'));
  var aviso = document.getElementById('aviso'), areaAviso = document.getElementById('area-aviso');
  var quadro = document.getElementById('quadro'), lista = document.getElementById('lista-comentarios');
  var s, estudo;

  function avisar(msg) { areaAviso.hidden = false; mostrarAviso(aviso, msg); }

  montarCabecalho();
  s = await sessao();
  document.getElementById('link-entrar').href = 'entrar.html?voltar=' + encodeURIComponent('estudo.html?id=' + id);
  if (!id) return avisar('Estudo não encontrado. Volte ao início.');

  var painel;
  try { painel = await chamar('painel_estudo', { estudo: id }); } catch (e) { return avisar(e.message); }
  if (!painel) return avisar('Estudo não encontrado. Volte ao início.');
  estudo = painel.estudo;

  document.title = estudo.titulo + ' · Hub de Estudos';
  desenharBarra();
  desenharComentarios(painel.comentarios);
  carregarEstudo(estudo.arquivo_url);

  // ---------- barra ----------
  function desenharBarra() {
    document.getElementById('titulo').textContent = estudo.titulo;
    document.getElementById('disciplina').textContent = estudo.disciplina_sigla || 'geral';
    document.getElementById('selo-revisado').hidden = !estudo.revisado;
    document.getElementById('autor').textContent = (estudo.autor_nome ? 'por ' + estudo.autor_nome + ' · ' : '') + formatarData(estudo.publicado_em);
    var fav = document.getElementById('favoritar');
    fav.textContent = '♥ ' + estudo.total_favoritos;
    fav.classList.toggle('coracao-ativo', !!estudo.favoritado);
    document.getElementById('estudando').classList.toggle('botao-ativo', estudo.progresso === 'estudando');
    document.getElementById('concluido').classList.toggle('botao-ativo', estudo.progresso === 'concluido');
    var equipe = ehEquipe(s.perfil);
    document.getElementById('revisar').hidden = !equipe;
    document.getElementById('revisar').textContent = estudo.revisado ? 'Tirar revisão' : 'Marcar revisado';
    document.getElementById('excluir').hidden = !equipe;
    document.getElementById('barra').hidden = false;
  }

  function exigirUsuario() {
    if (s.usuario) return true;
    location.href = 'entrar.html?voltar=' + encodeURIComponent('estudo.html?id=' + id);
    return false;
  }

  document.getElementById('favoritar').addEventListener('click', async function () {
    if (!exigirUsuario()) return;
    try {
      estudo.favoritado = await chamar('alternar_favorito', { estudo: id });
      estudo.total_favoritos += estudo.favoritado ? 1 : -1;
      desenharBarra();
    } catch (e) { avisar(e.message); }
  });

  // Clicar no status já ativo limpa o progresso.
  async function mudarProgresso(status) {
    if (!exigirUsuario()) return;
    try {
      estudo.progresso = await chamar('marcar_progresso', { estudo: id, novo_status: estudo.progresso === status ? null : status });
      desenharBarra();
    } catch (e) { avisar(e.message); }
  }
  document.getElementById('estudando').addEventListener('click', function () { mudarProgresso('estudando'); });
  document.getElementById('concluido').addEventListener('click', function () { mudarProgresso('concluido'); });

  document.getElementById('revisar').addEventListener('click', async function () {
    try {
      await chamar('marcar_revisado', { estudo: id, valor: !estudo.revisado });
      estudo.revisado = !estudo.revisado;
      desenharBarra();
    } catch (e) { avisar(e.message); }
  });

  document.getElementById('excluir').addEventListener('click', async function () {
    if (!confirm('Excluir "' + estudo.titulo + '"? Isso apaga também os comentários, favoritos e o arquivo.')) return;
    try {
      var caminho = await chamar('excluir_estudo', { estudo: id });
      if (caminho) await db.storage.from('estudos').remove([decodeURIComponent(caminho)]);
      location.href = 'index.html';
    } catch (e) { avisar(e.message); }
  });

  // ---------- conteúdo ----------
  // Os estudos usam ../tema.css e ../vendor/katex. Dentro de srcdoc não há
  // "pasta atual", então trocamos ../ pela raiz absoluta do site. Não usamos
  // <base> porque ela quebraria as âncoras href="#..." dos estudos.
  async function carregarEstudo(url) {
    var raiz = location.origin + location.pathname.replace(/[^/]*$/, '');
    try {
      var r = await fetch(url);
      if (!r.ok) throw new Error('HTTP ' + r.status);
      var html = await r.text();
      html = html.replace(/href="\.\.\/index\.html"/g, 'href="' + raiz + 'index.html" target="_top"');
      html = html.replace(/(src|href)=(["'])\.\.\//g, '$1=$2' + raiz);
      quadro.srcdoc = html;
      quadro.hidden = false;
    } catch (e) {
      areaAviso.hidden = false;
      aviso.className = 'aviso aviso-erro';
      aviso.innerHTML = 'Não consegui carregar o conteúdo (' + esc(e.message) + '). <a href="' + esc(url) + '" target="_blank" rel="noopener">Abrir o arquivo direto</a>';
      aviso.hidden = false;
    }
  }

  // ---------- comentários ----------
  function comentarioHtml(c) {
    var selo = c.autor_cargo && c.autor_cargo !== 'aluno' ? '<span class="selo selo-' + esc(c.autor_cargo) + '">' + esc(c.autor_cargo) + '</span>' : '';
    var apagar = (c.meu || ehEquipe(s.perfil)) ? '<button class="botao botao-perigo botao-pequeno" data-excluir="' + c.id + '" type="button">Excluir</button>' : '';
    return '<div class="comentario" data-id="' + c.id + '"><div class="comentario-topo"><b>' + esc(c.autor_nome || 'alguém') + '</b>' + selo +
      '<span class="discreto">' + formatarData(c.criado_em) + '</span></div><p>' + esc(c.texto) + '</p>' + apagar + '</div>';
  }
  function desenharComentarios(comentarios) {
    lista.innerHTML = comentarios.length ? comentarios.map(comentarioHtml).join('') : '<p class="vazio">Nenhum comentário ainda. Seja a primeira pessoa a perguntar.</p>';
    document.getElementById('form-comentario').hidden = !s.usuario;
    document.getElementById('entrar-para-comentar').hidden = !!s.usuario;
    document.getElementById('secao-comentarios').hidden = false;
  }

  document.getElementById('form-comentario').addEventListener('submit', async function (ev) {
    ev.preventDefault();
    var campo = document.getElementById('texto');
    try {
      var novo = await chamar('comentar', { estudo: id, texto: campo.value });
      painel.comentarios.push(novo);
      campo.value = '';
      desenharComentarios(painel.comentarios);
    } catch (e) { avisar(e.message); }
  });

  lista.addEventListener('click', async function (ev) {
    var botao = ev.target.closest('[data-excluir]');
    if (!botao) return;
    try {
      await chamar('excluir_comentario', { comentario: Number(botao.dataset.excluir) });
      painel.comentarios = painel.comentarios.filter(function (c) { return c.id !== Number(botao.dataset.excluir); });
      desenharComentarios(painel.comentarios);
    } catch (e) { avisar(e.message); }
  });
})();
</script>
</body>
</html>
```

- [ ] **Step 2: Verificar no navegador**

Abrir `http://localhost:8000/estudo.html` (sem id). Expected: aviso "Estudo não encontrado". Abrir `estudo.html?id=1`. Expected: aviso "Backend não configurado…" na área de conteúdo, barra escondida, console sem erros.

- [ ] **Step 3: Commit**

```bash
git add estudo.html && git commit -m "Front: página do estudo com iframe, progresso e comentários

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

### Task 9: Página publicar.html (publicar e importar)

**Files:**
- Create: `publicar.html`

**Interfaces:**
- Consumes: `exigirEquipe()`, RPCs `listar_disciplinas`, `publicar_estudo`, `estudos_para_importar`, `atualizar_arquivo`; `db.storage.from('estudos').upload(caminho, blob, opções)` e `.getPublicUrl(caminho)`; `slug()`.

- [ ] **Step 1: Escrever `publicar.html`**

```html
<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Publicar · Hub de Estudos</title>
<link rel="stylesheet" href="tema.css">
<link rel="stylesheet" href="css/site.css">
</head>
<body>
<header class="cabecalho" id="cabecalho"></header>

<main class="conteudo conteudo-estreito">
  <h1 class="titulo-pagina">Publicar estudo</h1>
  <p class="subtitulo">Só monitores e professores. O arquivo vai para o Storage e o cadastro para o banco.</p>
  <div class="aviso" id="aviso" hidden></div>

  <form id="form">
    <div class="campo"><label for="titulo">Título</label><input id="titulo" type="text" required maxlength="140"></div>
    <div class="campo"><label for="descricao">Descrição</label><textarea id="descricao" maxlength="1000"></textarea></div>
    <div class="campo"><label for="disciplina">Disciplina</label><select id="disciplina" required></select></div>
    <div class="campo">
      <label for="arquivo">Arquivo HTML</label>
      <input id="arquivo" type="file" accept=".html,text/html" required>
      <span class="dica">Até 5 MB. Links para ../tema.css e ../vendor/katex continuam funcionando.</span>
    </div>
    <button class="botao" type="submit" id="enviar">Publicar</button>
  </form>

  <section class="secao">
    <h2>Importar estudos do repositório</h2>
    <p class="discreto">Sobe para o Storage os estudos que ainda apontam para a pasta estudos/ do site e troca a URL no banco. Pode rodar de novo se algo falhar.</p>
    <button class="botao botao-secundario" type="button" id="importar">Importar</button>
    <pre class="registro" id="registro" hidden></pre>
  </section>
</main>

<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
<script src="js/config.js"></script>
<script src="js/util.js"></script>
<script src="js/supabase.js"></script>
<script src="js/sessao.js"></script>
<script>
// Publicar: sobe o arquivo no bucket "estudos", pega a URL pública e registra
// no banco com publicar_estudo (que confere o cargo de novo, no servidor).
(async function () {
  var aviso = document.getElementById('aviso'), form = document.getElementById('form');
  var enviar = document.getElementById('enviar'), registro = document.getElementById('registro');
  var LIMITE = 5 * 1024 * 1024;

  var s = await exigirEquipe();
  if (!s) return;
  montarCabecalho();

  try {
    var disciplinas = await chamar('listar_disciplinas');
    document.getElementById('disciplina').innerHTML = disciplinas.map(function (d) {
      return '<option value="' + esc(d.sigla) + '">' + esc(d.sigla) + ' · ' + esc(d.nome) + '</option>';
    }).join('');
  } catch (e) { mostrarAviso(aviso, e.message); }

  // Sobe um HTML e devolve a URL pública. upsert permite repetir a importação.
  async function subir(caminho, texto, sobrescrever) {
    var r = await db.storage.from('estudos').upload(caminho, new Blob([texto], { type: 'text/html' }), { upsert: !!sobrescrever });
    if (r.error) throw new Error(traduzirErro(r.error));
    return db.storage.from('estudos').getPublicUrl(caminho).data.publicUrl;
  }

  form.addEventListener('submit', async function (ev) {
    ev.preventDefault();
    var titulo = document.getElementById('titulo').value.trim();
    var arquivo = document.getElementById('arquivo').files[0];
    if (!arquivo) return mostrarAviso(aviso, 'Escolha o arquivo HTML.');
    if (arquivo.size > LIMITE) return mostrarAviso(aviso, 'Arquivo maior que 5 MB.');
    if (!/\.html?$/i.test(arquivo.name)) return mostrarAviso(aviso, 'O arquivo precisa ser .html');
    enviar.disabled = true;
    mostrarAviso(aviso, '');
    try {
      var url = await subir(Date.now() + '-' + slug(titulo) + '.html', await arquivo.text(), false);
      var novo = await chamar('publicar_estudo', {
        titulo: titulo,
        descricao: document.getElementById('descricao').value.trim(),
        disciplina_sigla: document.getElementById('disciplina').value,
        arquivo_url: url
      });
      location.href = 'estudo.html?id=' + novo;
    } catch (e) {
      mostrarAviso(aviso, e.message);
      enviar.disabled = false;
    }
  });

  function registrar(linha) { registro.hidden = false; registro.textContent += linha + '\n'; }

  document.getElementById('importar').addEventListener('click', async function () {
    var botao = this;
    botao.disabled = true;
    registro.textContent = '';
    try {
      var lista = await chamar('estudos_para_importar');
      if (!lista.length) registrar('Nada para importar: todos os estudos já estão no Storage.');
      for (var i = 0; i < lista.length; i++) {
        var item = lista[i];
        try {
          var r = await fetch(item.arquivo_url);
          if (!r.ok) throw new Error('HTTP ' + r.status + ' ao ler ' + item.arquivo_url);
          var url = await subir(item.id + '-' + item.arquivo_url.split('/').pop(), await r.text(), true);
          await chamar('atualizar_arquivo', { estudo: item.id, nova_url: url });
          registrar('ok    ' + item.titulo);
        } catch (e) {
          registrar('ERRO  ' + item.titulo + ': ' + e.message);
        }
      }
      registrar('Concluído.');
    } catch (e) {
      registrar('ERRO  ' + e.message);
    }
    botao.disabled = false;
  });
})();
</script>
</body>
</html>
```

- [ ] **Step 2: Verificar no navegador**

Abrir `http://localhost:8000/publicar.html`. Expected (sem backend, `sessao()` devolve anônimo): redireciona para `entrar.html?voltar=publicar.html`. Console sem erros.

- [ ] **Step 3: Commit**

```bash
git add publicar.html && git commit -m "Front: publicar estudo com upload e importar os estudos do repositório

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

### Task 10: Página perfil.html

**Files:**
- Create: `perfil.html`

**Interfaces:**
- Consumes: `exigirLogin()`, RPC `atualizar_nome`, `sair()`, `limparSessao()`. O perfil já vem em `sessao().perfil` (formato de `meu_perfil`).

- [ ] **Step 1: Escrever `perfil.html`**

```html
<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Meu perfil · Hub de Estudos</title>
<link rel="stylesheet" href="tema.css">
<link rel="stylesheet" href="css/site.css">
</head>
<body>
<header class="cabecalho" id="cabecalho"></header>

<main class="conteudo conteudo-estreito">
  <h1 class="titulo-pagina">Meu perfil</h1>
  <p class="subtitulo"><span id="email"></span> · <span class="selo" id="cargo"></span></p>
  <div class="aviso" id="aviso" hidden></div>

  <form id="form-nome">
    <div class="campo"><label for="nome">Nome</label><input id="nome" type="text" maxlength="80" required></div>
    <div class="botoes">
      <button class="botao" type="submit">Salvar nome</button>
      <button class="botao botao-perigo" type="button" id="sair">Sair</button>
    </div>
  </form>

  <section class="secao"><h2>Favoritos</h2><ul class="lista" id="favoritos"></ul></section>
  <section class="secao"><h2>Progresso</h2><ul class="lista" id="progresso"></ul></section>
</main>

<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
<script src="js/config.js"></script>
<script src="js/util.js"></script>
<script src="js/supabase.js"></script>
<script src="js/sessao.js"></script>
<script>
// Perfil: tudo vem de meu_perfil() (já carregado por sessao()).
(async function () {
  var aviso = document.getElementById('aviso');
  var s = await exigirLogin();
  if (!s) return;
  montarCabecalho();
  var p = s.perfil;
  if (!p) return mostrarAviso(aviso, 'Não consegui carregar o perfil. Tente entrar de novo.');

  document.getElementById('email').textContent = p.email;
  var cargo = document.getElementById('cargo');
  cargo.textContent = p.cargo;
  if (p.cargo !== 'aluno') cargo.classList.add('selo-' + p.cargo);
  document.getElementById('nome').value = p.nome;

  function itemHtml(e, extra) {
    return '<li><span class="selo selo-disciplina">' + esc(e.disciplina_sigla || 'geral') + '</span>' +
      '<a href="estudo.html?id=' + e.id + '">' + esc(e.titulo) + '</a>' + (extra || '') + '</li>';
  }
  document.getElementById('favoritos').innerHTML = p.favoritos.length
    ? p.favoritos.map(function (e) { return itemHtml(e); }).join('')
    : '<li class="vazio">Nenhum favorito ainda.</li>';
  document.getElementById('progresso').innerHTML = p.progresso.length
    ? p.progresso.map(function (e) { return itemHtml(e, '<span class="selo selo-progresso">' + (e.status === 'concluido' ? 'concluído' : 'estudando') + '</span>'); }).join('')
    : '<li class="vazio">Nenhum estudo em andamento.</li>';

  document.getElementById('form-nome').addEventListener('submit', async function (ev) {
    ev.preventDefault();
    try {
      await chamar('atualizar_nome', { novo_nome: document.getElementById('nome').value });
      limparSessao();
      mostrarAviso(aviso, 'Nome salvo.', 'ok');
      montarCabecalho();
    } catch (e) { mostrarAviso(aviso, e.message); }
  });
  document.getElementById('sair').addEventListener('click', sair);
})();
</script>
</body>
</html>
```

- [ ] **Step 2: Verificar no navegador**

Abrir `http://localhost:8000/perfil.html`. Expected: redireciona para `entrar.html?voltar=perfil.html`. Console sem erros.

- [ ] **Step 3: Commit**

```bash
git add perfil.html && git commit -m "Front: página de perfil com favoritos e progresso

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

### Task 11: README e limpeza

**Files:**
- Modify: `README.md` (substituir inteiro)

- [ ] **Step 1: Escrever o README**

```markdown
# ☕ Hub de Estudos

Plataforma de estudo colaborativa do curso de Ciência da Computação da PUC Minas.
Alunos leem, favoritam, acompanham o progresso e tiram dúvidas; monitores e
professores publicam e revisam os materiais. Prova de conceito do Trabalho
Interdisciplinar 2.

Feito com HTML, CSS e JavaScript puro no front (sem framework, sem build) e
**Supabase** no backend (Postgres + Auth + Storage). Toda a lógica mora no
banco, em funções SQL; as páginas só chamam essas funções e desenham o resultado.

## Estrutura

```
index.html          catálogo com busca e filtro por disciplina
entrar.html         login e cadastro (só e-mail da PUC)
estudo.html         estudo + favoritar + progresso + comentários
publicar.html       monitor/professor: publicar e importar estudos
perfil.html         nome, cargo, favoritos, progresso
tema.css            paleta (variáveis de cor)
css/site.css        componentes do site
js/config.js        URL e chave anon do projeto Supabase
js/util.js          funções pequenas (esc, slug, avisos)
js/supabase.js      cliente e chamar(): a ponte com o backend
js/sessao.js        sessão, cabeçalho e guardas de página
supabase/schema.sql todo o backend: tabelas, gatilhos, RLS, Storage, funções RPC, seed
supabase/teste/     testes do backend num Postgres local
estudos/            estudos originais; fonte da importação (pode apagar depois)
vendor/katex/       KaTeX local, usado pelos estudos de matemática
```

## Configurar o backend

1. Crie um projeto em [supabase.com](https://supabase.com).
2. **SQL Editor** → cole o conteúdo de `supabase/schema.sql` → **Run**.
3. **Authentication → Providers → Email**: para a demonstração, desligue *Confirm email* (senão cada cadastro precisa clicar no link do e-mail).
4. **Project Settings → API**: copie a *Project URL* e a chave *anon public* para `js/config.js`.
5. Sirva a pasta: `python3 -m http.server 8000` e abra <http://localhost:8000>.
6. Crie sua conta pelo site. Depois, no **Table Editor → perfis**, troque o seu `cargo` para `professor`.
7. Em **Publicar → Importar estudos do repositório**, clique em *Importar*: os 8 estudos sobem para o Storage e o site deixa de depender da pasta `estudos/`.

Para testar com um e-mail que não seja da PUC, insira o domínio na tabela `dominios_permitidos`.

## Cargos

| cargo | pode |
|---|---|
| visitante | ler os estudos e os comentários |
| aluno | favoritar, marcar progresso, comentar, apagar os próprios comentários |
| monitor / professor | tudo acima, mais publicar, marcar revisado, excluir estudos e comentários |

O cargo começa como `aluno` e só muda pelo painel do Supabase.

## Testar o backend localmente

Precisa de Postgres 17 pelo Homebrew (`brew install postgresql@17`).

```
supabase/teste/rodar.sh          # sobe um Postgres na porta 5499, roda schema.sql e teste.sql
supabase/teste/rodar.sh parar    # desliga
```

## Publicar

É tudo estático: qualquer hospedagem de arquivos serve (GitHub Pages inclusive).
Suba o repositório com o `js/config.js` preenchido. A chave anon é pública por
desenho; quem protege os dados são as políticas RLS no banco.
```

- [ ] **Step 2: Conferir que nada referencia `estudos.js`**

Run: `grep -rn "estudos.js" --include=*.html --include=*.js --include=*.md . | grep -v node_modules | grep -v docs/superpowers`
Expected: nenhuma linha.

- [ ] **Step 3: Commit**

```bash
git add README.md && git commit -m "README: configuração do Supabase, cargos e testes

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

### Task 12: Ponta a ponta com o projeto Supabase real

Depende do Lucas: criar o projeto, rodar `schema.sql` no SQL Editor, desligar *Confirm email* e passar URL + chave anon.

**Files:**
- Modify: `js/config.js` (valores reais)

- [ ] **Step 1: Preencher `js/config.js`** com a URL e a chave anon recebidas e reiniciar o preview.

- [ ] **Step 2: Catálogo anônimo.** Abrir `index.html`. Expected: 8 cards, 8 chips + "todas", faixa vermelha sumiu. Digitar `calculo` → 1 card. Clicar chip `AEDS1` → 2 cards. Clicar ♥ → vai para `entrar.html?voltar=index.html`.

- [ ] **Step 3: Cadastro e login.** Criar conta com `x@gmail.com` → aviso do domínio. Criar com um e-mail permitido (o Lucas informa qual; se for pessoal, ele insere o domínio em `dominios_permitidos` antes) → volta para o índice logado, nome no cabeçalho. Sair pelo perfil e entrar de novo com senha errada → "E-mail ou senha incorretos".

- [ ] **Step 4: Aluno.** No índice, favoritar um estudo (♥ fica rosa, contador sobe). Abrir o estudo: conteúdo aparece no iframe com o tema café e, no guia de integrais, as fórmulas renderizadas pelo KaTeX; clicar numa âncora da lateral rola dentro do iframe. Marcar *Estudando* (botão azul), depois *Concluído*, depois *Concluído* de novo (limpa). Comentar → aparece com o nome; excluir o próprio comentário. Perfil mostra favorito e progresso; salvar nome novo → cabeçalho atualiza. Tentar `publicar.html` → volta ao índice com "Só monitor ou professor…".

- [ ] **Step 5: Professor.** No Table Editor, trocar `cargo` para `professor`. Recarregar: link *Publicar* aparece. Publicar um estudo com um HTML de teste (pode ser uma cópia de `estudos/questoes-de-c.html`) → redireciona para o estudo novo, conteúdo carrega do Storage (URL começa com a do projeto). *Marcar revisado* → selo aparece. Importar: os 8 estudos aparecem com `ok`; no Storage do painel há 9 arquivos; abrir o guia de integrais de novo (agora do Storage) com KaTeX funcionando. Excluir o estudo de teste → volta ao índice; no Storage sobrou 8 arquivos.

- [ ] **Step 6: Apagar a pasta `estudos/`** (opcional, com o Lucas): `git rm -r estudos/`. Abrir 3 estudos para confirmar que continuam funcionando.

- [ ] **Step 7: Commit**

```bash
git add js/config.js && git commit -m "Aponta o site para o projeto Supabase

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Cobertura da spec (auto-revisão)

| Spec | Tarefa |
|---|---|
| 3.1 tipos, 3.2 tabelas, 3.3 gatilhos, 3.4 auxiliares, 3.8 seed | 2 |
| 3.6 RLS, 3.7 Storage | 3 |
| 3.5 leitura (`listar_disciplinas`, `listar_dominios`, `buscar_estudos`, `painel_estudo`, `meu_perfil`, `estudos_para_importar`) | 4 |
| 3.5 escrita (`alternar_favorito`, `marcar_progresso`, `comentar`, `excluir_comentario`, `publicar_estudo`, `atualizar_arquivo`, `marcar_revisado`, `excluir_estudo`, `atualizar_nome`) | 5 |
| 4.1 arquivos, 4.2 JS compartilhado, 4.4 CSS, 4.3 index | 6 |
| 4.3 entrar | 7 |
| 4.3 estudo (reescrita de links, comentários, ações de equipe) | 8 |
| 4.3 publicar + importar | 9 |
| 4.3 perfil | 10 |
| 5 erros (try/catch, faixa de config, estudo inexistente, falha de carga, upload inválido) | 6, 8, 9 |
| 6 testes: SQL local | 1–5 |
| 6 testes: ponta a ponta | 12 |
| 7 configuração (README) | 11 |
