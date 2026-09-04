// Edge Function "calendario" do Hub de Estudos.
//   POST /calendario/importar        usuário logado: baixa o feed do Canvas e grava os eventos
//   GET  /calendario/feed?token=…    pública: devolve o calendário do usuário em .ics
// Arquivo único de propósito: dá para colar inteiro no editor do painel do Supabase.
// As rotas entram na próxima tarefa; esta parte é só leitura e escrita de .ics.

export type Evento = {
  uid: string;
  titulo: string;
  descricao: string;
  inicio: string;          // ISO em UTC
  fim: string | null;      // nulo = prazo sem duração
  dia_inteiro: boolean;
  url: string | null;
  curso_codigo: string | null;
  curso_nome: string | null;
};

// ---------- leitura ----------

// Junta linhas de continuação (RFC 5545: a continuação começa com espaço ou tab) e normaliza \r\n.
export function desdobrar(texto: string): string {
  return texto.replace(/\r\n?/g, "\n").replace(/\n[ \t]/g, "");
}

function desescapar(s: string): string {
  return s.replace(/\\n/gi, "\n").replace(/\\,/g, ",").replace(/\\;/g, ";").replace(/\\\\/g, "\\");
}

// "DTSTART;VALUE=DATE:20260807" → { params: { VALUE: "DATE" }, valor: "20260807" }
function propriedade(bloco: string, nome: string): { params: Record<string, string>; valor: string } | null {
  const m = new RegExp("^" + nome + "((?:;[^:\\n]*)?):(.*)$", "m").exec(bloco);
  if (!m) return null;
  const params: Record<string, string> = {};
  for (const p of m[1].split(";").filter(Boolean)) {
    const [k, v] = p.split("=");
    params[k.toUpperCase()] = (v ?? "").replace(/^"|"$/g, "");
  }
  return { params, valor: m[2] };
}

// Diferença (ms) entre a hora de parede numa zona e o UTC, naquele instante.
function deslocamento(zona: string, instante: number): number {
  try {
    const f = new Intl.DateTimeFormat("en-US", {
      timeZone: zona, hour12: false, year: "numeric", month: "2-digit", day: "2-digit",
      hour: "2-digit", minute: "2-digit", second: "2-digit",
    });
    const p = Object.fromEntries(f.formatToParts(new Date(instante)).map((x) => [x.type, x.value]));
    const parede = Date.UTC(+p.year, +p.month - 1, +p.day, +p.hour % 24, +p.minute, +p.second);
    return parede - instante;
  } catch {
    return 0;
  }
}

// Valor de data do .ics → ISO em UTC. Dia inteiro vira meia-noite UTC daquele dia.
export function lerData(valor: string, params: Record<string, string>): { iso: string; diaInteiro: boolean } | null {
  const v = valor.trim();
  const soDia = /^(\d{4})(\d{2})(\d{2})$/.exec(v);
  if (soDia || params.VALUE === "DATE") {
    const m = soDia ?? /^(\d{4})(\d{2})(\d{2})/.exec(v);
    if (!m) return null;
    return { iso: `${m[1]}-${m[2]}-${m[3]}T00:00:00.000Z`, diaInteiro: true };
  }
  const m = /^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})?(Z?)$/.exec(v);
  if (!m) return null;
  const parede = Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +(m[6] ?? "0"));
  if (Number.isNaN(parede)) return null;
  const utc = m[7] === "Z" || !params.TZID ? parede : parede - deslocamento(params.TZID, parede);
  return { iso: new Date(utc).toISOString(), diaInteiro: false };
}

// "Prova 1 [(6166100) Cálculo II]" → título sem o sufixo + código e nome do curso
export function extrairCurso(summary: string): { titulo: string; curso_codigo: string | null; curso_nome: string | null } {
  const m = /\[\((\d+)\)\s*([^\]]+)\]\s*$/.exec(summary);
  if (!m) return { titulo: summary.trim(), curso_codigo: null, curso_nome: null };
  return { titulo: summary.slice(0, m.index).trim(), curso_codigo: m[1], curso_nome: m[2].trim() };
}

