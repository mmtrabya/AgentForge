# Data Architecture: knowledge store (DE-01, DRAFT)

Status: draft for review by Backend and AI. No migrations exist yet.
The SQL is in [db/schema-draft.sql](../db/schema-draft.sql). It was run against the local
pgvector container (PostgreSQL 18, pgvector 0.8.7) inside a rolled-back transaction, so it
parses and its constraints behave as described below.

This version includes the AI-to-DE embeddings handoff from Ziad Abdullah (AI-11, 26 October 2026,
[ai-de-embeddings-handoff.pdf](ai-de-embeddings-handoff.pdf)). The two AI docs it points to
(`ai/docs/ai/retrieval.md`, `ai/docs/ai/extraction.md`) are not on any GitHub branch yet, so nothing
here relies on them. Ziad has answered our questions; this version applies his answers. Items still
waiting for AI are listed under "Waiting for AI".

All tables live in the Postgres schema `knowledge`, separate from Backend's application tables.

## Tables and relations

```
crawl_runs 1 ──< documents >── 1 sources 1 ──< source_domains
                    │
                    ├── duplicate_of ──> documents (exact or near duplicate)
                    │
                    1 ──< chunks 1 ──< embeddings
```

| Table | One row is | Key columns |
|---|---|---|
| `sources` | A URL or repo file we may use | `url` (unique), `host`, `source_type`, `license`, `robots_allowed` |
| `source_domains` | A source collected for a skill domain, e.g. `technology/ai` | `(source_id, skill_domain)` |
| `crawl_runs` | One crawler or pipeline run | `status`, `user_agent`, `config`, `pipeline_version`, `pages_*` counters |
| `documents` | One distinct content fetched from a source | `source_id`, `crawl_run_id`, `fetched_at`, `content_hash`, `license`, `pipeline_version`, `language`, `minhash`, `duplicate_of`, `is_current` |
| `chunks` | A passage cut from a document | `document_id`, `chunk_index`, `text`, `section text[]`, `concepts text[]`, `content_hash`, `chunk_config`, `chunk_config_hash`, `pipeline_version` |
| `embeddings` | The vector for one chunk | `chunk_id`, `embedding vector(384)`, `embedding_model`, `embedding_version` |

Three views:

- `chunk_provenance`: chunk → `url`, `host`, `retrieved_at`, `license`, chunk and document hashes.
- `retrievable_chunks`: `text` plus the provenance columns and `skill_domains`, only for chunks whose document
  is `is_current` and has `duplicate_of IS NULL`. **The retrieval API (contract with AI) reads this view**, so
  superseded and duplicate content can never be returned by mistake. Join `embeddings` on `chunk_id`.
- `knowledge_chunks`: the table AI's code expects (their DDL, handoff section 3), built on our tables. See below.

`host` is the web host (rate limits and robots.txt work per host). `skill_domain` is the skill's field
(same vocabulary as SkillSpec `skill.domain`). They are different things and live in different tables.

## Who writes, who reads, who owns migrations

- **Writer: the DE pipeline (DE-05), and only it.** It calls AI's functions (`extract_page` and `embed`, or
  `ingest_pages`) and inserts the results into our tables (`sources`, `documents`, `chunks`, `embeddings`).
- **Reader: AI, through the view `knowledge_chunks` only.** AI connects as the role `skillforge_ai_reader`.
- **Migrations are DE's responsibility.** DE writes them (Alembic) and keeps them in step with the schema contract
  shared with Backend: a schema change still needs a pull request approved by the departments that consume it.
  They reach staging through the normal release path (merge, then automatic deploy with migrations).

### Read-only role `skillforge_ai_reader`

Defined in [db/roles-local.sql](../db/roles-local.sql) for local development. It will be created on staging too,
by a migration or ops script, with the password taken from the secret store and not from the repository.
Production follows the release process.

| Grant | Why |
|---|---|
| `CONNECT` on the database, `USAGE` on schema `knowledge` | needed to reach the view |
| `SELECT` on `knowledge.knowledge_chunks`, nothing else | the view runs with its owner's rights, so the role needs no access to the tables behind it |
| `search_path = knowledge, public` | `knowledge_chunks` resolves without a prefix. `public` is kept because the `vector` type and the `<=>` operator live there; with `knowledge` alone the operator fails (checked: `operator does not exist`) |

