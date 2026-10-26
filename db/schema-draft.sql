-- DRAFT for review (DE-01). Not a migration, not applied by docker-compose.
-- Everything lives in its own schema so it cannot clash with Backend's app tables.
-- Values marked PROPOSED are open for review by BE and AI.
-- Not yet compared with AI's knowledge-chunks.sql (not in the repo yet); see docs.

CREATE EXTENSION IF NOT EXISTS vector;
CREATE SCHEMA IF NOT EXISTS knowledge;

-- ---------------------------------------------------------------------------
-- Helper checks (used by CHECK constraints below).
-- ---------------------------------------------------------------------------

-- domains: at least one value, no repeats, no NULL or empty element (AI contract).
CREATE FUNCTION knowledge.is_valid_domains(d text[]) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
    SELECT d IS NOT NULL
       AND cardinality(d) >= 1
       AND cardinality(d) = (SELECT count(DISTINCT x)
                             FROM unnest(d) AS x
                             WHERE x IS NOT NULL AND btrim(x) <> '')
$$;

-- chunk_config: exactly these four keys. size, overlap and splitter are AI-owned values;
-- pipeline_version is ours. All four are part of the config hash.
CREATE FUNCTION knowledge.is_valid_chunk_config(c jsonb) RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_typeof(c) = 'object'
       AND c ?& ARRAY['size', 'overlap', 'splitter', 'pipeline_version']
       AND (SELECT count(*) FROM jsonb_object_keys(c)) = 4
       AND jsonb_typeof(c -> 'size') = 'number'
       AND jsonb_typeof(c -> 'overlap') = 'number'
       AND jsonb_typeof(c -> 'splitter') = 'string'
       AND jsonb_typeof(c -> 'pipeline_version') = 'string'
$$;

-- ---------------------------------------------------------------------------
-- sources: one row per URL (or repo file) we are allowed to know about.
-- Holds what does not change between fetches: where it is and who owns it.
-- ---------------------------------------------------------------------------
CREATE TABLE knowledge.sources (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    url              text        NOT NULL,           -- normalized URL, see docs
    host             text        NOT NULL,           -- web host, lowercase (rate limits, robots.txt)
    source_type      text        NOT NULL
                     CHECK (source_type IN ('web_page', 'skill_md', 'repo_file')),
    license          text        NOT NULL DEFAULT 'unknown',  -- latest known SPDX id, or 'unknown'
    license_source   text        NOT NULL DEFAULT 'unknown'
                     CHECK (license_source IN ('page', 'repo', 'manual', 'unknown')),
    robots_allowed   boolean,                        -- NULL = not checked yet (DE-04)
    robots_checked_at timestamptz,
    created_at       timestamptz NOT NULL DEFAULT now(),
    UNIQUE (url)
);
CREATE INDEX sources_host_idx ON knowledge.sources (host);

-- ---------------------------------------------------------------------------
-- source_domains: which skill domain a source was collected for, e.g. 'technology/ai'
-- (same vocabulary as SkillSpec skill.domain; hierarchical, matched by path prefix).
-- A source can serve several domains. This is the key of the DE-09 cache, and the
-- pipeline copies it into embeddings.domains when it embeds a chunk.
-- ---------------------------------------------------------------------------
CREATE TABLE knowledge.source_domains (
    source_id        uuid        NOT NULL REFERENCES knowledge.sources (id) ON DELETE CASCADE,
    skill_domain     text        NOT NULL CHECK (btrim(skill_domain) <> ''),
    PRIMARY KEY (source_id, skill_domain)
);
-- text_pattern_ops so prefix filters work: skill_domain LIKE 'technology/%'
CREATE INDEX source_domains_skill_domain_idx ON knowledge.source_domains (skill_domain text_pattern_ops);

