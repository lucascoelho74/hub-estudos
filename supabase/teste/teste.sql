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