Checked in the container inside a rolled-back transaction, acting as the role: it reads the view (3 of 3 rows) and
runs a `<=>` similarity query on it; it is denied `SELECT` on `chunks`, `embeddings`, `sources` and
`chunk_provenance`; it is denied `INSERT`, `UPDATE`, `DELETE` on the base tables and `CREATE TABLE` in `knowledge`
and `public`. A write to the view itself fails with "cannot insert into view" (a join is not writable at all),
before any permission check. The role was removed by the rollback; to create it locally run
`docker exec -i skillforge-postgres psql -U skillforge -d skillforge < db/roles-local.sql` after the schema exists.

If AI wants to use `ingest_pages()`, note that it writes its own `knowledge_chunks` table. Our pipeline must call
it in a way that returns the data for us to insert (or call `extract_page` and `embed` separately), because the
view cannot be written. To confirm when `retrieval.md` arrives.

## Waiting for AI

- The full `embedding_version`: the model revision that starts `aa8f8b06...` (the full pin is in AI's
  `models.yaml`). Until then it is stored as whatever the pipeline passes in.
- `ai/docs/ai/retrieval.md` and `ai/docs/ai/extraction.md`. They are not on GitHub yet.
- The final `knowledge_chunks` DDL. When it arrives we compare it with the view and match it. Today the view
  differs from the handoff DDL in one column: `domains text[]` instead of `domain text`, as agreed with AI.

## Embeddings contract with AI (final)

| Item | Value |
|---|---|
| `embedding_model` | exactly `local/BAAI/bge-small-en-v1.5`, enforced by a CHECK. Another value is rejected. |
| `embedding_version` | the pinned model revision of `Qdrant/bge-small-en-v1.5-onnx-Q`. The handoff gives only the start (`aa8f8b06...`); the full value is in AI's `ai/core/llm/models.yaml`, which we cannot see yet. Waiting for AI. |
| Dimension | 384, `vector(384)` |
| Unit length | enforced by a CHECK: `abs(vector_norm(embedding) - 1) < 0.001`. A vector that is not L2-normalized is rejected. The margin only absorbs float32 rounding. (pgvector 0.8.7 names this function `vector_norm`; `l2_norm` exists only for halfvec and sparsevec.) |
| Metric and index | cosine, HNSW with `vector_cosine_ops`. Final, no longer provisional. Order by `embedding <=> query`; score is `1 - (embedding <=> query)`. |

**Our pipeline does not create embeddings.** It uses AI's embedding code (`ingest_pages()`, or the embedding
function behind it) so that every rule matches: passages are embedded as
raw text with no prefix, the model file is pinned and checked by sha256, and vectors are normalized. DE only
chooses when to run it, and stores and indexes the result. Duplicating that logic in our own code would put
vectors in a different space and make search results silently wrong.

**Search queries** (only queries, never passages) must start with this exact instruction. It ends with one space,
so it is written here as a Python string literal, because editors strip trailing spaces from plain lines:

```python
QUERY_PREFIX = "Represent this sentence for searching relevant passages: "
```

Our retrieval code adds this prefix before the query text is embedded. The model and dimension are a contract:
changing either needs approval from AI and DE and a rebuild of the index.

## `knowledge_chunks`: the view AI's code reads

AI's store interface expects a table `knowledge_chunks` with 11 columns. We keep our own normalized tables and
expose that shape as a view, so AI reads from us without writing anything. Column names and types match their
handoff DDL, with one agreed change: a chunk can belong to several skill domains, so `domain text` became
`domains text[]` and **each chunk appears once**. Checked by comparing the view with their DDL in the container:
11 columns, 1 difference (position 9). AI will send the final DDL, and we will match it.

