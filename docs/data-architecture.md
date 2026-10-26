# Data Architecture: knowledge store (DE-01, DRAFT)

Status: draft for review by Backend and AI. No migrations exist yet.
The SQL is in [db/schema-draft.sql](../db/schema-draft.sql). It was run against the local
pgvector container (PostgreSQL 18, pgvector 0.8.7) inside rolled-back transactions, so it
parses and its constraints and queries behave as described below. The A to B to A tests are in
[tests/test_document_versions.py](../tests/test_document_versions.py).

Inputs from AI (Ziad Abdullah):

- [ai-de-embeddings-handoff.pdf](ai-de-embeddings-handoff.pdf), 26 October 2026: the embeddings contract.
- [ai/SkillForge_AI_to_DE_Knowledge_Store_v2.pdf](ai/SkillForge_AI_to_DE_Knowledge_Store_v2.pdf), 26 October 2026:
  answers to our questions and the review of PR #6. It replaces the first handoff where they differ. This version
  applies it: stored `chunk_id`, non-empty `title`, `domains` on `embeddings` with a simple view, the pinned
  `embedding_version`.

That PDF says three more files were sent with it: `knowledge-chunks.sql`, `retrieval.md` and `extraction.md`
(with a "For DE-05" section). **They are not in the repository yet, so this draft has not been checked against
them.** See "Waiting for AI".

All tables live in the Postgres schema `knowledge`, separate from Backend's application tables.

## Tables and relations

```
crawl_runs 1 ──< documents >── 1 sources 1 ──< source_domains
                    │
                    ├── duplicate_of ──> documents (exact or near duplicate)
                    │
                    1 ──< chunks 1 ──< embeddings          active_config (one row)
```

| Table | One row is | Key columns |
|---|---|---|
| `sources` | A URL or repo file we may use | `url` (unique), `host`, `source_type`, `license`, `robots_allowed` |
| `source_domains` | A source collected for a skill domain, e.g. `technology/ai` | `(source_id, skill_domain)` |
| `crawl_runs` | One crawler or pipeline run | `status`, `user_agent`, `config`, `pipeline_version`, `pages_*` counters |
| `documents` | One distinct content fetched from a source | `source_id`, `crawl_run_id`, `fetched_at`, `content_hash`, `license`, `title` (never empty), `pipeline_version`, `language`, `minhash`, `duplicate_of`, `is_current` |
| `chunks` | A passage cut from a document | `chunk_id` (AI's id), `document_id`, `chunk_index`, `text`, `section text[]`, `concepts text[]`, `content_hash`, `chunk_config`, `chunk_config_hash` |
| `embeddings` | The vector for one chunk | `chunk_id` (our uuid key of the chunk), `embedding vector(384)`, `embedding_model`, `embedding_version`, `domains text[]` |
| `active_config` | The single row that says which chunk config and embedding version are live | `chunk_config_hash`, `embedding_version` |

Note on names: `chunks.id` is our internal uuid key; `chunks.chunk_id` is the id AI's `extract_page()` returns.
`embeddings.chunk_id` is a foreign key to `chunks.id` (the uuid). In the views, `chunk_id` always means AI's id and
`chunk_uuid` the internal key.

Three views, all showing only the active config (see below):

- `chunk_provenance`: chunk → `url`, `host`, `retrieved_at`, `license`, chunk and document hashes. It is **not**
  filtered by `active_config` or `is_current`, so any chunk, old or new, can be traced.
- `retrievable_chunks`: `text` plus the provenance columns and `skill_domains`, only for chunks of the active
  config whose document `is_current` and has `duplicate_of IS NULL`. Superseded and duplicate content can never be
  returned by mistake. Join `embeddings` on `chunk_uuid`.
- `knowledge_chunks`: the view AI reads, with AI's columns. See below.

`host` is the web host (rate limits and robots.txt work per host). `skill_domain` is the skill's field
(same vocabulary as SkillSpec `skill.domain`). They are different things and live in different tables.

## Who writes, who reads, who owns migrations

- **Writer: the DE pipeline (DE-05), and only it.** It calls AI's functions (`extract_page` and `embed`, or
  `ingest_pages`) and inserts the results into our tables (`sources`, `documents`, `chunks`, `embeddings`).