export function lerEventos(texto: string): Evento[] {
  const plano = desdobrar(texto);
  const eventos: Evento[] = [];
  const re = /BEGIN:VEVENT\n([\s\S]*?)\nEND:VEVENT/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(plano))) {
    const bloco = m[1];
    const uid = propriedade(bloco, "UID")?.valor.trim();
    const ini = propriedade(bloco, "DTSTART");
    if (!uid || !ini) continue;
    const inicio = lerData(ini.valor, ini.params);
    if (!inicio) continue;
    const fimProp = propriedade(bloco, "DTEND");
    const fimData = fimProp ? lerData(fimProp.valor, fimProp.params) : null;
    const fim = fimData && !inicio.diaInteiro && fimData.iso > inicio.iso ? fimData.iso : null;
    const curso = extrairCurso(desescapar(propriedade(bloco, "SUMMARY")?.valor ?? ""));
    const url = (propriedade(bloco, "URL")?.valor ?? "").trim();
    eventos.push({
      uid,
      titulo: curso.titulo || "(sem título)",
      descricao: desescapar(propriedade(bloco, "DESCRIPTION")?.valor ?? "").trim(),
      inicio: inicio.iso,
      fim,
      dia_inteiro: inicio.diaInteiro,
      url: /^https:\/\//.test(url) ? url : null,
      curso_codigo: curso.curso_codigo,
      curso_nome: curso.curso_nome,
    });
  }
  return eventos;
}

// ---------- escrita ----------

function escapar(s: string): string {
  return s.replace(/\\/g, "\\\\").replace(/;/g, "\\;").replace(/,/g, "\\,").replace(/\r?\n/g, "\\n");
}

// Dobra em 75 octetos (a continuação começa com espaço e conta 1 octeto).
function dobrar(linha: string): string {
  const enc = new TextEncoder();
  if (enc.encode(linha).length <= 75) return linha;
  const partes: string[] = [];
  let atual = "";
  let tam = 0;
  for (const ch of linha) {
    const b = enc.encode(ch).length;
    const limite = partes.length ? 74 : 75;
    if (tam + b > limite) { partes.push(atual); atual = ""; tam = 0; }
    atual += ch;
    tam += b;
  }
  partes.push(atual);
  return partes.join("\r\n ");
}

// Normaliza pelo Date porque o banco devolve "+00:00" e o parser devolve "Z".
const dataIcs = (iso: string) => new Date(iso).toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");   // 20260807T100000Z
const diaIcs = (iso: string) => new Date(iso).toISOString().slice(0, 10).replace(/-/g, "");                  // 20260807
function diaSeguinte(iso: string): string {
  const d = new Date(new Date(iso).toISOString().slice(0, 10) + "T00:00:00Z");
  d.setUTCDate(d.getUTCDate() + 1);
  return diaIcs(d.toISOString());
}

export function escreverCalendario(nome: string, eventos: Evento[], agora: Date = new Date()): string {
  const stamp = dataIcs(agora.toISOString());
  const linhas = [
    "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Hub de Estudos//PT-BR", "CALSCALE:GREGORIAN", "METHOD:PUBLISH",
    "X-WR-CALNAME:" + escapar("Hub de Estudos · " + nome),
  ];
  for (const e of eventos) {
    linhas.push("BEGIN:VEVENT", "UID:" + e.uid + "@hub-estudos", "DTSTAMP:" + stamp);
    if (e.dia_inteiro) {
      linhas.push("DTSTART;VALUE=DATE:" + diaIcs(e.inicio), "DTEND;VALUE=DATE:" + diaSeguinte(e.inicio));
    } else {
      const fim = e.fim ?? new Date(new Date(e.inicio).getTime() + 30 * 60000).toISOString();
      linhas.push("DTSTART:" + dataIcs(e.inicio), "DTEND:" + dataIcs(fim));
    }
    const sufixo = e.curso_nome ? " (" + e.curso_nome + ")" : "";
    linhas.push("SUMMARY:" + escapar(e.titulo + sufixo));
    if (e.descricao) linhas.push("DESCRIPTION:" + escapar(e.descricao));
    if (e.url) linhas.push("URL:" + e.url);
    linhas.push("END:VEVENT");
  }
  linhas.push("END:VCALENDAR");
  return linhas.map(dobrar).join("\r\n") + "\r\n";
}