| AI column | Comes from |
|---|---|
| `chunk_id text` | `chunks.id::text` |
| `source_url text` | `sources.url` |
| `title text` | `documents.title`, empty string if NULL |
| `retrieved date` | `documents.fetched_at` as a UTC date |
| `text`, `section`, `concepts` | `chunks` |
| `content_hash char(64)` | `chunks.content_hash` (sha256 hex of the chunk text; what AI's hash covers is an open question) |
| `domains text[]` | all `source_domains.skill_domain` of the chunk's source, sorted; `{}` if none |
| `embedding_model`, `embedding` | `embeddings` |

Like `retrievable_chunks`, it only shows current, non-duplicate documents. What differs from a real table:

1. **Read-only.** It is a join; an INSERT fails (checked). The DE pipeline writes to our tables.
2. **One row per chunk.** If a chunk has several embedding versions at once, only the newest is shown
   (checked: 2 versions each, 3 rows in the view, all `rev2`).
3. **AI's bootstrap DDL fails on it.** Their `pg_schema()` runs `CREATE TABLE IF NOT EXISTS knowledge_chunks`
   (skipped, the name exists) and then `CREATE INDEX ... ON knowledge_chunks`, which errors because it is a view
   (checked). Their code must not run `pg_schema()` against this database.
4. **No ANN speed-up through the view.** A query on the view returns the right rows, but the planner does not use
   the HNSW index: it joins first and sorts, which is an exact scan of the matching chunks. Also, `domains` is
   computed per row, so a filter such as `'technology/ai' = ANY(domains)` cannot use the index on
   `source_domains`. Fine for a small store; for a large one the retrieval path should query the tables directly
   (filter with `EXISTS` on `source_domains`, then order by `embedding <=> query`). DE-02 should measure latency on
   the 1M-chunk set and decide whether a real table or a materialized view is needed.

## How the table design serves the later tasks

| Task | What the schema gives it |
|---|---|
| DE-05 idempotency | The pipeline is the only writer. It calls AI's code (`extract_page`, `embed`, or `ingest_pages`) and does not embed on its own. `documents` is unique on `(source_id, content_hash)`; `chunks` on `(document_id, chunk_index, chunk_config_hash)`; `embeddings` on `(chunk_id, embedding_model, embedding_version)`. Re-runs use `ON CONFLICT DO NOTHING`. |
| DE-06 provenance | Chunk → document → source gives `url`, `fetched_at` (as `retrieved_at`), `license`, `content_hash`. The license is the copy stored on the document at fetch time, so it does not change if the source's license changes later. |
| DE-07 dedup and language | `documents.language`, `documents.minhash` (datasketch signature), `documents.duplicate_of`. Exact duplicates are found by `content_hash`; near duplicates by MinHash. `crawl_runs.pages_duplicate` gives the duplicate rate per crawl. |
| DE-09 domain cache | See below. |
| DE-04 crawler | `sources.robots_allowed`, `robots_checked_at`, and `crawl_runs.user_agent`, `config`, `pages_blocked`. |
| DE-03 storage | `raw_object_key` and `clean_object_key` point to object storage; raw expires after 30 days (`raw_deleted_at`) and clean text is removed when a newer version of the page replaces it (`clean_deleted_at`), without losing the document row. |
| DE-11 monitoring | `crawl_runs.status` and counters make "failed or empty run" a simple query. |

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
3. **Duplicates and old versions stay in the tables but never leave through `retrievable_chunks`.**
4. **`pipeline_version` is not part of the chunk unique key** (the key is document, index, config hash).
   Consequence: re-running a newer pipeline with the same chunk settings hits the unique key and does not
   overwrite the old rows. When `pipeline_version` changes, the pipeline must replace the document's chunks in
   one transaction (delete, then insert). The alternative is to put `pipeline_version` into `chunk_config`, so the
   hash changes with it. Open question below.
5. **`chunk_config_hash`** is computed by the pipeline: sha256 of `chunk_config` as canonical JSON (sorted keys,
   no whitespace). It is a plain column, not generated, so the hashing rule is explicit in code and tests.
6. **`crawl_run_id` points to the run that first stored the document.** An unchanged page found by a later run
   inserts nothing; it is counted in that run's `pages_unchanged`.
7. **`embedding_model` is fixed by a CHECK**, so a model change needs a migration. That matches the contract
   (a model change must be approved by AI and DE and needs a rebuild), and it removes the "several models in one
   index" case.
8. **`section` and `concepts` live on `chunks`** (`text[] NOT NULL DEFAULT '{}'`), as in AI's table.

## HNSW index and filtered queries

`embeddings_hnsw_cosine_idx` uses `hnsw (embedding vector_cosine_ops)` with `m=16`, `ef_construction=64`
(pgvector defaults). The metric is final. DE-02 will tune the parameters on the 1M-chunk test set.

Because the model is fixed, we no longer filter by model, but a retrieval query still filters by
`embedding_version` while two versions overlap, and by what `retrievable_chunks` removes (old versions,
duplicates) and by domain. **Any query with such a filter must use `hnsw.iterative_scan`.**
Without it, HNSW returns its first `hnsw.ef_search` candidates (40 by default) and then applies the filter, so a
selective filter can leave few rows or none.

Measured earlier on the local container with synthetic random vectors (3,020 rows; 20 with the filtered value,
the rest not; `LIMIT 10`, plan confirmed to use the HNSW index):

| Setting | Rows returned |
|---|---|
| default | 0 |
| `SET hnsw.iterative_scan = relaxed_order` | 10 |

Use it per transaction so it does not leak into other work:

```sql
BEGIN;
SET LOCAL hnsw.iterative_scan = relaxed_order;
SELECT e.chunk_id
FROM knowledge.embeddings e
WHERE e.embedding_version = $1
ORDER BY e.embedding <=> $2
LIMIT 10;
COMMIT;
```

`relaxed_order` may return results slightly out of distance order; sort by distance in an outer query if exact
order matters, or use `strict_order`. `hnsw.max_scan_tuples` (default 20,000) caps how far the scan continues.
This was checked on random data only, so recall and the latency target are still for DE-02 to measure on real
data.

## Retention (raw 30 days and the clean-text rule are agreed with AI; the rest is PROPOSED and needs BE and DevOps)

| Data | Where | Keep | Then |
|---|---|---|---|
| Raw HTML | object storage | 30 days after `fetched_at` | Delete object, set `raw_deleted_at`; keep the document row |
| Clean text | object storage | Until the page is crawled again and a newer version is stored (not a fixed number of days) | Delete the old version's object, set `clean_deleted_at` |
| Superseded documents (`is_current = false`) | `documents` | 90 days | Delete row; chunks and embeddings cascade |
| Chunks and embeddings of a current document | `chunks`, `embeddings` | While the document exists | Cascade with the document |
| Old `embedding_version` rows | `embeddings` | 30 days after a newer version is fully backfilled | Delete |
| Sources never fetched, or not fetched for 12 months | `sources` | 12 months | Delete (cascades to `source_domains`, `documents`) |
| `crawl_runs` | `crawl_runs` | 12 months | Delete; `documents.crawl_run_id` becomes NULL |
| Crawl and pipeline logs | logs | 90 days | Delete |
| Sources with license `unknown` | `sources`, `documents` | Allowed as background knowledge only | Never copied as examples (DE-08) |

Personal data: these tables hold public web content only. User requests and accounts belong to
Backend; user deletion and request-text retention are handled in DE-13 and should not add user
columns here.

## Open questions

Answered by AI and removed: cosine as the metric; one embedding model; a chunk can have several domains; who
writes (the DE pipeline); which AI functions to call; role and `search_path` for AI; migrations are DE's. Items
that depend on files from AI are under "Waiting for AI" above.

**For AI (Ziad)**
1. What does your `content_hash` cover: the chunk text, or the whole page? We store the chunk text hash.
2. Is a skill domain hierarchical (`technology/ai`, matched with a prefix)? Your old index used
   `text_pattern_ops`. With `domains text[]`, how will you filter: exact value in the array, or prefix? Who owns
   the list of valid values?
3. Are the `chunk_config` keys (size, overlap, splitter) free-form or fixed? We hash the whole object.
4. Should `pipeline_version` be part of what makes a chunk set unique (decision 4)?

**For BE**
1. Is a separate `knowledge` schema acceptable next to your application tables?
2. Does Backend need to read these tables directly, or only through the retrieval API?
3. Do the retention numbers fit storage cost and any legal limits? Who confirms the agreed deletion time for DE-13?

**For both**
1. `source_type` is `web_page`, `skill_md`, `repo_file`. Is another type needed for the repository analysis in the spec?
2. Storing chunk text (not only summaries) in the store: does it conflict with the "no long copyrighted passages" rule? The rule is about what goes into skills, but the store holds source text internally.
