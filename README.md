# The Cracks App

A micro-task delivery engine for high-interruption workdays — Virtual Assistants, Medical Billers, Content Creators, and solo executives. Instead of a task list, it hands you exactly one task that fits the pocket of time and energy you actually have right now.

## Phase 1 scope (built)

**A — Crack Picker.** Three big tap targets: *5 mins*, *15 mins*, *45+ mins*. Tapping one filters the open-task queue to that bucket and surfaces a single highest-priority card — not a list.

**B — Brain-dump parser.** One text field at the top of the screen. Drop a raw, messy thought in; a local heuristic parser extracts a clean title, guesses a duration bucket (5/15/45), flags an energy type (low / admin / focus / social), and tags call vs. email vs. general.

**C — Bulk list importer.** A paste-in textarea that splits a pasted paragraph or list line-by-line (or sentence-by-sentence as a fallback), runs every line through the same parser, and creates tagged tasks instantly.

**D — Call script drawer.** Tapping a `call`-type task auto-opens a side drawer with a 3-minute boundary-setting default script matched to the active role profile (Virtual Assistant / Medical Biller / Content Creator / Executive). The drawer's AI Prompt Engine takes a ~5-word call goal and outputs a 120-second script (opener → purpose → ask → fallback → confirm → next step → close) with a live word/timing estimate and one-tap copy to clipboard. Every field — task titles, generated scripts, default templates — is directly editable in place.

Frontend is plain HTML5/CSS3/vanilla JS (no framework), mobile-first with large thumb-friendly tap targets, and runs entirely on `localStorage` in Phase 1 so it's demoable with zero backend setup. `supabase/schema.sql` defines the matching tables (`profiles`, `tasks`, `call_scripts`, `script_templates`, all RLS-scoped to `auth.uid()`) — swapping `loadState`/`saveState` in `index.html` for Supabase calls is the only change needed to go live.

## Design system

Muted organic sage green as the primary palette, warm cream/beige/terracotta as accents — deliberately calm rather than alarming, since the whole point is reducing task anxiety. High-contrast headings, legible body type that scales down cleanly on small phone screens, single-column mobile-first layout that still works up to tablet width.

## Explicitly deferred (documented, not built)

1. **Live email integration**
2. **Live calendar syncing**
3. **Multi-user marketplace matching**

Do not build these into the active base files yet.

## Getting started

1. Create a Supabase project and run `supabase/schema.sql` in the SQL editor.
2. Open `index.html` directly in a browser (or serve it statically) — works standalone with no backend for Phase 1.
3. When ready to go live, wire `index.html`'s `loadState`/`saveState` to Supabase auth + the tables above instead of `localStorage`.
