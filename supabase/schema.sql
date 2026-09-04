-- ============================================================
-- Hub de Estudos · backend completo (Supabase)
-- Cole este arquivo inteiro no SQL Editor do projeto e execute.
-- Pode ser executado de novo: tudo é "if not exists" / "or replace".
-- Ordem: extensões → tipos → tabelas → auxiliares → gatilhos →
--        RLS → Storage → funções RPC (a API do site) → seed
-- ============================================================
create schema if not exists extensions;
create extension if not exists unaccent with schema extensions;

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
  nome text not null check (length(nome) between 1 and 80),
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
returns void language plpgsql stable set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Faça login para continuar'; end if;
end $$;

create or replace function exigir_equipe()
returns void language plpgsql stable set search_path = public as $$
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
    left(coalesce(nullif(btrim(new.raw_user_meta_data ->> 'nome'), ''), split_part(new.email, '@', 1)), 80),
    lower(new.email)
  );
  return new;
end $$;
drop trigger if exists criar_perfil on auth.users;
create trigger criar_perfil after insert on auth.users
  for each row execute function auth_criar_perfil();

-- Cargo só muda pelo painel do Supabase (sem JWT). Sessão autenticada não pode.
create or replace function perfis_proteger_cargo()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.cargo is distinct from old.cargo and auth.role() = 'authenticated' then
    raise exception 'O cargo só pode ser alterado pelo painel do Supabase';
  end if;
  return new;
end $$;
drop trigger if exists proteger_cargo on perfis;
create trigger proteger_cargo before update on perfis
  for each row execute function perfis_proteger_cargo();

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

-- ---------- RPC de escrita ----------
-- Rodam como o chamador (security invoker, o padrão): a checagem de cargo é
-- explícita aqui E as políticas RLS valem por baixo.
-- "#variable_conflict use_variable": se um parâmetro tiver o mesmo nome de uma
-- coluna, vale o parâmetro.

create or replace function alternar_favorito(estudo bigint)
returns boolean language plpgsql set search_path = public as $$
begin
  perform exigir_login();
  perform exigir_estudo(estudo);
  delete from favoritos where perfil_id = auth.uid() and estudo_id = estudo;
  if found then return false; end if;
  insert into favoritos (perfil_id, estudo_id) values (auth.uid(), estudo);
  return true;
end $$;

create or replace function marcar_progresso(estudo bigint, novo_status status_progresso)
returns status_progresso language plpgsql set search_path = public as $$
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
returns json language plpgsql set search_path = public as $$
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
returns void language plpgsql set search_path = public as $$
begin
  perform exigir_login();
  delete from comentarios where id = comentario and (perfil_id = auth.uid() or sou_equipe());
  if not found then raise exception 'Comentário não encontrado ou sem permissão para excluir'; end if;
end $$;

create or replace function publicar_estudo(titulo text, descricao text, disciplina_sigla text, arquivo_url text)
returns bigint language plpgsql set search_path = public as $$
#variable_conflict use_variable
declare did int; novo_id bigint;
begin
  perform exigir_equipe();
  if length(btrim(coalesce(titulo, ''))) not between 1 and 140 then raise exception 'O título deve ter entre 1 e 140 caracteres'; end if;
  if length(coalesce(descricao, '')) > 1000 then raise exception 'A descrição deve ter no máximo 1000 caracteres'; end if;
  if coalesce(btrim(arquivo_url), '') = '' then raise exception 'Informe o arquivo do estudo'; end if;
  if not (btrim(arquivo_url) ~ '^https://' or btrim(arquivo_url) like 'estudos/%') then raise exception 'URL do arquivo inválida'; end if;
  select id into did from disciplinas where sigla = disciplina_sigla;
  if did is null then raise exception 'Disciplina inválida'; end if;
  insert into estudos (titulo, descricao, disciplina_id, autor_id, arquivo_url)
  values (btrim(titulo), btrim(coalesce(descricao, '')), did, auth.uid(), btrim(arquivo_url))
  returning id into novo_id;
  return novo_id;
end $$;

create or replace function atualizar_arquivo(estudo bigint, nova_url text)
returns void language plpgsql set search_path = public as $$
begin
  perform exigir_equipe();
  if coalesce(btrim(nova_url), '') = '' then raise exception 'URL vazia'; end if;
  if not (btrim(nova_url) ~ '^https://' or btrim(nova_url) like 'estudos/%') then raise exception 'URL do arquivo inválida'; end if;
  update estudos set arquivo_url = btrim(nova_url) where id = estudo;
  if not found then raise exception 'Estudo não encontrado'; end if;
end $$;

create or replace function marcar_revisado(estudo bigint, valor boolean)
returns void language plpgsql set search_path = public as $$
begin
  perform exigir_equipe();
  update estudos set revisado = coalesce(valor, false) where id = estudo;
  if not found then raise exception 'Estudo não encontrado'; end if;
end $$;

-- Devolve o caminho do objeto no bucket (a página apaga o arquivo pela API do
-- Storage; apagar direto em storage.objects deixaria o arquivo órfão).
create or replace function excluir_estudo(estudo bigint)
returns text language plpgsql set search_path = public as $$
declare url text;
begin
  perform exigir_equipe();
  delete from estudos where id = estudo returning arquivo_url into url;
  if url is null then raise exception 'Estudo não encontrado'; end if;
  return substring(url from '/storage/v1/object/public/estudos/(.+)$');
end $$;

create or replace function atualizar_nome(novo_nome text)
returns void language plpgsql set search_path = public as $$
begin
  perform exigir_login();
  if length(btrim(coalesce(novo_nome, ''))) not between 1 and 80 then raise exception 'O nome deve ter entre 1 e 80 caracteres'; end if;
  update perfis set nome = btrim(novo_nome) where id = auth.uid();
end $$;

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
