# Hub de Estudos · Plataforma com Supabase — Desenho

Data: 2026-09-04
Status: aprovado em conversa, aguardando revisão do texto

## 1. Contexto e objetivo

O Hub de Estudos hoje é um site estático (GitHub Pages) com uma página inicial que lista 8 estudos em HTML lidos de um arquivo `estudos.js`. Este desenho transforma o hub em uma plataforma de estudo colaborativa para o curso de Ciência da Computação da PUC Minas, como prova de conceito do Trabalho Interdisciplinar 2 (TI2). O objetivo desta versão é demonstrar a ideia ao professor; a equipe refaz o código depois.

Requisitos dados pelo Lucas:

- HTML, CSS e JavaScript puros. Sem React, sem framework, sem build.
- O máximo possível da lógica no backend. O site deixa de ser estático: catálogo, estudos, usuários, favoritos, progresso e comentários vivem no backend.
- Toda a customização visual em CSS, da forma mais simples possível.
- Backend: somente Supabase (Postgres, Auth, Storage). Sem servidor Node.
- Cargos: aluno, monitor e professor. Só monitor e professor publicam. Aluno lê, favorita, marca progresso e comenta.
- Cadastro só com e-mail da PUC (`sga.pucminas.br` e `pucminas.br`).
- Evoluir o repositório `hub-estudos` existente; pode alterar bastante o que existe.

Fora desta versão: fluxo de aprovação de estudos, edição de estudo depois de publicado, notificações, login com Google, painel de administração de cargos (cargo é promovido pelo painel do Supabase).

## 2. Arquitetura

```
navegador (HTML + site.css + JS fino)
   │  supabase-js via CDN
   ▼
Supabase
   ├── Auth        e-mail + senha
   ├── Postgres    tabelas, RLS, gatilhos e funções RPC (toda a lógica)
   └── Storage     bucket público "estudos" com os arquivos HTML
```

Regra central: **o front só chama funções RPC, Auth e Storage.** Nenhuma página monta consulta em tabela. Cada função devolve JSON pronto para desenhar. Se uma regra de negócio precisa existir (quem pode o quê, validação, contagem, busca), ela mora no SQL.

Todo o backend está em um único arquivo, `supabase/schema.sql`, que se cola no editor SQL do projeto Supabase. Ele é idempotente o bastante para ser rodado uma vez em projeto novo.

## 3. Banco de dados

### 3.1 Tipos

- `cargo`: `aluno` | `monitor` | `professor`
- `status_progresso`: `estudando` | `concluido`

### 3.2 Tabelas

`dominios_permitidos`
- `dominio text primary key` — seed: `sga.pucminas.br`, `pucminas.br`. Para testar com outro e-mail, insere-se o domínio aqui pelo painel.

`perfis` (um por usuário do Auth)
- `id uuid primary key references auth.users(id) on delete cascade`
- `nome text not null`
- `email text not null unique`
- `cargo cargo not null default 'aluno'`
- `criado_em timestamptz not null default now()`

`disciplinas`
- `id serial primary key`
- `sigla text not null unique` (ex.: `AEDS1`, `AEDS2`, `CALC2`, `DIW`)
- `nome text not null`
- `periodo smallint`

`estudos`
- `id bigint generated always as identity primary key`
- `titulo text not null` (1–140 caracteres)
- `descricao text not null default ''` (até 1000)
- `disciplina_id int references disciplinas(id)`
- `autor_id uuid references perfis(id) on delete set null`
- `arquivo_url text not null` — relativa (`estudos/x.html`, só para os 8 iniciais antes da importação) ou absoluta (URL pública do Storage)
- `revisado boolean not null default false`
- `publicado_em timestamptz not null default now()`

`favoritos`
- `perfil_id uuid references perfis(id) on delete cascade`
- `estudo_id bigint references estudos(id) on delete cascade`
- `criado_em timestamptz default now()`
- chave primária `(perfil_id, estudo_id)`

`progresso`
- `perfil_id`, `estudo_id` (mesmas referências), `status status_progresso not null`, `atualizado_em timestamptz default now()`
- chave primária `(perfil_id, estudo_id)`

`comentarios`
- `id bigint generated always as identity primary key`
- `estudo_id bigint references estudos(id) on delete cascade`
- `perfil_id uuid references perfis(id) on delete cascade`
- `texto text not null check (length(btrim(texto)) between 1 and 2000)`
- `criado_em timestamptz not null default now()`

### 3.3 Gatilhos