- **Reader: AI, through the view `knowledge_chunks` only.** AI connects as the role `skillforge_ai_reader`. Their
  store reads the view name from `SKILLFORGE_PGVECTOR_TABLE` (e.g. `knowledge.knowledge_chunks`) and sets every
  transaction READ ONLY.
- **Migrations are DE's responsibility.** DE writes them (Alembic) and keeps them in step with the schema contract
  shared with Backend: a schema change still needs a pull request approved by the departments that consume it.
  They reach staging through the normal release path (merge, then automatic deploy with migrations).

### Read-only role `skillforge_ai_reader`

Defined in [db/roles-local.sql](../db/roles-local.sql) for local development. It will be created on staging too,
by a migration or ops script, with the password taken from the secret store and not from the repository.
Production follows the release process. AI confirmed this role is what they want.

| Grant | Why |
|---|---|
| `CONNECT` on the database, `USAGE` on schema `knowledge` | needed to reach the view |
| `SELECT` on `knowledge.knowledge_chunks`, nothing else | the view runs with its owner's rights, so the role needs no access to the tables behind it |
| `search_path = knowledge, public` | `knowledge_chunks` resolves without a prefix. `public` is kept because the `vector` type and the `<=>` operator live there; with `knowledge` alone the operator fails (checked: `operator does not exist`) |

