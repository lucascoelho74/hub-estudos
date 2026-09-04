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
