# Hub de Estudos · Calendário do Canvas — Desenho

Data: 2026-09-04
Status: aprovado em conversa, aguardando revisão do texto

## 1. Contexto e objetivo

O Hub de Estudos (spec anterior: `2026-09-04-hub-estudos-supabase-design.md`) ganha uma aba **Calendário**. Cada aluno cola a URL do feed de calendário do Canvas (o LMS da PUC, em `pucminas.instructure.com`), o hub baixa o feed, guarda os eventos como calendário **pessoal** daquele aluno e os entrega de três formas: uma grade mensal na própria aba, botões por evento para abrir no Google Agenda / Outlook / Apple Calendar, e um **link de assinatura** (`.ics`) que esses apps acompanham sozinhos.

Formato de entrada, observado no feed real do Lucas (68 eventos): `VCALENDAR` gerado por `icalendar-ruby`; cada `VEVENT` tem `UID` (`event-assignment-<id>` ou `event-assignment-override-<id>`), `DTSTART` em UTC (`20260807T100000Z`), `DTEND` só em parte dos eventos (52 são prazos sem duração), `SUMMARY` terminando com o curso entre colchetes, como `Atividade 02 [(6166100) Cálculo II]`, `DESCRIPTION` (às vezes vazia, com `\,` e `\n` escapados), `URL` para o Canvas e `X-ALT-DESC` em HTML (ignorada). Linhas longas vêm dobradas (continuação começa com espaço).

Decisões do Lucas:

- Calendário **pessoal**: só quem importou vê os próprios eventos.
- Entrada pela **URL do feed** (não por upload), com atualização automática. Isso exige um trecho de servidor, porque o navegador não consegue baixar do Instructure (CORS).
- Integração por **assinatura por link** mais **botões por evento**. Sem OAuth.
- Mesmas regras do projeto: HTML/CSS/JS puro no front, lógica no Supabase, CSS só em `css/site.css` + `tema.css`.

Fora desta versão: lembretes criados à mão, notificações, importação agendada no servidor (`pg_cron`), login com Google, upload de arquivo `.ics`.

## 2. Arquitetura

```
calendario.html ──rpc──▶ Postgres (calendario_config, eventos, funções)
      │
      └──fetch──▶ Edge Function "calendario"
                    ├─ POST /importar  (usuário logado) ──▶ baixa o feed do Canvas ──▶ rpc importar_eventos
                    └─ GET  /feed?token=…  (pública)  ──▶ rpc eventos_por_token ──▶ responde text/calendar
Google / Apple / Outlook ──assinam──▶ GET /feed?token=…
```

A Edge Function é o único código de servidor do projeto. Ela existe por dois motivos que o banco não resolve: buscar uma URL externa e responder `text/calendar` numa URL pública sem cabeçalhos. Tudo o que é regra de dados continua em SQL.

## 3. Banco de dados (bloco novo em `supabase/schema.sql`, antes do seed)

### 3.1 Tabelas

`calendario_config` (uma linha por usuário)
- `perfil_id uuid primary key references perfis(id) on delete cascade`
- `feed_url text` — URL pessoal do Canvas; contém um token do Canvas, por isso só o dono lê
- `token_feed text not null unique default encode(extensions.gen_random_bytes(16), 'hex')` — segredo do link de assinatura
- `ultima_importacao timestamptz`
- `ultimo_erro text`
- `atualizado_em timestamptz not null default now()`

`eventos`
- `id bigint generated always as identity primary key`
- `perfil_id uuid not null references perfis(id) on delete cascade`
- `uid text not null` — o `UID` do Canvas
- `titulo text not null check (length(titulo) between 1 and 300)` — `SUMMARY` sem o sufixo `[(código) curso]`
- `descricao text not null default '' check (length(descricao) <= 4000)`
- `inicio timestamptz not null`
- `fim timestamptz` — nulo quando o feed não traz `DTEND` ou ele é igual ao início (prazo)
- `dia_inteiro boolean not null default false`
- `url text check (url is null or url ~ '^https://')`
- `curso_codigo text`, `curso_nome text` — extraídos do sufixo do título; nulos se não houver
- `atualizado_em timestamptz not null default now()`
- `unique (perfil_id, uid)`

