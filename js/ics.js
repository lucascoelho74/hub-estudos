// Helpers puros do calendário: formatos de data que Google, Outlook e .ics esperam,
// e um .ics de um evento só para o Apple Calendar. Sem chamadas ao backend.
(function () {
  function pad(n) { return String(n).padStart(2, '0'); }

  // '2026-08-07T10:00:00+00:00' → '20260807T100000Z'
  window.dataCompacta = function (iso) {
    var d = new Date(iso);
    return d.getUTCFullYear() + pad(d.getUTCMonth() + 1) + pad(d.getUTCDate()) + 'T' +
      pad(d.getUTCHours()) + pad(d.getUTCMinutes()) + pad(d.getUTCSeconds()) + 'Z';
  };
  // '2026-08-07T00:00:00+00:00' → '20260807' (eventos de dia inteiro ficam à meia-noite UTC)
  window.diaCompacto = function (iso) { return iso.slice(0, 10).replace(/-/g, ''); };
  window.diaSeguinte = function (iso) {
    var d = new Date(iso.slice(0, 10) + 'T00:00:00Z');
    d.setUTCDate(d.getUTCDate() + 1);
    return d.toISOString();
  };
  // Prazo sem duração vira 30 minutos, que é o que os apps exigem para mostrar algo.
  window.fimEfetivo = function (e) {
    return e.fim || new Date(new Date(e.inicio).getTime() + 30 * 60000).toISOString();
  };
  window.tituloComCurso = function (e) { return e.titulo + (e.curso_nome ? ' (' + e.curso_nome + ')' : ''); };

  window.linkGoogle = function (e) {
    var datas = e.dia_inteiro
      ? diaCompacto(e.inicio) + '/' + diaCompacto(diaSeguinte(e.inicio))
      : dataCompacta(e.inicio) + '/' + dataCompacta(fimEfetivo(e));
    return 'https://calendar.google.com/calendar/render?action=TEMPLATE' +
      '&text=' + encodeURIComponent(tituloComCurso(e)) +
      '&dates=' + datas +
      '&details=' + encodeURIComponent((e.descricao || '') + (e.url ? '\n' + e.url : ''));
  };

  window.linkOutlook = function (e) {
    var ini = e.dia_inteiro ? e.inicio.slice(0, 10) : new Date(e.inicio).toISOString();
    var fim = e.dia_inteiro ? diaSeguinte(e.inicio).slice(0, 10) : new Date(fimEfetivo(e)).toISOString();
    return 'https://outlook.live.com/calendar/0/deeplink/compose?path=/calendar/action/compose&rru=addevent' +
      '&subject=' + encodeURIComponent(tituloComCurso(e)) +
      '&startdt=' + ini + '&enddt=' + fim + (e.dia_inteiro ? '&allday=true' : '') +
      '&body=' + encodeURIComponent((e.descricao || '') + (e.url ? '\n' + e.url : ''));
  };

  function escaparIcs(s) {
    return String(s).replace(/\\/g, '\\\\').replace(/;/g, '\\;').replace(/,/g, '\\,').replace(/\r?\n/g, '\\n');
  }

  window.eventoParaIcs = function (e) {
    var l = ['BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//Hub de Estudos//PT-BR', 'BEGIN:VEVENT',
      'UID:' + e.uid + '@hub-estudos', 'DTSTAMP:' + dataCompacta(new Date().toISOString())];
    if (e.dia_inteiro) l.push('DTSTART;VALUE=DATE:' + diaCompacto(e.inicio), 'DTEND;VALUE=DATE:' + diaCompacto(diaSeguinte(e.inicio)));
    else l.push('DTSTART:' + dataCompacta(e.inicio), 'DTEND:' + dataCompacta(fimEfetivo(e)));
    l.push('SUMMARY:' + escaparIcs(tituloComCurso(e)));
    if (e.descricao) l.push('DESCRIPTION:' + escaparIcs(e.descricao));
    if (e.url) l.push('URL:' + e.url);
    l.push('END:VEVENT', 'END:VCALENDAR');
    return l.join('\r\n') + '\r\n';
  };

  // Baixa um .ics de um evento (Apple Calendar abre direto).
  window.baixarIcs = function (e) {
    var blob = new Blob([eventoParaIcs(e)], { type: 'text/calendar' });
    var a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = slug(e.titulo) + '.ics';
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(function () { URL.revokeObjectURL(a.href); }, 1000);
  };

  window.formatarHora = function (e) {
    if (e.dia_inteiro) return 'dia inteiro';
    return new Date(e.inicio).toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' });
  };
  // Chave 'AAAA-MM-DD' no fuso do navegador (para agrupar por dia).
  window.chaveData = function (d) { return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()); };
  window.chaveDia = function (e) { return e.dia_inteiro ? e.inicio.slice(0, 10) : chaveData(new Date(e.inicio)); };
})();