Checked in the container inside a rolled-back transaction, acting as the role, against the current view: it reads
`knowledge_chunks` (5 of 5 rows) and, in a READ ONLY transaction like AI's store uses, runs `SET LOCAL
hnsw.iterative_scan` and a `<=>` similarity query with a `domains` filter. It is denied `SELECT` on `chunks`,
`embeddings`, `active_config`, `retrievable_chunks` and `chunk_provenance`; denied `UPDATE` and `DELETE` on the base
tables and `CREATE TABLE` in `knowledge`; and denied `EXECUTE` on `record_document_version()` (revoked from
`PUBLIC`; by default every role can call a function, and the call then failed on table permissions). A write to the
view itself fails with "cannot insert into view" (a join is not writable at all), before any permission check. To
create the role locally run
`docker exec -i skillforge-postgres psql -U skillforge -d skillforge < db/roles-local.sql` after the schema exists.

If AI wants the pipeline to use `ingest_pages()`, note that it writes its own `knowledge_chunks` table. Our
pipeline must call it in a way that returns the data for us to insert (or call `extract_page` and `embed`
separately), because the view cannot be written. To confirm when `retrieval.md` is in the repo.

## Waiting for AI

- `knowledge-chunks.sql`, `retrieval.md`, `extraction.md` (sent by Ziad, not in the repository yet; put them in
  `docs/ai/`). Two things must be checked against them: the "For DE-05" section of `extraction.md` (what
  `extract_page()` returns, and the exact format of `chunk_id`, which our constraints assume is non-empty text), and
  the example `CREATE VIEW` and search query in `knowledge-chunks.sql` (our view columns and the filter shape).
- The final `knowledge_chunks` DDL is in that SQL file. Until we compare, the view matches the handoff DDL with the
  one agreed change (`domains text[]`), checked column by column in the container: 11 columns, 0 differences.

## Embeddings contract with AI (final)

| Item | Value |
|---|---|
| `embedding_model` | exactly `local/BAAI/bge-small-en-v1.5`, enforced by a CHECK. Another value is rejected. |
| `embedding_version` | `aa8f8b060edb00e03bfdd08813a2949946c8ba55`: the pinned revision of `Qdrant/bge-small-en-v1.5-onnx-Q` (file `model_optimized.onnx`, sha256 `51f1bd0addd6e859e42c2c8021a5e5461385bb676a649f4b269aa445449f2431`). Not fixed by a CHECK: a new revision must be able to coexist with the old during a rebuild. The live one is in `active_config`. |
| Dimension | 384, `vector(384)` |
| Unit length | enforced by a CHECK: `abs(vector_norm(embedding) - 1) < 0.001`. A vector that is not L2-normalized is rejected. The margin only absorbs float32 rounding. (pgvector 0.8.7 names this function `vector_norm`; `l2_norm` exists only for halfvec and sparsevec.) |
| Metric and index | cosine, HNSW with `vector_cosine_ops`. Final. Order by `embedding <=> query`; score is `1 - (embedding <=> query)`. |

**Our pipeline does not create embeddings.** It calls AI's code (`extract_page()` and `embed()`, or
`ingest_pages()`) so that every rule matches: passages are embedded as raw text with no prefix, the model file is
pinned and checked by sha256, and vectors are normalized. DE only chooses when to run it, and stores and indexes
the result. Duplicating that logic in our own code would put vectors in a different space and make search results
silently wrong.

**Search queries** (only queries, never passages) must start with this exact instruction. It ends with one space,
so it is written here as a Python string literal, because editors strip trailing spaces from plain lines:

```python
QUERY_PREFIX = "Represent this sentence for searching relevant passages: "
```

Any retrieval code of ours (including `knowledge.search()` below, which receives an already embedded query) adds
this prefix before the query text is embedded. The model and dimension are a contract: changing either, or the
`chunk_id` rule, or the view columns, needs approval from AI and DE and a rebuild of the index.

## `chunk_id`: stable ids for citations

AI's contract promises the same `chunk_id` for the same text on the same page. A new uuid on every crawl would break
citations, and it would still pass AI's format check, so nothing would fail visibly. So:

- `chunks.chunk_id` stores the id returned by `extract_page()`. The view exposes it as `chunk_id`. Our internal
  `chunks.id` is never shown to AI.
- Constraints: not empty; unique per `(document_id, chunk_config_hash, chunk_id)`.
- Because the same text on the same page keeps its id across versions of a document, the same `chunk_id` exists in
  several document rows over time. Only the current document is visible in the views, so it is unique there.
- The pipeline must not generate ids itself.

## `title`: never empty

AI's model rejects an empty title, and one empty title makes a whole search call fail. `documents.title` is
`NOT NULL` with a CHECK that it is not blank, and the view no longer wraps it in `COALESCE`. The title comes from
`extract_page()`. A page without a usable title is a pipeline failure (`status = 'failed'`), not something to hide
with an empty string.

## `knowledge_chunks`: the view AI reads

We keep our own normalized tables and expose AI's table shape as a view, so AI reads from us without writing
anything. Column names and types match AI's DDL, with one agreed change: a chunk can belong to several skill
domains, so `domain text` became `domains text[]` (at least one, no repeats, enforced by a CHECK) and **each chunk
appears once**.

| AI column | Comes from |
|---|---|
| `chunk_id text` | `chunks.chunk_id` (AI's id, not our uuid) |
| `source_url text` | `sources.url` |
| `title text` | `documents.title` (never empty) |
| `retrieved date` | `documents.fetched_at` as a UTC date |
| `text`, `section`, `concepts` | `chunks` |
| `content_hash char(64)` | `chunks.content_hash`: sha256 hex of the chunk text (confirmed by AI) |
| `domains text[]` | `embeddings.domains` |
| `embedding_model`, `embedding` | `embeddings` |

The view is a plain join with no subquery and no `NOT EXISTS`. It shows only current, non-duplicate documents, and
only the chunk config and embedding version in `active_config`. What differs from a real table:

1. **Read-only.** It is a join; an INSERT fails. The DE pipeline writes to our tables.
2. **AI's bootstrap DDL fails on it.** Their `pg_schema()` runs `CREATE TABLE IF NOT EXISTS knowledge_chunks`
   (skipped, the name exists) and then `CREATE INDEX ... ON knowledge_chunks`, which errors because it is a view
   (checked earlier). Their code must not run `pg_schema()` against this database.
3. **One row per chunk** relies on `active_config`: only one embedding version is live at a time, so a chunk with
   two versions during a rebuild still appears once.

### `domains` on `embeddings`, and keeping it right

`embeddings.domains` is filled by the pipeline from `source_domains` when it embeds a chunk, so the vector search and
the domain filter touch one table and the view needs no subquery. A GIN index on `domains` serves
`domains && ARRAY[...]`. It is a copy, so it can go stale:

- When `source_domains` of a source changes, the pipeline updates `embeddings.domains` for that source's chunks in
  the same transaction.
- DE-11 should run a consistency check: any embedding whose `domains` differs from the sorted `source_domains` of its
  source is a failure.

### How AI filters by domain

A row matches query domain `D` if one of its domains equals `D`, or one is a path prefix of the other
(`technology` matches `technology/ai`). Domains are hierarchical, and the valid list lives in the SkillSpec.

- Equal and parent domains: `domains && ARRAY[D and its parents]`. A GIN index can serve this.
- Child domains: `unnest(domains) LIKE 'D/%'`. No index serves this form; it is a filter on rows found by the
  vector index.
- Results are ordered by `embedding <=> query`; score is `1 - distance`.

### EXPLAIN: the HNSW index is used through the view

Checked on the local container, in a rolled-back transaction: 30,000 chunks (one source, one document, one chunk and
one embedding each), random normalized vectors, index built after loading, `ANALYZE`d, `SET hnsw.iterative_scan =
relaxed_order`, `LIMIT 10`, querying `knowledge.knowledge_chunks` with AI's filter shapes. Domain shares: 1%
`legal/contracts`, 29% `technology/ai`, 70% `marketing/b2b`.

| Query shape | Plan | Rows | Execution time |
|---|---|---|---|
| selective domain (1%), `domains && ARRAY[D, parent]` | HNSW index scan, then filter; nested loops to `chunks`, `documents`, `sources` | 10 | 28 ms (first run, 262 buffers read from disk; the scan removed 1,500 rows by filter) |
| medium domain (29%) | HNSW index scan, then filter | 10 | 2.8 ms |
| broad domain (70%) | HNSW index scan, then filter | 10 | 2.5 ms |
| child form, `unnest(domains) LIKE 'technology/%'` | HNSW index scan, then filter | 10 | 2.8 ms |

Without `hnsw.iterative_scan`: the broad query still returns 10 rows, but the selective one returns **0**. With it,
all return 10.

What this does not show: the GIN index was not chosen in any of these (the planner preferred the HNSW scan even for
the 1% domain; on a much larger table it may choose GIN for a very selective domain, and that is also fine). 30,000
rows with random vectors say nothing about recall or about latency at 1M chunks with real data. That is DE-02's
measurement, and the decision on `knowledge.search()` below depends on it. The previous version of the view (a
subquery for domains and a `NOT EXISTS` filter) was never planned against this data, so we cannot say how it would
have compared; the new shape is the one AI asked for.

## `active_config`: one chunk config, one embedding version

`chunk_config` has fixed keys: `size`, `overlap`, `splitter` (AI-owned values) and `pipeline_version` (ours), enforced
by a CHECK. Because `pipeline_version` is inside `chunk_config`, it is inside `chunk_config_hash`: a new pipeline
version, or any new chunk setting, is a new config and a new chunk set. Rows of the old and new config can exist
side by side while a rebuild runs, so the same text would appear twice.

`active_config` is a table that can hold only one row (`id boolean PRIMARY KEY CHECK (id)`), with
`chunk_config_hash` and `embedding_version`. `retrievable_chunks` and `knowledge_chunks` join it, so only the live
set is visible and no text repeats. To switch, the pipeline loads the new set, then updates this row in one
transaction. `chunk_provenance` does not filter on it.

- `embedding_version` is in this table too (not only the chunk config), so that two embedding versions during a
  rebuild do not produce duplicate rows. This goes slightly beyond the request; it replaces the `NOT EXISTS` filter
  AI asked us to remove.
- The row is created by the first pipeline run, because the hash depends on AI's chunk settings. **Until it exists the
  views return no rows.**
- `chunk_config_hash` is computed by the pipeline: sha256 of `chunk_config` as canonical JSON (sorted keys, no
  whitespace). It is a plain column, not generated, so the rule is explicit in code and tests.

## A to B to A: the pipeline must restore the old document

A page can go back to old content: it serves content A, then B, then A again. The document row for A already
exists, and `UNIQUE (source_id, content_hash)` makes a plain insert fail. An "insert or ignore" would leave B marked
current and A hidden, although the page now serves A: the retrieval view would show text the page no longer has.

**The DE-05 pipeline must handle this case.** For every fetched page it calls `knowledge.record_document_version()`
(in `db/schema-draft.sql`), which keeps "one current version per source" true in three cases, under a per-source
advisory lock so two workers cannot interleave:

| Case | What happens |
|---|---|
| Same content as the current version | refresh `fetched_at`, `license`, `http_status` and the raw object key |
| New content | demote the current row, insert a new current row |
| **Old content returns (A, B, then A)** | demote the current row (B), set the old row (A) `is_current = true` and update its `fetched_at` |

If A's clean text was already deleted when B replaced it, A goes back to `status = 'fetched'` with its clean text keys
cleared, so it is cleaned again. Its chunks and embeddings still exist (within the 90 days a superseded document is
kept), so they are not created twice. If they are already gone, the normal pipeline recreates them.

Tests (`tests/test_document_versions.py`, run with `.venv\Scripts\python -m pytest`; they skip if the database is
down, and roll back everything they load): unchanged re-fetch refreshes `fetched_at`; new content replaces the
current row; A, B, A reuses the old row, makes it current with the new `fetched_at`, leaves two rows and one current;
after A, B, A only A's chunks are in `retrievable_chunks`; a restored document with deleted clean text is
reprocessed. Checked that the tests can fail: with the "old content returns" branch disabled, 3 of the 5 fail.

## Note for DE-07 (dedup): duplicates must not make content disappear

`duplicate_of` marks a document as a copy, and retrieval hides copies. Suppose document C is marked
`duplicate_of = B`. Later B is superseded (`is_current = false`, for example B's page changed). Now B is hidden
because it is not current, and C is hidden because it is a duplicate: **the content is in no retrievable row, though
a live page (C) still carries it.**

DE-07 must therefore, whenever a document that other documents point to stops being current (or is deleted by
retention):

1. find the documents with `duplicate_of` pointing to it;
2. for each group, pick a current one as the new canonical document (set its `duplicate_of` to NULL) and re-point
   the rest to it. If none of them is current, nothing is lost: the content is gone from every live page;
3. run this in the same transaction that supersedes B.

Test to write with DE-07: B, C (duplicate of B); supersede B; assert C's chunks are in `retrievable_chunks`. The same
rule applies when B is restored in an A, B, A cycle. Note that `ON DELETE SET NULL` on `duplicate_of` already makes
retention deletes safe for C; the dangerous case is supersession, which does not delete anything.

## Fallback: `knowledge.search()` if the view misses 100 ms (DE-02)

If DE-02 measures the 1M-chunk set and the view cannot reach the 100 ms target, we do not change AI's view contract.
We add a function that queries the tables directly and set the planner's hands: the filter first, one function
setting for the iterative scan, no join through a view. AI would call it instead of reading the view, so this is a
contract change that both sides approve. It is documented here, not installed. The sketch below was run in the
container in a rolled-back transaction on a small data set: for `technology/ai` it returned the equal, child and
parent domains and not a sibling; for `technology` all of its children; it did not match `techno` (a path prefix,
not a string prefix); the best hit scored 1.000 for the query vector itself.

```sql
CREATE FUNCTION knowledge.search(p_query vector(384), p_domain text, p_k integer DEFAULT 10)
RETURNS TABLE (chunk_id text, source_url text, title text, retrieved date, text text,
               section text[], concepts text[], content_hash char(64), domains text[], score real)