-- ---------------------------------------------------------------------------
-- crawl_runs: one row per crawler or pipeline run. Per-crawl numbers (DE-07 duplicate
-- rate, DE-11 failed/empty runs) come from here.
-- ---------------------------------------------------------------------------
CREATE TABLE knowledge.crawl_runs (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    started_at        timestamptz NOT NULL DEFAULT now(),
    finished_at       timestamptz,
    status            text        NOT NULL DEFAULT 'running'
                      CHECK (status IN ('running', 'succeeded', 'partial', 'failed')),
    skill_domain      text,                          -- domain the run was started for, if any
    user_agent        text        NOT NULL,          -- identified user agent that was used
    config            jsonb       NOT NULL DEFAULT '{}'::jsonb,  -- rate limits, depth, retries
    pipeline_version  text        NOT NULL,
    pages_fetched     integer     NOT NULL DEFAULT 0,
    pages_unchanged   integer     NOT NULL DEFAULT 0,  -- same content_hash as before
    pages_duplicate   integer     NOT NULL DEFAULT 0,  -- marked duplicate_of
    pages_blocked     integer     NOT NULL DEFAULT 0,  -- robots.txt or terms
    pages_failed      integer     NOT NULL DEFAULT 0,
    error             text,
    CHECK (finished_at IS NULL OR finished_at >= started_at)
);
CREATE INDEX crawl_runs_started_at_idx ON knowledge.crawl_runs (started_at);

-- ---------------------------------------------------------------------------
-- documents: one row per distinct content fetched from a source.
-- A page that changes gets a new row; the old one stays until retention removes it.
-- If old content comes back (A -> B -> A) the old row is brought back, see
-- knowledge.record_document_version() below.
-- ---------------------------------------------------------------------------
CREATE TABLE knowledge.documents (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    source_id        uuid        NOT NULL REFERENCES knowledge.sources (id) ON DELETE CASCADE,
    crawl_run_id     uuid        REFERENCES knowledge.crawl_runs (id) ON DELETE SET NULL,
    fetched_at       timestamptz NOT NULL,           -- exposed as retrieved_at in provenance; DE-09 freshness
    http_status      integer,
    content_hash     text        NOT NULL CHECK (content_hash ~ '^[0-9a-f]{64}$'),  -- sha256 hex of the raw fetched bytes
    license          text        NOT NULL DEFAULT 'unknown',  -- license as of the latest fetch
    pipeline_version text        NOT NULL,           -- version of fetch/clean code that processed it (DE-05)
    title            text        NOT NULL CHECK (btrim(title) <> ''),  -- page title from AI's extract_page(); never empty
    language         text,                           -- ISO 639-1, NULL until detected (DE-07)
    minhash          bytea,                          -- MinHash signature for near-duplicate search (DE-07)
    duplicate_of     uuid        REFERENCES knowledge.documents (id) ON DELETE SET NULL,
    is_current       boolean     NOT NULL DEFAULT true,  -- latest version for its source
    status           text        NOT NULL DEFAULT 'fetched'
                     CHECK (status IN ('fetched', 'cleaned', 'chunked', 'embedded', 'failed')),
    raw_object_key   text,                           -- object storage key (DE-03); NULL after raw expiry
    clean_object_key text,
    raw_deleted_at   timestamptz,                    -- raw HTML is kept 30 days
    clean_deleted_at timestamptz,                    -- clean text goes when a newer version replaces this one
    created_at       timestamptz NOT NULL DEFAULT now(),
    -- Re-running the crawler on unchanged content hits this and inserts nothing.
    UNIQUE (source_id, content_hash),
    CHECK (duplicate_of IS NULL OR duplicate_of <> id)
);
-- At most one current version per source.
CREATE UNIQUE INDEX documents_one_current_idx ON knowledge.documents (source_id) WHERE is_current;
CREATE INDEX documents_fetched_at_idx ON knowledge.documents (fetched_at);
CREATE INDEX documents_crawl_run_idx ON knowledge.documents (crawl_run_id);
CREATE INDEX documents_content_hash_idx ON knowledge.documents (content_hash);  -- exact dup lookup across sources
CREATE INDEX documents_duplicate_of_idx ON knowledge.documents (duplicate_of) WHERE duplicate_of IS NOT NULL;