- `auth.users` **before insert**: se `email_permitido(new.email)` for falso, `raise exception 'E-mail fora dos domínios permitidos'`. O Supabase devolve "Database error saving new user"; por isso o front valida o domínio antes de chamar o cadastro e mostra mensagem amigável. O gatilho é a garantia.
- `auth.users` **after insert**: cria a linha em `perfis` com `nome = raw_user_meta_data->>'nome'` (ou a parte do e-mail antes do `@`) e `email`.
- `perfis` **before update**: se `new.cargo` mudou e `auth.role() = 'authenticated'`, `raise exception 'Cargo só muda pelo painel'`. Pelo painel do Supabase a sessão não é `authenticated`, então a promoção funciona.

### 3.4 Funções auxiliares (security definer, `search_path = public`)

- `email_permitido(email text) returns boolean` — domínio após o `@` existe em `dominios_permitidos` (comparação sem maiúsculas).
- `meu_cargo() returns cargo` — cargo do `auth.uid()`; `null` se anônimo.
- `sou_equipe() returns boolean` — `meu_cargo() in ('monitor','professor')`.
- `exigir_login()` — `raise exception 'Faça login'` se `auth.uid()` for nulo.
- `exigir_equipe()` — `raise exception 'Só monitor ou professor'` se `sou_equipe()` for falso.

### 3.5 Funções RPC (a API do site)

Leitura (security definer, para poder juntar `perfis` sem expor e-mails):

- `listar_disciplinas() returns setof disciplinas` — ordem por período e sigla.
- `buscar_estudos(texto text default '', disciplina text default null) returns setof json`. Filtra por `unaccent(titulo || descricao) ilike unaccent('%texto%')` e, se `disciplina` não for nula, pela sigla. Ordena por `publicado_em desc`. Cada item: `{id, titulo, descricao, disciplina_sigla, disciplina_nome, autor_nome, autor_cargo, revisado, publicado_em, arquivo_url, total_favoritos, total_comentarios, favoritado, progresso}`. `favoritado` e `progresso` refletem o usuário logado (`false`/`null` se anônimo).
- `painel_estudo(estudo bigint) returns json` — `{estudo: <mesmo formato acima>, comentarios: [{id, texto, criado_em, autor_nome, autor_cargo, meu}]}`; `null` se não existir. `meu` indica se o comentário é do usuário logado.
- `meu_perfil() returns json` — `{id, nome, email, cargo, favoritos: [{id, titulo, disciplina_sigla}], progresso: [{id, titulo, disciplina_sigla, status}]}`; `null` se anônimo.
- `estudos_para_importar() returns setof json` — `{id, titulo, arquivo_url}` dos estudos cuja URL não começa com `http`. Exige equipe.

Escrita (todas chamam `exigir_login()`; as de equipe chamam `exigir_equipe()`):

- `alternar_favorito(estudo bigint) returns boolean` — insere ou remove; devolve o novo estado.
- `marcar_progresso(estudo bigint, novo_status status_progresso) returns status_progresso` — upsert; `null` remove a linha e devolve `null`.
- `comentar(estudo bigint, texto text) returns json` — insere e devolve o comentário no formato de `painel_estudo`.
- `excluir_comentario(comentario bigint) returns void` — permitido ao autor ou à equipe; senão `raise`.
- `publicar_estudo(titulo text, descricao text, disciplina_sigla text, arquivo_url text) returns bigint` — equipe; valida tamanhos e sigla; `autor_id = auth.uid()`.
- `atualizar_arquivo(estudo bigint, nova_url text) returns void` — equipe.
- `marcar_revisado(estudo bigint, valor boolean) returns void` — equipe.
- `excluir_estudo(estudo bigint) returns text` — equipe; apaga a linha e devolve o caminho do objeto no bucket `estudos` (ou `null` se a URL não for do Storage). Apagar direto em `storage.objects` deixaria o arquivo órfão no Supabase, então quem remove o arquivo é a página, via API do Storage, com o caminho devolvido.
- `atualizar_nome(novo_nome text) returns void` — usuário logado, 1–80 caracteres.

Erros de negócio saem como `raise exception` com mensagem em português; o front mostra a mensagem como veio.

### 3.6 RLS (defesa em profundidade para acesso direto às tabelas)

RLS ligado em todas as tabelas. As funções RPC são o caminho oficial; estas políticas limitam o que a chave anon consegue fazer direto:

| tabela | select | insert | update | delete |
|---|---|---|---|---|
| dominios_permitidos | ninguém | ninguém | ninguém | ninguém |
| perfis | só a própria linha | ninguém (gatilho cria) | só a própria linha | ninguém |
| disciplinas | todos | equipe | equipe | equipe |
| estudos | todos | equipe | equipe | equipe |
| favoritos | só as próprias | só as próprias | ninguém | só as próprias |
| progresso | só as próprias | só as próprias | só as próprias | só as próprias |
| comentarios | todos | logado, `perfil_id = auth.uid()` | ninguém | autor ou equipe |