LANGUAGE sql STABLE
SET hnsw.iterative_scan = relaxed_order
AS $$
    SELECT c.chunk_id, s.url, d.title, (d.fetched_at AT TIME ZONE 'UTC')::date, c.text,
           c.section, c.concepts, c.content_hash::char(64), e.domains,
           (1 - (e.embedding <=> p_query))::real
    FROM knowledge.embeddings e
    JOIN knowledge.active_config ac ON ac.embedding_version = e.embedding_version
    JOIN knowledge.chunks    c ON c.id = e.chunk_id AND c.chunk_config_hash = ac.chunk_config_hash
    JOIN knowledge.documents d ON d.id = c.document_id AND d.is_current AND d.duplicate_of IS NULL
    JOIN knowledge.sources   s ON s.id = d.source_id
    WHERE e.domains && ARRAY(                     -- the query domain and each of its parents
              SELECT array_to_string((string_to_array(p_domain, '/'))[1:i], '/')
              FROM generate_series(1, cardinality(string_to_array(p_domain, '/'))) AS i)
       OR EXISTS (SELECT 1 FROM unnest(e.domains) AS x      -- or a child of the query domain
                  WHERE left(x, length(p_domain) + 1) = p_domain || '/')
    ORDER BY e.embedding <=> p_query
    LIMIT p_k