-- ---------------------------------------------------------------------------
-- chunks: passages cut from a document. The same document can be chunked with several
-- configs; chunk_config_hash tells those sets apart. pipeline_version lives inside
-- chunk_config, so a new pipeline version is a new config and a new chunk set.
-- ---------------------------------------------------------------------------
CREATE TABLE knowledge.chunks (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),  -- internal key
    chunk_id          text        NOT NULL CHECK (btrim(chunk_id) <> ''),
                                  -- AI-10 chunk.chunk_id from extract_page(): same text on the same page
                                  -- gives the same id on every crawl. Citations use this, never `id`.
    document_id       uuid        NOT NULL REFERENCES knowledge.documents (id) ON DELETE CASCADE,
    chunk_index       integer     NOT NULL CHECK (chunk_index >= 0),
    text              text        NOT NULL,
    token_count       integer,
    section           text[]      NOT NULL DEFAULT '{}',  -- heading path inside the page (from AI extraction)
    concepts          text[]      NOT NULL DEFAULT '{}',  -- key concepts found in the chunk (from AI extraction)
    content_hash      text        NOT NULL CHECK (content_hash ~ '^[0-9a-f]{64}$'),  -- sha256 hex of the chunk text
    chunk_config      jsonb       NOT NULL CHECK (knowledge.is_valid_chunk_config(chunk_config)),
    chunk_config_hash text        NOT NULL,          -- sha256 hex of chunk_config as canonical JSON (sorted keys)
    created_at        timestamptz NOT NULL DEFAULT now(),
    UNIQUE (document_id, chunk_index, chunk_config_hash),
    UNIQUE (document_id, chunk_config_hash, chunk_id)
);
CREATE INDEX chunks_content_hash_idx ON knowledge.chunks (content_hash);
CREATE INDEX chunks_chunk_id_idx ON knowledge.chunks (chunk_id);

-- ---------------------------------------------------------------------------
-- embeddings: one vector per (chunk, model version). Contract with AI (26 Oct 2026):
-- model BAAI/bge-small-en-v1.5, 384 dimensions, L2-normalized, cosine.
-- DE does not create these vectors; AI's embed() does, called by the DE-05 pipeline.
-- A new model or dimension is a contract change approved by AI and DE, plus a rebuild.
-- embedding_version is the pinned model revision:
--   aa8f8b060edb00e03bfdd08813a2949946c8ba55  (Qdrant/bge-small-en-v1.5-onnx-Q)
-- ---------------------------------------------------------------------------
CREATE TABLE knowledge.embeddings (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    chunk_id          uuid        NOT NULL REFERENCES knowledge.chunks (id) ON DELETE CASCADE,
    embedding         vector(384) NOT NULL,
    embedding_model   text        NOT NULL
                      CHECK (embedding_model = 'local/BAAI/bge-small-en-v1.5'),  -- exact string, with local/
    embedding_version text        NOT NULL CHECK (btrim(embedding_version) <> ''),
    -- Skill domains of the chunk's source, copied from source_domains by the pipeline when it
    -- embeds. Kept on this table so the retrieval filter and the vector search touch one table.
    domains           text[]      NOT NULL CHECK (knowledge.is_valid_domains(domains)),
    created_at        timestamptz NOT NULL DEFAULT now(),
    -- Vectors must be unit length before writing; a small margin allows float32 rounding.
    CONSTRAINT embeddings_unit_norm CHECK (abs(vector_norm(embedding) - 1) < 0.001),
    UNIQUE (chunk_id, embedding_model, embedding_version)
);
-- FINAL (confirmed by AI): HNSW with cosine. Order by embedding <=> query; score = 1 - distance.
-- Filtered queries need SET hnsw.iterative_scan (see docs/data-architecture.md).
CREATE INDEX embeddings_hnsw_cosine_idx
    ON knowledge.embeddings USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);
-- Serves `domains && ARRAY[...]` (query domain and its parents).
CREATE INDEX embeddings_domains_gin_idx ON knowledge.embeddings USING gin (domains);