### 3.2 RLS

Ambas com RLS ligado. Políticas para `authenticated`: select, insert, update e delete só onde `perfil_id = auth.uid()`. `anon` não acessa nada. Políticas recriadas pelo mesmo laço de `drop policy` já usado no arquivo.

### 3.3 Funções RPC

Todas exigem login (`exigir_login()`), exceto `eventos_por_token`.

- `calendario_config_minha() returns json` — cria a linha do usuário se não existir e devolve `{feed_url, token_feed, ultima_importacao, ultimo_erro, total_eventos}`.
- `salvar_feed_url(url text) returns void` — aceita só `^https://[a-z0-9.-]+\.instructure\.com/feeds/calendars/[A-Za-z0-9_.-]+\.ics$`; senão `raise exception 'URL do feed inválida: cole o link do calendário do Canvas'`. Grava e limpa `ultimo_erro`.
- `importar_eventos(eventos json) returns integer` — recebe um array de `{uid, titulo, descricao, inicio, fim, dia_inteiro, url, curso_codigo, curso_nome}`; numa transação apaga os eventos do usuário e insere os recebidos (o último de cada `uid` vence), respeitando os checks (título cortado em 300, descrição em 4000, título vazio vira `(sem título)`); grava `ultima_importacao = now()` e `ultimo_erro = null`; devolve a quantidade. Rejeita entrada que não seja array com `raise exception 'Formato inválido'`.
- `registrar_erro_importacao(msg text) returns void` — grava `ultimo_erro` (cortado em 500 caracteres).
- `listar_eventos(de timestamptz, ate timestamptz) returns setof json` — eventos do usuário com `inicio` no intervalo, ordenados por `inicio, id`, no formato `{id, uid, titulo, descricao, inicio, fim, dia_inteiro, url, curso_codigo, curso_nome}`.
- `novo_token_feed() returns text` — gera outro token e o devolve.
- `eventos_por_token(token text) returns json` — `security definer`; `{nome, eventos: [...]}` do dono do token ou `null`. `revoke execute ... from public, anon, authenticated`; só `service_role` executa (a rota pública da função usa a chave de serviço, que fica só no servidor).

## 4. Edge Function `calendario`

Arquivo único `supabase/functions/calendario/index.ts` (Deno, TypeScript), para poder ser colado no editor do painel do Supabase. Exporta as funções puras e só chama `Deno.serve(tratar)` quando `import.meta.main`.

### 4.1 Rotas

Caminho é o último segmento da URL (`/functions/v1/calendario/<rota>`). Toda resposta tem `Access-Control-Allow-Origin: *` e `Access-Control-Allow-Headers: authorization, apikey, content-type`; `OPTIONS` responde 204.

`POST /importar`
1. Exige `Authorization: Bearer <jwt do usuário>`; cria o cliente com a chave anon e esse cabeçalho; `auth.getUser()` inválido → 401 `{erro: 'Faça login'}`.
2. `rpc('calendario_config_minha')` → sem `feed_url` → 400 `{erro: 'Salve a URL do feed primeiro'}`.
3. Baixa a URL com timeout de 20 s e limite de 5 MB; status diferente de 200 ou corpo sem `BEGIN:VCALENDAR` → erro.
4. `lerEventos(texto)` → `rpc('importar_eventos', {eventos})` → 200 `{importados: n}`.
5. Qualquer erro nos passos 3–4: `rpc('registrar_erro_importacao', {msg})` e resposta 502 `{erro: msg}` (mensagem em português, sem a URL do feed).

`GET /feed?token=<token>`
1. Sem token → 400. Cliente com a chave de serviço (`SUPABASE_SERVICE_ROLE_KEY`, injetada pelo Supabase) → `rpc('eventos_por_token', {token})` → `null` → 404 `Calendário não encontrado`.
2. `escreverCalendario(nome, eventos)` → 200, `Content-Type: text/calendar; charset=utf-8`, `Content-Disposition: inline; filename="hub-estudos.ics"`, `Cache-Control: public, max-age=300`.