$$;
```

Limits of the sketch: the `OR` with the child test means the GIN index cannot serve the whole filter, so a rare
domain would be found through the HNSW scan, as with the view; if that is too slow, split it into two queries
(equal and parents with GIN, children separately) and merge by score. The reader role would need `EXECUTE` on it.
The query vector must already be embedded with the query prefix.

## How the table design serves the later tasks

| Task | What the schema gives it |
|---|---|
| DE-05 idempotency | The pipeline is the only writer. It calls AI's code and does not embed on its own. `documents` is unique on `(source_id, content_hash)`; `chunks` on `(document_id, chunk_index, chunk_config_hash)` and `(document_id, chunk_config_hash, chunk_id)`; `embeddings` on `(chunk_id, embedding_model, embedding_version)`. Re-runs use `ON CONFLICT DO NOTHING`; page versions go through `record_document_version()`. |
| DE-06 provenance | Chunk → document → source gives `url`, `fetched_at` (as `retrieved_at`), `license`, `content_hash`. The license is the copy stored on the document at its latest fetch. `chunk_provenance` traces any chunk by AI's `chunk_id`. |
| DE-07 dedup and language | `documents.language`, `documents.minhash` (datasketch signature), `documents.duplicate_of`. Exact duplicates are found by `content_hash`; near duplicates by MinHash. `crawl_runs.pages_duplicate` gives the duplicate rate per crawl. See the DE-07 note above. |
| DE-09 domain cache | See below. |
| DE-04 crawler | `sources.robots_allowed`, `robots_checked_at`, and `crawl_runs.user_agent`, `config`, `pages_blocked`. |
| DE-03 storage | `raw_object_key` and `clean_object_key` point to object storage; raw expires after 30 days (`raw_deleted_at`) and clean text is removed when a newer version of the page replaces it (`clean_deleted_at`), without losing the document row. |
| DE-11 monitoring | `crawl_runs.status` and counters make "failed or empty run" a simple query; the `domains` consistency check above; `active_config` missing is an alert. |

### DE-09 cache lookup

A skill domain is covered when it has enough fresh, current documents. The freshness window is a
config value, not a column:

```sql
SELECT count(*) AS fresh_documents
FROM knowledge.source_domains sd
JOIN knowledge.documents d ON d.source_id = sd.source_id
WHERE sd.skill_domain = 'technology/ai'
  AND d.is_current
  AND d.duplicate_of IS NULL
  AND d.fetched_at > now() - interval '30 days';   -- window comes from config
