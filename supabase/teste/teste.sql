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

grant usage on schema teste to anon, authenticated, service_role;
grant execute on all functions in schema teste to anon, authenticated, service_role;

select teste.confere(true, 'helpers carregados');

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

insert into auth.users (id, email, raw_user_meta_data) values
  ('44444444-4444-4444-4444-444444444444', 'longo@sga.pucminas.br', jsonb_build_object('nome', repeat('x', 100)));
select teste.confere(length((select nome from perfis where id = '44444444-4444-4444-4444-444444444444')) = 80, 'nome longo é cortado em 80 no cadastro');
delete from auth.users where id = '44444444-4444-4444-4444-444444444444';

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

-- ---------- Tarefa 3: RLS e Storage (acesso direto às tabelas) ----------
-- "set local role" faz a sessão agir como o role da API; RLS passa a valer.
select teste.entrar('11111111-1111-1111-1111-111111111111');
set local role authenticated;
select teste.confere((select count(*) from perfis) = 1, 'aluno só enxerga o próprio perfil');
select teste.confere((select count(*) from dominios_permitidos) = 0, 'ninguém lê domínios direto');
select teste.confere((select count(*) from estudos) = 8, 'aluno lê todos os estudos');
select teste.confere((select count(*) from disciplinas) = 8, 'aluno lê disciplinas');
select teste.espera_erro($$insert into estudos (titulo, arquivo_url) values ('x', 'y')$$, 'aluno não insere estudo direto');
delete from estudos where id = 1;
select teste.confere((select count(*) from estudos) = 8, 'aluno não apaga estudo direto');
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
  perform teste.espera_erro('select atualizar_nome(repeat(''x'', 81))', 'nome com 81 caracteres é recusado');
  perform atualizar_nome('Ana Silva');
  perform teste.confere((meu_perfil() ->> 'nome') = 'Ana Silva', 'nome atualizado');
end $$;
reset role;

-- Monitor
select teste.entrar('22222222-2222-2222-2222-222222222222');
set local role authenticated;
do $$
declare novo bigint; caminho text; guia bigint := teste.id_estudo('guia-integrais.html'); rel bigint;
begin
  perform teste.espera_erro('select publicar_estudo('''', ''D'', ''AEDS1'', ''https://x/y.html'')', 'título vazio é recusado');
  perform teste.espera_erro('select publicar_estudo(''T'', ''D'', ''NAOEXISTE'', ''https://x/y.html'')', 'disciplina inválida é recusada');
  perform teste.espera_erro('select publicar_estudo(''T'', ''D'', ''AEDS1'', '''')', 'arquivo vazio é recusado');
  perform teste.espera_erro('select publicar_estudo(''T'', ''D'', ''AEDS1'', ''javascript:alert(1)'')', 'URL com esquema inválido é recusada');
  perform teste.espera_erro('select atualizar_arquivo(' || guia || ', ''javascript:alert(1)'')', 'atualizar_arquivo com esquema inválido é recusado');

  rel := publicar_estudo('Rel', '', 'AEDS1', 'estudos/x.html');
  perform teste.confere(rel > 0, 'URL relativa estudos/ é aceita');
  perform excluir_estudo(rel);

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
