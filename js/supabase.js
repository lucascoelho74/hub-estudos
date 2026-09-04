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

  if (!window.db) {
    document.addEventListener('DOMContentLoaded', function () {
      var faixa = document.createElement('div');
      faixa.className = 'aviso aviso-erro aviso-topo';
      faixa.textContent = 'Backend não configurado: preencha js/config.js com a URL e a chave anon do projeto Supabase.';
      document.body.prepend(faixa);
    });
  }
})();