```

A second request in the same domain reuses these documents instead of crawling again.
A source can be tagged with several skill domains, so cached pages are shared between skills.

## Decisions for review

1. **`content_hash` is not globally unique.** It is unique per source for documents, and inside the chunk key
   for chunks. A global unique key would drop the second source when two sites carry the same text, and then
   provenance would be wrong. Duplicates are kept as rows and marked with `duplicate_of`.
2. **One time column, `documents.fetched_at`.** The views rename it `retrieved_at`.
3. **Duplicates and old versions stay in the tables but never leave through the views** (see the DE-07 note for the
   case where that hides content).
4. **`pipeline_version` is inside `chunk_config`** (and so inside the config hash). `chunks` has no separate
   `pipeline_version` column. A new version is a new chunk set, switched on through `active_config`. `documents`
   keeps its own `pipeline_version` (the fetch and clean stage).
5. **`chunk_config_hash`** is computed by the pipeline from canonical JSON; see `active_config`.
6. **`crawl_run_id` points to the run that first stored the document.** An unchanged page found by a later run
   inserts nothing new; it is counted in that run's `pages_unchanged`. A restored document (A, B, A) keeps its
   original run id.
7. **`embedding_model` is fixed by a CHECK**, so a model change needs a migration. That matches the contract. The
   embedding version is not fixed by a CHECK; `active_config` says which one is live.
8. **`section` and `concepts` live on `chunks`** (`text[] NOT NULL DEFAULT '{}'`), as in AI's table.
9. **`record_document_version()` is SQL, not Python,** so the "one current version" invariant holds for any writer
   and is tested against the real constraints.

## HNSW index and filtered queries

`embeddings_hnsw_cosine_idx` uses `hnsw (embedding vector_cosine_ops)` with `m=16`, `ef_construction=64`
(pgvector defaults). The metric is final. DE-02 will tune the parameters on the 1M-chunk test set. A GIN index on
`domains` sits next to it.

A query that filters (by domain, or by what the views remove: old versions, duplicates, inactive config) must use
`hnsw.iterative_scan`. Without it, HNSW returns its first `hnsw.ef_search` candidates (40 by default) and then
applies the filter, so a selective filter can leave few rows or none. Measured results are in the EXPLAIN section
above (selective domain: 0 rows without it, 10 with it).

Use it per transaction so it does not leak into other work:

```sql
BEGIN;
SET LOCAL hnsw.iterative_scan = relaxed_order;
SELECT chunk_id, 1 - (embedding <=> $1) AS score
FROM knowledge.knowledge_chunks
WHERE domains && $2
ORDER BY embedding <=> $1
LIMIT 10;
COMMIT;
```

`relaxed_order` may return results slightly out of distance order; sort by distance in an outer query if exact
order matters, or use `strict_order`. `hnsw.max_scan_tuples` (default 20,000) caps how far the scan continues. AI's
store sets every transaction READ ONLY; `SET LOCAL` is allowed there.

## Retention (raw 30 days and the clean-text rule are agreed with AI; the rest is PROPOSED and needs BE and DevOps)

| Data | Where | Keep | Then |
|---|---|---|---|
| Raw HTML | object storage | 30 days after `fetched_at` | Delete object, set `raw_deleted_at`; keep the document row |
| Clean text | object storage | Until the page is crawled again and a newer version is stored (not a fixed number of days). AI asked for it to outlive the raw HTML so they can re-chunk or re-embed without a re-crawl; this satisfies it | Delete the old version's object, set `clean_deleted_at` |
| Superseded documents (`is_current = false`) | `documents` | 90 days (AI agreed) | Delete row; chunks and embeddings cascade |
| Chunks and embeddings of a current document, active config | `chunks`, `embeddings` | While the document exists | Cascade with the document |
| Chunks of an inactive chunk config, embeddings of an inactive version | `chunks`, `embeddings` | 30 days after `active_config` switched away from them | Delete |
| Sources never fetched, or not fetched for 12 months | `sources` | 12 months | Delete (cascades to `source_domains`, `documents`) |
| `crawl_runs` | `crawl_runs` | 12 months (AI agreed) | Delete; `documents.crawl_run_id` becomes NULL |
| Crawl and pipeline logs | logs | 90 days | Delete |
| Sources with license `unknown` | `sources`, `documents` | Allowed as background knowledge only | Never copied as examples (DE-08) |

Personal data: these tables hold public web content only. User requests and accounts belong to
Backend; user deletion and request-text retention are handled in DE-13 and should not add user
columns here.

## Open questions

Answered and removed: cosine as the metric; one embedding model; a chunk has several domains; who writes (the DE
pipeline); which AI functions to call; role and `search_path` for AI; migrations are DE's; what `content_hash`
covers (the chunk text); domains are hierarchical, matched by path prefix, and the list lives in the SkillSpec;
`chunk_config` keys are fixed (size, overlap, splitter); `pipeline_version` goes inside `chunk_config`.

**For AI (Ziad)**
1. Is V1 English only, or will you move to a multilingual embedding model? A multilingual model most likely has a
   different dimension and a different model name, which is a contract change: the `vector(384)` column, the model
   CHECK and the HNSW index would be rebuilt, and `documents.language` (DE-07) would decide what is embedded.
   Please tell us before DE-02 sizes the index.

**For BE**
1. Is a separate `knowledge` schema acceptable next to your application tables?
2. Does Backend need to read these tables directly, or only through the retrieval API?
3. Do the retention numbers fit storage cost and any legal limits? Who confirms the agreed deletion time for DE-13?

**For both**
1. `source_type` is `web_page`, `skill_md`, `repo_file`. Is another type needed for the repository analysis in the spec?
2. Storing chunk text (not only summaries) in the store: does it conflict with the "no long copyrighted passages" rule? The rule is about what goes into skills, but the store holds source text internally.
