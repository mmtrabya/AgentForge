-- DRAFT for review (DE-01). Not a migration, not applied by docker-compose.
-- Everything lives in its own schema so it cannot clash with Backend's app tables.
-- Values marked PROPOSED are open for review by BE and AI.

CREATE EXTENSION IF NOT EXISTS vector;
CREATE SCHEMA IF NOT EXISTS knowledge;

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
-- (same vocabulary as SkillSpec skill.domain). A source can serve several domains.
-- This is the key of the DE-09 cache: "do we already hold fresh documents for this domain?"
-- ---------------------------------------------------------------------------
CREATE TABLE knowledge.source_domains (
    source_id        uuid        NOT NULL REFERENCES knowledge.sources (id) ON DELETE CASCADE,
    skill_domain     text        NOT NULL,
    PRIMARY KEY (source_id, skill_domain)
);
CREATE INDEX source_domains_skill_domain_idx ON knowledge.source_domains (skill_domain);

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
-- ---------------------------------------------------------------------------
CREATE TABLE knowledge.documents (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    source_id        uuid        NOT NULL REFERENCES knowledge.sources (id) ON DELETE CASCADE,
    crawl_run_id     uuid        REFERENCES knowledge.crawl_runs (id) ON DELETE SET NULL,
    fetched_at       timestamptz NOT NULL,           -- exposed as retrieved_at in provenance; DE-09 freshness
    http_status      integer,
    content_hash     text        NOT NULL,           -- sha256 hex of the raw fetched bytes
    license          text        NOT NULL DEFAULT 'unknown',  -- license as it was at fetch time
    pipeline_version text        NOT NULL,           -- version of clean/chunk code that last processed it (DE-05)
    title            text,
    language         text,                           -- ISO 639-1, NULL until detected (DE-07)
    minhash          bytea,                          -- MinHash signature for near-duplicate search (DE-07)
    duplicate_of     uuid        REFERENCES knowledge.documents (id) ON DELETE SET NULL,
    is_current       boolean     NOT NULL DEFAULT true,  -- latest version for its source
    status           text        NOT NULL DEFAULT 'fetched'
                     CHECK (status IN ('fetched', 'cleaned', 'chunked', 'embedded', 'failed')),
    raw_object_key   text,                           -- object storage key (DE-03); NULL after raw expiry
    clean_object_key text,
    raw_deleted_at   timestamptz,
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
-- settings; chunk_config_hash tells those sets apart (DE-05, tuned by AI in AI-10/AI-11).
-- ---------------------------------------------------------------------------
CREATE TABLE knowledge.chunks (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    document_id       uuid        NOT NULL REFERENCES knowledge.documents (id) ON DELETE CASCADE,
    chunk_index       integer     NOT NULL CHECK (chunk_index >= 0),
    text              text        NOT NULL,
    token_count       integer,
    content_hash      text        NOT NULL,          -- sha256 hex of the chunk text
    pipeline_version  text        NOT NULL,
    chunk_config      jsonb       NOT NULL DEFAULT '{}'::jsonb,  -- size, overlap, splitter: AI-owned values
    chunk_config_hash text        NOT NULL,          -- sha256 hex of chunk_config as canonical JSON (sorted keys)
    created_at        timestamptz NOT NULL DEFAULT now(),
    UNIQUE (document_id, chunk_index, chunk_config_hash)
);
CREATE INDEX chunks_content_hash_idx ON knowledge.chunks (content_hash);

-- ---------------------------------------------------------------------------
-- embeddings: one vector per (chunk, model, version). Dimension 384 is a contract
-- with the AI team. Changing the model means a new row, not an update.
-- ---------------------------------------------------------------------------
CREATE TABLE knowledge.embeddings (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    chunk_id          uuid        NOT NULL REFERENCES knowledge.chunks (id) ON DELETE CASCADE,
    embedding         vector(384) NOT NULL,
    embedding_model   text        NOT NULL,
    embedding_version text        NOT NULL,
    created_at        timestamptz NOT NULL DEFAULT now(),
    UNIQUE (chunk_id, embedding_model, embedding_version)
);
-- PROVISIONAL until AI confirms cosine. Queries must also filter on model + version,
-- and then need SET hnsw.iterative_scan (see docs/data-architecture.md).
CREATE INDEX embeddings_hnsw_cosine_idx
    ON knowledge.embeddings USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);

-- ---------------------------------------------------------------------------
-- Provenance (DE-06): every chunk reaches url, retrieved_at, license, content_hash.
-- ---------------------------------------------------------------------------
CREATE VIEW knowledge.chunk_provenance AS
SELECT c.id            AS chunk_id,
       c.content_hash  AS chunk_hash,
       d.id            AS document_id,
       d.content_hash  AS document_hash,
       s.id            AS source_id,
       s.url,
       s.host,
       d.fetched_at    AS retrieved_at,
       d.license                                     -- license at fetch time, not today's
FROM knowledge.chunks c
JOIN knowledge.documents d ON d.id = c.document_id
JOIN knowledge.sources   s ON s.id = d.source_id;

-- ---------------------------------------------------------------------------
-- retrievable_chunks: what the retrieval API may return (contract with AI).
-- Only the current version of a document, and never an exact/near duplicate.
-- Join embeddings on chunk_id and filter by embedding_model / embedding_version.
-- ---------------------------------------------------------------------------
CREATE VIEW knowledge.retrievable_chunks AS
SELECT c.id            AS chunk_id,
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
JOIN knowledge.documents d ON d.id = c.document_id
JOIN knowledge.sources   s ON s.id = d.source_id
WHERE d.is_current
  AND d.duplicate_of IS NULL;
