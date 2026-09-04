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
calendario.html     feed do Canvas, grade do mês, botões por evento e assinatura
tema.css            paleta (variáveis de cor)
css/site.css        componentes do site
js/config.js        URL e chave anon do projeto Supabase
js/util.js          funções pequenas (esc, slug, avisos)
js/supabase.js      cliente e chamar(): a ponte com o backend
js/sessao.js        sessão, cabeçalho e guardas de página
js/ics.js           helpers de data e .ics para Google/Outlook/Apple
supabase/schema.sql todo o backend: tabelas, gatilhos, RLS, Storage, funções RPC, seed
supabase/teste/     testes do backend num Postgres local
supabase/functions/calendario/  Edge Function: importa o feed do Canvas e serve o .ics de assinatura
vendor/katex/       KaTeX local, usado pelos estudos de matemática
```

`tema.css` e `vendor/katex/` precisam continuar na raiz do site, porque os estudos (que vivem no Storage) são reescritos para carregá-los a partir da raiz. Os arquivos originais dos 8 estudos foram removidos do repositório depois da importação; ficam no histórico do git (até o commit 8cdbf50).

## Configurar o backend

1. Crie um projeto em [supabase.com](https://supabase.com).
2. **SQL Editor** → cole o conteúdo de `supabase/schema.sql` → **Run**.
3. **Authentication → Providers → Email**: para a demonstração, desligue *Confirm email* (senão cada cadastro precisa clicar no link do e-mail).
4. **Project Settings → API**: copie a *Project URL* e a chave *anon public* para `js/config.js`.
5. Sirva a pasta: `python3 -m http.server 8000` e abra <http://localhost:8000>.
6. Crie sua conta pelo site. Depois, no **Table Editor → perfis**, troque o seu `cargo` para `professor`.
7. Os 8 estudos já estão no Storage deste projeto. Se você criar um projeto Supabase do zero, o seed cadastra esses 8 com URL relativa `estudos/<arquivo>`: recupere a pasta `estudos/` do histórico do git (commit 8cdbf50), sirva o site e clique em **Publicar → Importar** para subi-los.

Para testar com um e-mail que não seja da PUC, insira o domínio na tabela `dominios_permitidos`.

## Cargos

| cargo | pode |
|---|---|
| visitante | ler os estudos e os comentários |
| aluno | favoritar, marcar progresso, comentar, apagar os próprios comentários |
| monitor / professor | tudo acima, mais publicar, marcar revisado, excluir estudos e comentários |

O cargo começa como `aluno` e só muda pelo painel do Supabase.

**Risco aceito**: o HTML publicado por monitor/professor roda na mesma origem do
site dentro do iframe, então quem publica precisa ser de confiança; uma mitigação
futura é o atributo `sandbox` no iframe.

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

## Testar o backend localmente

Precisa de Postgres 17 (`brew install postgresql@17`) e, para os testes da Edge Function, Deno 2 (`brew install deno`), ambos pelo Homebrew.

```
supabase/teste/rodar.sh          # sobe um Postgres na porta 5499, roda schema.sql e teste.sql
supabase/teste/rodar.sh parar    # desliga
HUB_TESTE=1 deno test --allow-env supabase/functions/calendario/   # parser/gerador de .ics e rotas (precisa do Deno 2)
```

## Publicar

É tudo estático: qualquer hospedagem de arquivos serve (GitHub Pages inclusive).
Suba o repositório com o `js/config.js` preenchido. A chave anon é pública por
desenho; quem protege os dados são as políticas RLS no banco.