-- ---------------------------------------------------------------------------
-- active_config: ONE row. Which chunk config and which embedding version the views show.
-- Chunks of other configs or versions may exist side by side (during a rebuild); the
-- views only show the active set, so text never appears twice. The pipeline updates this
-- row, in the same transaction, when a rebuilt set is ready.
-- The row is created by the first pipeline run (the hash depends on AI's chunk settings);
-- until it exists the views return no rows.
-- ---------------------------------------------------------------------------
CREATE TABLE knowledge.active_config (
    id                boolean     PRIMARY KEY DEFAULT true CHECK (id),  -- only one row can exist
    chunk_config_hash text        NOT NULL,
    embedding_version text        NOT NULL CHECK (btrim(embedding_version) <> ''),
    updated_at        timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- record_document_version: what the DE-05 pipeline calls for every fetched page.
-- It keeps "one current version per source" true in all three cases:
--   1. same content as the current version     -> refresh fetched_at
--   2. new content                              -> demote the current row, insert a new current row
--   3. old content comes back (A -> B -> A)     -> demote the current row, bring the OLD row back
-- Case 3 matters because UNIQUE (source_id, content_hash) makes a plain insert fail, and an
-- insert-or-ignore would leave B current and A hidden even though the page now serves A.
-- If A's clean text was already deleted, A goes back to status 'fetched' so it is cleaned
-- again; its chunks and embeddings are still there, so nothing is embedded twice.
-- ---------------------------------------------------------------------------
CREATE FUNCTION knowledge.record_document_version(
    p_source_id        uuid,
    p_content_hash     text,
    p_fetched_at       timestamptz,
    p_title            text,
    p_license          text,
    p_pipeline_version text,
    p_crawl_run_id     uuid    DEFAULT NULL,
    p_http_status      integer DEFAULT NULL,
    p_raw_object_key   text    DEFAULT NULL
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
    v_id         uuid;
    v_is_current boolean;
BEGIN
    -- One writer per source at a time, so two workers cannot both demote and insert.
    PERFORM pg_advisory_xact_lock(hashtextextended(p_source_id::text, 0));

    SELECT id, is_current INTO v_id, v_is_current
    FROM knowledge.documents
    WHERE source_id = p_source_id AND content_hash = p_content_hash;

    IF v_id IS NOT NULL AND v_is_current THEN                       -- case 1
        UPDATE knowledge.documents
        SET fetched_at = p_fetched_at,
            license = p_license,
            http_status = p_http_status,
            raw_object_key = COALESCE(p_raw_object_key, raw_object_key),
            raw_deleted_at = CASE WHEN p_raw_object_key IS NULL THEN raw_deleted_at END
        WHERE id = v_id;
        RETURN v_id;
    END IF;

    -- Demote first: the partial unique index allows only one current row per source.
    UPDATE knowledge.documents SET is_current = false
    WHERE source_id = p_source_id AND is_current;

    IF v_id IS NOT NULL THEN                                        -- case 3
        UPDATE knowledge.documents
        SET is_current = true,
            fetched_at = p_fetched_at,
            license = p_license,
            http_status = p_http_status,
            raw_object_key = COALESCE(p_raw_object_key, raw_object_key),
            raw_deleted_at = CASE WHEN p_raw_object_key IS NULL THEN raw_deleted_at END
        WHERE id = v_id;
        UPDATE knowledge.documents
        SET status = 'fetched', clean_object_key = NULL, clean_deleted_at = NULL
        WHERE id = v_id AND clean_deleted_at IS NOT NULL;
        RETURN v_id;
    END IF;

    INSERT INTO knowledge.documents                                 -- case 2
        (source_id, crawl_run_id, fetched_at, http_status, content_hash, license,
         pipeline_version, title, raw_object_key)
    VALUES
        (p_source_id, p_crawl_run_id, p_fetched_at, p_http_status, p_content_hash, p_license,
         p_pipeline_version, p_title, p_raw_object_key)
    RETURNING id INTO v_id;
    RETURN v_id;
END
$$;
-- Functions are executable by everyone by default. Only the pipeline's role should call this
-- (grant EXECUTE to it when that role exists).
REVOKE EXECUTE ON FUNCTION knowledge.record_document_version(
    uuid, text, timestamptz, text, text, text, uuid, integer, text) FROM PUBLIC;

-- ---------------------------------------------------------------------------
-- Provenance (DE-06): every chunk reaches url, retrieved_at, license, content_hash.
-- Not filtered by active_config or is_current: any chunk, old or new, can be traced.
-- chunk_id is AI's id (the one citations use); chunk_uuid is our internal key.
-- ---------------------------------------------------------------------------
CREATE VIEW knowledge.chunk_provenance AS
SELECT c.chunk_id      AS chunk_id,
       c.id            AS chunk_uuid,
       c.content_hash  AS chunk_hash,
       d.id            AS document_id,
       d.content_hash  AS document_hash,
       s.id            AS source_id,
       s.url,
       s.host,
       d.fetched_at    AS retrieved_at,
       d.license                                     -- license as of the latest fetch
FROM knowledge.chunks c
JOIN knowledge.documents d ON d.id = c.document_id
JOIN knowledge.sources   s ON s.id = d.source_id;

-- ---------------------------------------------------------------------------
-- retrievable_chunks: what the retrieval API may return (contract with AI).
-- Only the current version of a document, never an exact/near duplicate, and only the
-- active chunk config. Join embeddings on chunk_uuid and filter by embedding_version.
-- ---------------------------------------------------------------------------
CREATE VIEW knowledge.retrievable_chunks AS
SELECT c.chunk_id      AS chunk_id,
       c.id            AS chunk_uuid,
       c.chunk_index,
       c.text,
       c.content_hash  AS chunk_hash,
       d.id            AS document_id,
       d.content_hash  AS document_hash,
       d.language,
       s.id            AS source_id,
       s.url,
       s.host,
       s.source_type,
       d.fetched_at    AS retrieved_at,
       d.license,
       ARRAY(SELECT sd.skill_domain
             FROM knowledge.source_domains sd
             WHERE sd.source_id = s.id
             ORDER BY sd.skill_domain) AS skill_domains
FROM knowledge.chunks c
JOIN knowledge.active_config ac ON ac.chunk_config_hash = c.chunk_config_hash
JOIN knowledge.documents d ON d.id = c.document_id
JOIN knowledge.sources   s ON s.id = d.source_id
WHERE d.is_current
  AND d.duplicate_of IS NULL;

-- ---------------------------------------------------------------------------
-- knowledge_chunks: the view AI reads (agreed 26 Oct 2026). AI reads from this view only,
-- as the read-only role skillforge_ai_reader; our pipeline (DE-05) writes to our tables.
-- Columns follow AI's table; `domain text` became `domains text[]` (one row per chunk).
-- chunk_id is AI's id from extract_page(), title is the page title (never empty), and
-- domains comes from the same table as the embedding, so the view needs no subquery.
-- Only the current, non-duplicate documents, and only the active config and version.
--
-- Read-only: it is a join. AI's own bootstrap (CREATE INDEX ... ON knowledge_chunks)
-- fails on a view; their code must not run pg_schema() against this database.
-- ---------------------------------------------------------------------------
CREATE VIEW knowledge.knowledge_chunks AS
SELECT c.chunk_id                              AS chunk_id,
       s.url                                   AS source_url,
       d.title                                 AS title,
       (d.fetched_at AT TIME ZONE 'UTC')::date AS retrieved,
       c.text                                  AS text,
       c.section                               AS section,
       c.concepts                              AS concepts,
       c.content_hash::char(64)                AS content_hash,
       e.domains                               AS domains,
       e.embedding_model                       AS embedding_model,
       e.embedding                             AS embedding
FROM knowledge.embeddings e
JOIN knowledge.active_config ac ON ac.embedding_version = e.embedding_version
JOIN knowledge.chunks    c ON c.id = e.chunk_id AND c.chunk_config_hash = ac.chunk_config_hash
JOIN knowledge.documents d ON d.id = c.document_id
JOIN knowledge.sources   s ON s.id = d.source_id
WHERE d.is_current
  AND d.duplicate_of IS NULL;