### 3.7 Storage

- Bucket `estudos`, público para leitura, tipo permitido `text/html`, limite 5 MB por arquivo.
- Políticas em `storage.objects`: select para todos; insert, update e delete só quando `bucket_id = 'estudos'` e `sou_equipe()`.
- Nome do objeto dentro do bucket: `<timestamp>-<slug do título>.html` na publicação; `<id>-<nome original>.html` na importação.

### 3.8 Seed

- Domínios: `sga.pucminas.br`, `pucminas.br`.
- Disciplinas: AEDS1, CALC1, TI1 (1º período); AEDS2, CALC2, DIW, BD1, ES (2º período).
- Os 8 estudos atuais, com `arquivo_url = 'estudos/<arquivo>'`, `revisado = true`, `autor_id = null`, e a descrição já existente em `estudos.js`. Mapeamento: java-primeiros-passos, resumo-java-interativo, conceitos-java-interativo, java-para-quem-sabe-c-cpp e trilha-beecrowd-c-java em AEDS2; resumo-c-cpp e questoes-de-c em AEDS1; guia-integrais em CALC2.

## 4. Front

### 4.1 Arquivos

```
index.html          catálogo
entrar.html         login e cadastro
estudo.html         ?id=N  estudo + comentários
publicar.html       equipe: publicar e importar
perfil.html         perfil, favoritos, progresso, sair
tema.css            paleta (permanece na raiz: os estudos leem ../tema.css)
css/site.css        componentes compartilhados do site
js/config.js        SUPABASE_URL e SUPABASE_ANON_KEY
js/supabase.js      cria o cliente e expõe chamar(nome, params)
js/sessao.js        sessão, perfil, cabeçalho, guardas de página
js/util.js          esc(), formatarData(), parametro()
supabase/schema.sql todo o backend
estudos/            fonte da importação; pode ser apagada depois
vendor/katex/       KaTeX local (os estudos usam)
README.md           configuração e uso
```

Removidos: `estudos.js` (a lista agora vem do banco) e o `<script>` embutido do `index.html` antigo.

### 4.2 JS compartilhado

`js/supabase.js` carrega `@supabase/supabase-js@2` pelo CDN (jsDelivr, build UMD) e cria `window.db`. Expõe `chamar(nome, params)`: faz `db.rpc(nome, params)`, e se vier erro lança `Error` com a mensagem traduzida (`Invalid login credentials` → "E-mail ou senha incorretos", `Database error saving new user` → "E-mail fora dos domínios permitidos", demais mensagens passam como estão).

`js/sessao.js`:
- `sessao()` — devolve `{usuario, perfil}` (perfil via `meu_perfil()`), com cache por página.
- `montarCabecalho()` — preenche `<header id="cabecalho">` com logo, links (Início, Publicar se equipe, Perfil ou Entrar).
- `exigirLogin()` — se anônimo, redireciona para `entrar.html?voltar=<página atual>`.
- `exigirEquipe()` — se não for equipe, redireciona para `index.html?aviso=so-equipe`.
- `sair()` — `db.auth.signOut()` e volta ao início.

Cada página tem um `<script>` próprio, curto, no padrão "chama a função, desenha o resultado, liga os botões".

### 4.3 Páginas

**index.html** — chama `listar_disciplinas()` e `buscar_estudos(texto, disciplina)`. Campo de busca (com atalho `/`), chips de disciplina (todas + uma por disciplina), grade de cards. Card: sigla da disciplina, título, descrição, autor, selo "revisado", contagens, botão de favoritar (coração) e selo do progresso. Favoritar sem login leva para `entrar.html`. A busca é refeita no servidor a cada mudança (com debounce de 250 ms). Se a URL trouxer `?aviso=so-equipe`, mostra o aviso "Só monitor ou professor pode publicar".

**entrar.html** — duas abas: Entrar (e-mail, senha) e Cadastrar (nome, e-mail, senha). Cadastro valida o domínio no front antes de chamar `signUp` com `options.data.nome`. Se o projeto exigir confirmação de e-mail (`data.session` nulo), mostra "Confira seu e-mail". Depois de entrar, volta para `?voltar=` ou para o início.

**estudo.html?id=N** — chama `painel_estudo(N)`. Barra superior: voltar, título, disciplina, autor, botões de favoritar e progresso (Estudando / Concluído / Limpar), e para equipe "Marcar revisado" e "Excluir" (chama `excluir_estudo`, remove o arquivo do Storage com o caminho devolvido e volta ao início). Abaixo, o estudo em um `<iframe>` de altura `calc(100vh - barra)`: o JS faz `fetch(arquivo_url)`, injeta `<base href="<origem do site>/estudos/">` logo após `<head>` e atribui a `srcdoc`. Assim `../tema.css` e `../vendor/katex/...` continuam resolvendo, tanto para arquivo do repositório quanto para o Storage. Abaixo do iframe, comentários: lista (autor, selo do cargo, data, botão excluir quando `meu` ou equipe) e formulário (só logado; anônimo vê link para entrar).

