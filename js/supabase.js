// Cria o cliente do Supabase (window.db) e chamar(): a única forma de o site
// falar com o backend. Carregar depois do CDN, de config.js e de util.js.
(function () {
  var cfg = window.CONFIG || {};
  var configurado = /^https?:\/\//.test(cfg.SUPABASE_URL || '') && (cfg.SUPABASE_ANON_KEY || '').indexOf('COLE_') !== 0;
  window.db = configurado ? supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_ANON_KEY) : null;

  var TRADUCOES = {
    'Invalid login credentials': 'E-mail ou senha incorretos',
    'Database error saving new user': 'E-mail fora dos domínios permitidos (use o e-mail da PUC)',
    'User already registered': 'Este e-mail já tem cadastro',
    'Password should be at least 6 characters': 'A senha precisa ter pelo menos 6 caracteres',
    'Email not confirmed': 'Confirme o e-mail antes de entrar',
    'The resource already exists': 'Já existe um arquivo com esse nome no Storage',
    'mime type': 'O arquivo precisa ser HTML',
    'exceeded the maximum allowed size': 'Arquivo maior que 5 MB',
    'Failed to fetch': 'Sem conexão com o servidor'
  };

  window.traduzirErro = function (erro) {
    var msg = (erro && erro.message) || String(erro);
    for (var chave in TRADUCOES) if (msg.indexOf(chave) >= 0) return TRADUCOES[chave];
    return msg;
  };

  // chamar('buscar_estudos', {texto: 'java'}) → dados; erro vira Error em português.
  window.chamar = async function (nome, params) {
    if (!window.db) throw new Error('Backend não configurado: preencha js/config.js');
    var r = await db.rpc(nome, params || {});
    if (r.error) throw new Error(traduzirErro(r.error));
    return r.data;
  };

  // urlFuncao('feed') → endereço da rota na Edge Function "calendario".
  window.urlFuncao = function (rota) {
    return (cfg.SUPABASE_URL || '') + '/functions/v1/calendario/' + rota;
  };

  // chamarFuncao('importar') → JSON da Edge Function, autenticado com o JWT da sessão.
  // opcoes: { method: 'POST' | 'GET', body: objeto }. Erro vira Error em português.
  window.chamarFuncao = async function (rota, opcoes) {
    if (!window.db) throw new Error('Backend não configurado: preencha js/config.js');
    var s = await db.auth.getSession();
    var token = s.data && s.data.session ? s.data.session.access_token : null;
    if (!token) throw new Error('Faça login para continuar');
    var r;
    try {
      r = await fetch(urlFuncao(rota), {
        method: (opcoes && opcoes.method) || 'POST',
        headers: { Authorization: 'Bearer ' + token, apikey: cfg.SUPABASE_ANON_KEY, 'Content-Type': 'application/json' },
        body: opcoes && opcoes.body ? JSON.stringify(opcoes.body) : undefined
      });
    } catch (e) {
      throw new Error('Sem conexão com a função do calendário. Ela já foi publicada no Supabase?');
    }
    var corpo = null;
    try { corpo = await r.json(); } catch (e) { corpo = null; }
    if (!r.ok) throw new Error((corpo && corpo.erro) || ('A função do calendário respondeu ' + r.status));
    return corpo;
  };

  if (!window.db) {
    document.addEventListener('DOMContentLoaded', function () {
      var faixa = document.createElement('div');
      faixa.className = 'aviso aviso-erro aviso-topo';
      faixa.textContent = 'Backend não configurado: preencha js/config.js com a URL e a chave anon do projeto Supabase.';
      document.body.prepend(faixa);
    });
  }
})();
