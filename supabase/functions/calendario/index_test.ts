import { assert, assertEquals, assertMatch } from "jsr:@std/assert@1";
import { cliente, desdobrar, escolherFabrica, escreverCalendario, extrairCurso, lerData, lerEventos, tratar, validarUrlFeed } from "./index.ts";
import type { Evento } from "./index.ts";

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

Deno.test("escapar e desescapar são inversos exatos, inclusive barra seguida de n", () => {
  const original: Evento = {
    uid: "e-barra", titulo: "Vetor \\nabla f", descricao: "caminho C:\\Notas\\prova.pdf, ok; fim\nlinha 2",
    inicio: "2026-09-10T10:00:00.000Z", fim: null, dia_inteiro: false, url: null, curso_codigo: null, curso_nome: null,
  };
  const relido = lerEventos(escreverCalendario("Ana", [original]))[0];
  assertEquals(relido.titulo, original.titulo);
  assertEquals(relido.descricao, original.descricao);
});

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

Deno.test("escolherFabrica: usa a fábrica só quando é função (Deno.serve passa info no 2º argumento)", () => {
  const minha = () => { throw new Error("x"); };
  assertEquals(escolherFabrica(minha), minha);
  assertEquals(escolherFabrica({ remoteAddr: {} }), cliente);
  assertEquals(escolherFabrica(undefined), cliente);
});

Deno.test("tratar: um 2º argumento que não é função (como o info do Deno.serve) não quebra o roteamento", async () => {
  // deno-lint-ignore no-explicit-any
  const r = await tratar(new Request(BASE + "/outra"), { remoteAddr: {} } as any);
  assertEquals(r.status, 404);
  // deno-lint-ignore no-explicit-any
  const o = await tratar(new Request(BASE + "/importar", { method: "OPTIONS" }), { remoteAddr: {} } as any);
  assertEquals(o.status, 204);
});

Deno.test("validarUrlFeed aceita só https em *.instructure.com terminando em .ics", () => {
  assertEquals(validarUrlFeed("https://pucminas.instructure.com/feeds/calendars/user_abc.ics"), true);
  assertEquals(validarUrlFeed("https://canvas.instructure.com/feeds/calendars/x.ics"), true);
  assertEquals(validarUrlFeed("http://pucminas.instructure.com/feeds/calendars/user_abc.ics"), false);
  assertEquals(validarUrlFeed("https://evil.example/instructure.com/x.ics"), false);
  assertEquals(validarUrlFeed("https://instructure.com.evil.example/x.ics"), false);
  assertEquals(validarUrlFeed("https://pucminas.instructure.com/feeds/calendars/x.txt"), false);
  assertEquals(validarUrlFeed("nada"), false);
});
