#!/bin/sh
# Concatenates the migrations into schema.sql (one file to paste into the Supabase SQL editor).
cd "$(dirname "$0")"
{ echo "-- ANCAP LIFE · full database schema (generated from supabase/migrations by build-schema.sh; edit the migrations, not this file)"
  echo "-- Paste into Supabase > SQL Editor > New query and press Run. Safe to run more than once."
  for f in migrations/*.sql; do echo; echo "-- ===================================================================== $f"; cat "$f"; done; } > schema.sql
