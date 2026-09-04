-- ============================================================
-- Hub de Estudos · backend completo (Supabase)
-- Cole este arquivo inteiro no SQL Editor do projeto e execute.
-- Pode ser executado de novo: tudo é "if not exists" / "or replace".
-- Ordem: extensões → tipos → tabelas → auxiliares → gatilhos →
--        RLS → Storage → funções RPC (a API do site) → seed
-- ============================================================
create schema if not exists extensions;
create extension if not exists unaccent with schema extensions;