Outra rota → 404. "Verify JWT" fica **desligado** na função (a rota do feed é pública); a rota de importar faz a própria checagem no passo 1.

### 4.2 Funções puras (testáveis com `deno test`)

- `desdobrar(texto)` — junta linhas de continuação (RFC 5545) e normaliza `\r\n`.
- `lerEventos(texto) → Evento[]` — percorre `BEGIN:VEVENT … END:VEVENT`; lê `UID`, `SUMMARY`, `DESCRIPTION` (desescapa `\,` `\;` `\n` `\\`), `URL`, `DTSTART`, `DTEND`. Datas: `…Z` → UTC; `VALUE=DATE` → `dia_inteiro = true`, `inicio` = meia-noite UTC daquele dia, `fim` = nulo; `TZID=<zona>` → converte para UTC com `Intl` (melhor esforço); sem sufixo → trata como UTC. `fim` igual ao `inicio` ou anterior → nulo. Ignora eventos sem `UID` ou sem `DTSTART`. Não lança exceção por evento malformado: pula e segue.
- `extrairCurso(summary) → {titulo, curso_codigo, curso_nome}` — casa `\[\((\d+)\)\s*([^\]]+)\]\s*$`; sem casamento, devolve o título inteiro e nulos.
- `escreverCalendario(nome, eventos) → string` — `VCALENDAR` com `PRODID:-//Hub de Estudos//PT-BR`, `X-WR-CALNAME:Hub de Estudos · <nome>`, um `VEVENT` por evento: `UID:<uid>@hub-estudos`, `DTSTAMP`, `DTSTART`/`DTEND` (dia inteiro: `VALUE=DATE`, `DTEND` = dia seguinte; sem fim: `DTEND` = início + 30 min), `SUMMARY` com o curso entre parênteses no fim, `DESCRIPTION` escapada, `URL`. Linhas dobradas em 75 octetos, `\r\n`.

## 5. Front

### 5.1 Arquivos

```
calendario.html      página nova (só logado)
js/ics.js            helpers puros: datas para Google/Outlook, .ics de um evento, formatação
js/supabase.js       ganha chamarFuncao(rota, opcoes) → fetch na Edge Function com o JWT da sessão
js/sessao.js         cabeçalho ganha o link "Calendário" quando logado
css/site.css         classes da grade e da lista
README.md            seção do calendário: feed do Canvas, deploy da função, assinatura
```

### 5.2 `chamarFuncao(rota, opcoes)`

`fetch(CONFIG.SUPABASE_URL + '/functions/v1/calendario/' + rota, {method, headers: {Authorization: 'Bearer ' + session.access_token, apikey: CONFIG.SUPABASE_ANON_KEY, 'Content-Type': 'application/json'}})`. Devolve o JSON; se a resposta não for 2xx lança `Error(json.erro || 'Erro na função')`. Sem sessão lança "Faça login".

### 5.3 Página `calendario.html`

`exigirLogin()`, depois `calendario_config_minha()`. Quatro blocos, de cima para baixo:

1. **Fonte.** Campo com a URL do feed (preenchido se já houver), botão **Salvar e importar** (`salvar_feed_url` → `chamarFuncao('importar')`), botão **Atualizar agora**, e a linha de estado: "Última importação: <data> · <n> eventos" ou o `ultimo_erro` em `.aviso-erro`. Link "Onde acho essa URL?" que abre um `<details>` com o caminho no Canvas (Calendário → Feed do calendário → copiar o link). Ao abrir a página, se houver `feed_url` e a última importação for nula ou tiver mais de 6 horas, a importação roda sozinha e a página mostra "Atualizando…".
2. **Mês.** Cabeçalho com "‹ mês ›" e botão **Hoje**; chips de filtro por curso (todos + um por `curso_nome` presente nos eventos carregados); grade 7 colunas × 5 ou 6 linhas, começando na segunda; cada dia mostra o número e até 3 chips com o título (o resto vira "+n"); dia atual destacado; dias de outro mês esmaecidos. Os eventos do mês vêm de `listar_eventos(primeiro dia da grade, último dia da grade)`.
3. **Lista do mês.** Os mesmos eventos agrupados por dia, cada um com hora (ou "dia inteiro"), título, curso, descrição (colapsada com `<details>` quando houver), link "abrir no Canvas" e três botões: **Google** (`calendar.google.com/calendar/render?action=TEMPLATE&text=…&dates=…&details=…`), **Outlook** (`outlook.live.com/calendar/0/deeplink/compose?subject=…&startdt=…&enddt=…&body=…&path=/calendar/action/compose&rru=addevent`) e **Apple / .ics** (baixa um `.ics` de um evento gerado por `js/ics.js`). Evento sem fim usa início + 30 min nos três; dia inteiro usa os formatos de data.
4. **Assinar no seu app.** Mostra `https://<projeto>/functions/v1/calendario/feed?token=<token>` e a variante `webcal://`, cada uma com botão **Copiar**; instruções de uma linha para Google Agenda (Outras agendas → Por URL), Apple Calendar (Arquivo → Nova assinatura de calendário) e Outlook (Adicionar calendário → Assinar da Web); botão **Gerar novo link** (`novo_token_feed`, com `confirm`).