**publicar.html** — `exigirEquipe()`. Formulário: título, descrição, disciplina (de `listar_disciplinas()`), arquivo HTML (obrigatório, até 5 MB, `.html`). Fluxo: sobe o arquivo no bucket `estudos` como `<timestamp>-<slug>.html`, pega a URL pública e chama `publicar_estudo(...)`. Sucesso redireciona para `estudo.html?id=<novo>`. Seção "Importar estudos do repositório": chama `estudos_para_importar()`; para cada um, `fetch(arquivo_url)` relativo, sobe no bucket como `<id>-<nome>.html`, chama `atualizar_arquivo`. Mostra progresso item a item e erros sem parar o lote.

**perfil.html** — `exigirLogin()`, `meu_perfil()`. Nome (editável via `atualizar_nome`), e-mail, cargo com selo, listas de favoritos e de progresso com links, botão Sair.

### 4.4 CSS

`tema.css` não muda (paleta "café" escura, variáveis). `css/site.css` define, com nomes simples e sem aninhamento profundo: `.cabecalho`, `.conteudo`, `.botao` (+ `.botao-secundario`, `.botao-perigo`), `.campo` (label + input/textarea/select), `.aviso` (+ `.aviso-erro`, `.aviso-ok`), `.card`, `.grade`, `.chip` (+ `.chip-ativo`), `.selo` (+ `.selo-monitor`, `.selo-professor`, `.selo-revisado`), `.comentario`, `.quadro-estudo` (o iframe), `.abas`. Um `@media (max-width: 640px)` no fim para a grade virar uma coluna e o cabeçalho empilhar. As páginas não têm `<style>` nem `style=""`.

## 5. Tratamento de erro

- Toda chamada ao backend está dentro de `try/catch`; a mensagem vai para um `.aviso-erro` da própria página, nunca para `alert`.
- Sem `js/config.js` preenchido: `supabase.js` detecta o placeholder e mostra no topo "Configure js/config.js" em vez de quebrar.
- Estudo inexistente: `estudo.html` mostra "Estudo não encontrado" com link para o início.
- Falha ao carregar o HTML do estudo (rede, CORS): mostra aviso e um link direto para `arquivo_url`.
- Upload maior que 5 MB ou não `.html`: bloqueado no front antes de enviar; o bucket bloqueia de novo no servidor.

## 6. Testes e validação

Não há Node, Docker nem CLI do Supabase na máquina. A validação é em duas camadas:

1. **SQL localmente**: instalar Postgres via Homebrew, criar um banco de teste com stubs mínimos dos schemas `auth` (tabela `users`, funções `uid()` e `role()` lendo uma variável de sessão) e `storage` (tabela `objects`, `buckets`), rodar `schema.sql` inteiro e um `supabase/teste.sql` que simula usuários (aluno, monitor, anônimo) e confere: domínio recusado, perfil criado, aluno não publica, equipe publica, favoritar alterna, progresso faz upsert, comentário do outro não pode ser excluído por aluno, busca acha com e sem acento, `excluir_estudo` devolve o caminho do objeto. O teste falha com `raise` se algo divergir.
2. **Ponta a ponta no navegador**: servir com `python3 -m http.server 8000`, abrir no navegador integrado. Antes do Supabase existir: todas as páginas abrem e mostram o aviso de configuração. Depois de o Lucas criar o projeto, colar o `schema.sql` e preencher `js/config.js`: cadastrar aluno, entrar, buscar e filtrar, favoritar, marcar progresso, comentar, promover a professor pelo painel, publicar com upload, importar os 8 estudos, abrir um estudo importado do Storage (KaTeX e CSS funcionando), excluir estudo, sair.

## 7. Configuração (vai para o README)

1. Criar projeto em supabase.com.
2. SQL Editor → colar `supabase/schema.sql` → Run.
3. Authentication → Providers → Email: para a demo, desligar "Confirm email".
4. Project Settings → API: copiar URL e chave `anon` para `js/config.js`.
5. Rodar `python3 -m http.server 8000` e abrir `http://localhost:8000`.
6. Cadastrar-se, depois em Table Editor → `perfis` trocar o próprio `cargo` para `professor`.
7. Em Publicar, clicar "Importar estudos do repositório". Depois, opcionalmente, apagar a pasta `estudos/`.
8. Para o GitHub Pages: subir tudo, incluindo `js/config.js` (a chave anon é pública por desenho; a segurança está nas políticas RLS).
