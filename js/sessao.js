// Sessão: quem está logado, seu perfil (com cargo), cabeçalho e guardas de página.
(function () {
  var XICARA = '<svg class="cabecalho-xicara" viewBox="0 0 48 44" aria-hidden="true">' +
    '<path d="M8 15 h26 v13 a11 11 0 0 1 -11 11 h-4 a11 11 0 0 1 -11 -11 z" fill="none" stroke="var(--bean)" stroke-width="2.4"/>' +
    '<path d="M34 18 h4 a6 6 0 0 1 0 12 h-3" fill="none" stroke="var(--bean)" stroke-width="2.4"/>' +
    '<path d="M15 4 c-2 3 2 5 0 8 M21 3 c-2 3 2 5 0 8 M27 4 c-2 3 2 5 0 8" fill="none" stroke="var(--steam)" stroke-width="2" stroke-linecap="round" opacity=".8"/></svg>';
  var promessa = null;

  // sessao() → {usuario, perfil}. Ambos null se anônimo. Uma consulta por página.
  window.sessao = function () {
    if (!promessa) promessa = carregar();
    return promessa;
  };
  async function carregar() {
    if (!window.db) return { usuario: null, perfil: null };
    var r = await db.auth.getSession();
    var usuario = r.data && r.data.session ? r.data.session.user : null;
    var perfil = null;
    if (usuario) { try { perfil = await chamar('meu_perfil'); } catch (e) { perfil = null; } }
    return { usuario: usuario, perfil: perfil };
  }
  window.limparSessao = function () { promessa = null; };
  window.ehEquipe = function (perfil) { return !!perfil && (perfil.cargo === 'monitor' || perfil.cargo === 'professor'); };

  window.montarCabecalho = async function () {
    var el = document.getElementById('cabecalho');
    if (!el) return;
    var s = await sessao();
    var links = '<a href="index.html">Início</a>';
    if (ehEquipe(s.perfil)) links += '<a href="publicar.html">Publicar</a>';
    if (s.usuario) links += '<a href="perfil.html" class="cabecalho-usuario">' + esc(s.perfil ? s.perfil.nome : s.usuario.email) + '</a>';
    else links += '<a href="entrar.html" class="botao botao-pequeno">Entrar</a>';
    el.innerHTML = '<a class="cabecalho-marca" href="index.html">' + XICARA + '<span>Hub de Estudos</span></a>' +
      '<nav class="cabecalho-links">' + links + '</nav>';
  };

  // Nome da página atual + query, para voltar depois do login.
  function paginaAtual() { return location.pathname.split('/').pop() + location.search; }

  window.exigirLogin = async function () {
    var s = await sessao();
    if (!s.usuario) { location.href = 'entrar.html?voltar=' + encodeURIComponent(paginaAtual()); return null; }
    return s;
  };
  window.exigirEquipe = async function () {
    var s = await exigirLogin();
    if (s && !ehEquipe(s.perfil)) { location.href = 'index.html?aviso=so-equipe'; return null; }
    return s;
  };
  window.sair = async function () {
    if (window.db) await db.auth.signOut();
    limparSessao();
    location.href = 'index.html';
  };
})();
