# Data Architecture: knowledge store (DE-01, DRAFT)

Status: draft for review by Backend and AI. No migrations exist yet.
The SQL is in [db/schema-draft.sql](../db/schema-draft.sql). It was run against the local
pgvector container (PostgreSQL 18, pgvector 0.8.7) inside a rolled-back transaction, so it
parses and its constraints behave as described below.

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
| `chunks` | A passage cut from a document | `document_id`, `chunk_index`, `text`, `content_hash`, `chunk_config`, `chunk_config_hash`, `pipeline_version` |
| `embeddings` | A vector for one chunk from one model | `chunk_id`, `embedding vector(384)`, `embedding_model`, `embedding_version` |

Two views:

- `chunk_provenance`: chunk → `url`, `host`, `retrieved_at`, `license`, chunk and document hashes.
- `retrievable_chunks`: `text` plus the provenance columns and `skill_domains`, only for chunks whose document
  is `is_current` and has `duplicate_of IS NULL`. **The retrieval API (contract with AI) reads this view**, so
  superseded and duplicate content can never be returned by mistake. Join `embeddings` on `chunk_id`.

`host` is the web host (rate limits and robots.txt work per host). `skill_domain` is the skill's field
(same vocabulary as SkillSpec `skill.domain`). They are different things and live in different tables.

## How the table design serves the later tasks

| Task | What the schema gives it |
|---|---|
| DE-05 idempotency | `documents` is unique on `(source_id, content_hash)`; `chunks` on `(document_id, chunk_index, chunk_config_hash)`; `embeddings` on `(chunk_id, embedding_model, embedding_version)`. Re-runs use `ON CONFLICT DO NOTHING`. |
| DE-06 provenance | Chunk → document → source gives `url`, `fetched_at` (as `retrieved_at`), `license`, `content_hash`. The license is the copy stored on the document at fetch time, so it does not change if the source's license changes later. |
| DE-07 dedup and language | `documents.language`, `documents.minhash` (datasketch signature), `documents.duplicate_of`. Exact duplicates are found by `content_hash`; near duplicates by MinHash. `crawl_runs.pages_duplicate` gives the duplicate rate per crawl. |
| DE-09 domain cache | See below. |
| DE-04 crawler | `sources.robots_allowed`, `robots_checked_at`, and `crawl_runs.user_agent`, `config`, `pages_blocked`. |
| DE-03 storage | `raw_object_key` and `clean_object_key` point to object storage; raw can expire (`raw_deleted_at`) without losing the document row. |
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

## HNSW index and filtered queries

`embeddings_hnsw_cosine_idx` uses `hnsw (embedding vector_cosine_ops)` with `m=16`,
`ef_construction=64` (pgvector defaults). It is provisional until AI confirms the metric.
DE-02 will tune it on the 1M-chunk test set.

One index covers every model and version in the table, so retrieval queries must filter by
`embedding_model` and `embedding_version`. **Queries with that filter must use `hnsw.iterative_scan`.**
Without it, HNSW returns its first `hnsw.ef_search` candidates (40 by default) and then applies the filter, so a
selective filter can leave few rows or none.

Measured on the local container with synthetic random vectors (3,020 rows; 20 of model `target`, the rest
`noise`; query filtered to `target`, `LIMIT 10`, plan confirmed to use the HNSW index):

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
WHERE e.embedding_model = $1 AND e.embedding_version = $2
ORDER BY e.embedding <=> $3
LIMIT 10;
COMMIT;
```

`relaxed_order` may return results slightly out of distance order; sort by distance in an outer query if exact
order matters, or use `strict_order`. `hnsw.max_scan_tuples` (default 20,000) caps how far the scan continues.
This was checked on random data only, so recall and the latency target are still for DE-02 to measure on real
data. If more than one model is live at a time, we should switch to one partial index per active model.

## Retention (PROPOSED, values need agreement with BE and DevOps)

| Data | Where | Keep | Then |
|---|---|---|---|
| Raw page bytes | object storage | 30 days after `fetched_at` | Delete object, set `raw_deleted_at`; keep the document row |
| Clean text | object storage | While the document is current, and 90 days after it is superseded | Delete |
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

**For AI**
1. Is cosine the final distance metric? (Index is provisional until you confirm.)
2. Will more than one embedding model be live at the same time? That decides one shared index or one partial index per model.
3. Are the `chunk_config` keys (size, overlap, splitter) free-form, or a fixed set? We hash the whole object.
4. Is `skill_domain` a closed vocabulary like `technology/ai`? Who owns the list?
5. Should `pipeline_version` be part of what makes a chunk set unique (decision 4)?

**For BE**
1. Is a separate `knowledge` schema acceptable, and who owns migrations (Alembic) and runs them on staging?
2. Does Backend need to read these tables directly, or only through the retrieval API?
3. Do the retention numbers fit storage cost and any legal limits? Who confirms the agreed deletion time for DE-13?

**For both**
1. `source_type` is `web_page`, `skill_md`, `repo_file`. Is another type needed for the repository analysis in the spec?
2. Storing chunk text (not only summaries) in the store: does it conflict with the "no long copyrighted passages" rule? The rule is about what goes into skills, but the store holds source text internally.
