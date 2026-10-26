-- Read-only role for AI's code (LOCAL development only).
-- Apply after the knowledge schema exists:
--   docker exec -i skillforge-postgres psql -U skillforge -d skillforge < db/roles-local.sql
-- The password below is a local-dev value, like the one in docker-compose.yml.
-- Staging and production create the same role from a migration or ops script, with a
-- password from the secret store (never from this file).

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'skillforge_ai_reader') THEN
        CREATE ROLE skillforge_ai_reader LOGIN PASSWORD 'skillforge_dev_reader'
            NOSUPERUSER NOCREATEDB NOCREATEROLE;
    END IF;
END
$$;

GRANT CONNECT ON DATABASE skillforge TO skillforge_ai_reader;
GRANT USAGE ON SCHEMA knowledge TO skillforge_ai_reader;

-- The only object the role may read. The view runs with its owner's rights, so the role
-- gets no access to the tables behind it.
GRANT SELECT ON knowledge.knowledge_chunks TO skillforge_ai_reader;

-- knowledge first, so `knowledge_chunks` resolves without a prefix. public stays in the
-- path because the vector type and the <=> operator live there.
ALTER ROLE skillforge_ai_reader SET search_path = knowledge, public;