Datas exibidas no fuso do navegador (`toLocaleString('pt-BR')`); eventos de dia inteiro exibidos pela data UTC sem conversão de hora.

### 5.4 Erros

Como nas outras páginas: cada chamada em `try/catch`, mensagem em `.aviso-erro` da própria página. Erros de importação também ficam gravados em `ultimo_erro` e aparecem na linha de estado. Sem `feed_url`, os blocos 2 e 3 mostram "Cole a URL do feed do Canvas para começar".

## 6. Deploy e configuração (vai para o README)

1. Rodar o `supabase/schema.sql` de novo no SQL Editor (o bloco novo é re-executável).
2. Painel do Supabase → Edge Functions → **Deploy a new function** → via editor → nome `calendario` → colar `supabase/functions/calendario/index.ts` → desligar **Verify JWT** → Deploy. Alternativa: `brew install supabase/tap/supabase`, `supabase login`, `supabase functions deploy calendario --project-ref <ref> --no-verify-jwt` (o login é do Lucas, no terminal dele).
3. Nada de segredo novo: a função recebe `SUPABASE_URL`, `SUPABASE_ANON_KEY` e `SUPABASE_SERVICE_ROLE_KEY` automaticamente.
4. Privacidade: a URL do feed do Canvas fica só na linha do dono; o link de assinatura contém apenas um token aleatório de 128 bits, trocável em "Gerar novo link".

## 7. Testes

1. **SQL** (harness existente): criação da config na primeira chamada e reaproveitamento depois; token único por usuário; `salvar_feed_url` recusa URL fora do padrão e aceita a do Canvas; `importar_eventos` substitui (importar 3, depois 2 → sobram 2), deduplica por `uid`, corta título longo, recusa não-array; `listar_eventos` respeita o intervalo e a ordem; RLS: outro usuário não vê eventos nem config; `eventos_por_token` devolve `null` para token desconhecido e falha para `anon`/`authenticated`; `novo_token_feed` muda o token e invalida o antigo.
2. **Deno** (`deno test supabase/functions/calendario/`): `desdobrar` com linhas dobradas; `lerEventos` com um fixture sintético de 4 eventos cobrindo prazo sem `DTEND`, evento com duração, dia inteiro e descrição escapada; `extrairCurso`; `escreverCalendario` gera `VCALENDAR` válido (dobra de linhas, `VALUE=DATE`, `DTEND` de 30 min) e é relido por `lerEventos` com os mesmos títulos; `tratar` responde 204 a `OPTIONS`, 401 sem `Authorization` em `/importar`, 400 sem token em `/feed`, 404 em rota desconhecida (sem tocar no Supabase).
3. **Ponta a ponta**, depois que o Lucas publicar a função: colar o feed dele, importar os 68 eventos, ver setembro e outubro na grade, filtrar por Cálculo II, abrir um evento no Google Agenda, baixar um `.ics`, `curl` no link de assinatura devolvendo `text/calendar` com 68 `VEVENT`, assinar no Apple Calendar ou Google, gerar novo link e confirmar que o antigo dá 404.
