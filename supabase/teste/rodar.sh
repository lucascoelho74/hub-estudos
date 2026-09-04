#!/bin/bash
# Roda schema.sql + teste.sql num Postgres local (Homebrew), com stub do Supabase.
# Uso: supabase/teste/rodar.sh          → roda os testes
#      supabase/teste/rodar.sh parar    → desliga o Postgres local
set -euo pipefail
# Sem LC_ALL/LANG definidos, o setlocale("") do macOS cai no CFLocaleCopyCurrent(),
# que deixa o processo multithread e o Postgres recusa subir ("postmaster became
# multithreaded during startup"). Força um valor para evitar esse caminho.
export LC_ALL="${LC_ALL:-C}"
cd "$(dirname "$0")/../.."
PG="$(brew --prefix postgresql@17)/bin"
DADOS="${TMPDIR:-/tmp}/hub-estudos-pg"
PORTA=5499

if [ "${1:-}" = "parar" ]; then "$PG/pg_ctl" -D "$DADOS" stop >/dev/null 2>&1 || true; echo "Postgres parado"; exit 0; fi

if [ ! -d "$DADOS" ]; then "$PG/initdb" -D "$DADOS" -U postgres --auth=trust -E UTF8 --locale=C >/dev/null; fi
"$PG/pg_isready" -h localhost -p $PORTA >/dev/null 2>&1 || \
  "$PG/pg_ctl" -D "$DADOS" -o "-p $PORTA -k $DADOS" -l "$DADOS/log" start >/dev/null
for _ in $(seq 1 30); do "$PG/pg_isready" -h localhost -p $PORTA >/dev/null 2>&1 && break; sleep 0.3; done

PSQL="$PG/psql -h localhost -p $PORTA -U postgres -v ON_ERROR_STOP=1 -q"
$PSQL -d postgres -c "drop database if exists hub_teste" -c "create database hub_teste"
$PSQL -d hub_teste -f supabase/teste/stub.sql
$PSQL -d hub_teste -f supabase/schema.sql
$PSQL -d hub_teste -1 -f supabase/teste/teste.sql
echo "OK: schema.sql e teste.sql passaram"
