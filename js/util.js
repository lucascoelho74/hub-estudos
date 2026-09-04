// Funções pequenas usadas por todas as páginas.

// Escapa texto para colocar dentro de innerHTML (inclusive dentro de atributos) sem risco de injeção.
window.esc = function (s) {
  return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
    return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
  });
};

// parametro('id') → valor de ?id=... na URL, ou null.
window.parametro = function (nome) {
  return new URLSearchParams(location.search).get(nome);
};

window.formatarData = function (iso) {
  var d = new Date(iso);
  return isNaN(d) ? '' : d.toLocaleDateString('pt-BR', { day: '2-digit', month: 'short', year: 'numeric' });
};

// slug('Cálculo 2 · Guia') → 'calculo-2-guia' (para nome de arquivo no Storage).
window.slug = function (s) {
  return String(s).normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase()
    .replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 60) || 'estudo';
};

// mostrarAviso(el, 'mensagem', 'ok' | 'erro'); mensagem vazia esconde.
window.mostrarAviso = function (el, msg, tipo) {
  el.textContent = msg || '';
  el.className = 'aviso ' + (tipo === 'ok' ? 'aviso-ok' : 'aviso-erro');
  el.hidden = !msg;
};
