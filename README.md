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

## Cargos

| cargo | pode |
|---|---|
| visitante | ler os estudos e os comentários |
| aluno | favoritar, marcar progresso, comentar, apagar os próprios comentários |
| monitor / professor | tudo acima, mais publicar, marcar revisado, excluir estudos e comentários |

## Calendário do Canvas

Cada aluno cola a URL do próprio feed do Canvas (Calendário → *Feed do calendário* → link `.ics`) na aba **Calendário**. O hub baixa o feed, guarda os eventos como calendário pessoal (só o dono vê), mostra a grade do mês e oferece:

- botões **Google**, **Outlook** e **Apple / .ics** em cada evento;
- um **link de assinatura** (`…/functions/v1/calendario/feed?token=…`) que Google Agenda, Apple Calendar e Outlook acompanham sozinhos. O link contém só um token aleatório; "Gerar novo link" invalida o antigo.

```
supabase/teste/rodar.sh          # sobe um Postgres na porta 5499, roda schema.sql e teste.sql
supabase/teste/rodar.sh parar    # desliga
HUB_TESTE=1 deno test --allow-env supabase/functions/calendario/   # parser/gerador de .ics e rotas (precisa do Deno 2)
```
