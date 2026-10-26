"""A -> B -> A: a page returns to old content and the old document row must come back.

These tests load db/schema-draft.sql into the local Postgres (docker compose, port 5433)
inside one transaction and roll it back at the end, so nothing is left in the database.
They are skipped when the database is not reachable or the schema is already installed.
"""
import os
from datetime import UTC, datetime, timedelta
from pathlib import Path

import psycopg
import pytest

SCHEMA_SQL = Path(__file__).resolve().parents[1] / "db" / "schema-draft.sql"
DATABASE_URL = os.environ.get(
    "DATABASE_URL",
    "postgresql://skillforge:skillforge_dev@localhost:5433/skillforge",
).replace("postgresql+psycopg://", "postgresql://")

HASH_A = "a" * 64
HASH_B = "b" * 64
T1 = datetime(2026, 11, 1, tzinfo=UTC)
T2 = T1 + timedelta(days=1)
T3 = T1 + timedelta(days=2)
CHUNK_CONFIG = '{"size": 500, "overlap": 50, "splitter": "sentence", "pipeline_version": "p1"}'


@pytest.fixture
def db():
    try:
        conn = psycopg.connect(DATABASE_URL, autocommit=False, connect_timeout=3)
    except psycopg.OperationalError as exc:
        pytest.skip(f"database not reachable: {exc}")
    try:
        exists = conn.execute(
            "SELECT 1 FROM pg_namespace WHERE nspname = 'knowledge'"
        ).fetchone()
        if exists:
            pytest.skip("schema 'knowledge' is already installed; refusing to touch it")
        conn.execute(SCHEMA_SQL.read_text(encoding="utf-8"))
        yield conn
    finally:
        conn.rollback()
        conn.close()


@pytest.fixture
def source_id(db):
    return db.execute(
        "INSERT INTO knowledge.sources (url, host, source_type) "
        "VALUES ('https://example.com/p', 'example.com', 'web_page') RETURNING id"
    ).fetchone()[0]


def record(db, source_id, content_hash, fetched_at, title="Page"):
    return db.execute(
        "SELECT knowledge.record_document_version(%s, %s, %s, %s, 'MIT', 'p1')",
        (source_id, content_hash, fetched_at, title),
    ).fetchone()[0]


def doc(db, doc_id):
    return db.execute(
        "SELECT is_current, fetched_at, status FROM knowledge.documents WHERE id = %s",
        (doc_id,),
    ).fetchone()


def add_chunk(db, doc_id, chunk_id, text):
    return db.execute(
        "INSERT INTO knowledge.chunks "
        "(chunk_id, document_id, chunk_index, text, content_hash, chunk_config, chunk_config_hash) "
        "VALUES (%s, %s, 0, %s, %s, %s::jsonb, 'cfg') RETURNING id",
        (chunk_id, doc_id, text, "c" * 64, CHUNK_CONFIG),
    ).fetchone()[0]


def test_same_content_again_only_refreshes_fetched_at(db, source_id):
    a1 = record(db, source_id, HASH_A, T1)
    a2 = record(db, source_id, HASH_A, T2)
    assert a1 == a2
    assert doc(db, a1)[:2] == (True, T2)
    assert db.execute("SELECT count(*) FROM knowledge.documents").fetchone()[0] == 1


def test_new_content_replaces_the_current_version(db, source_id):
    a = record(db, source_id, HASH_A, T1)
    b = record(db, source_id, HASH_B, T2)
    assert a != b
    assert doc(db, a)[0] is False
    assert doc(db, b)[0] is True


def test_a_b_a_brings_the_old_row_back(db, source_id):
    a = record(db, source_id, HASH_A, T1)
    b = record(db, source_id, HASH_B, T2)
    a_again = record(db, source_id, HASH_A, T3)

    assert a_again == a, "the old row is reused, not duplicated"
    assert doc(db, a)[:2] == (True, T3), "old row is current again with the new fetched_at"
    assert doc(db, b)[0] is False
    assert db.execute("SELECT count(*) FROM knowledge.documents").fetchone()[0] == 2
    assert db.execute(
        "SELECT count(*) FROM knowledge.documents WHERE source_id = %s AND is_current", (source_id,)
    ).fetchone()[0] == 1


def test_a_b_a_makes_the_old_chunks_retrievable_again(db, source_id):
    a = record(db, source_id, HASH_A, T1, title="A")
    chunk_a = add_chunk(db, a, "chunk-a", "text of A")
    b = record(db, source_id, HASH_B, T2, title="B")
    add_chunk(db, b, "chunk-b", "text of B")
    db.execute("INSERT INTO knowledge.active_config (chunk_config_hash, embedding_version) VALUES ('cfg', 'v1')")

    def visible():
        return {r[0] for r in db.execute("SELECT chunk_id FROM knowledge.retrievable_chunks").fetchall()}

    assert visible() == {"chunk-b"}
    record(db, source_id, HASH_A, T3, title="A")
    assert visible() == {"chunk-a"}, "after A -> B -> A only A's text is retrievable"
    assert chunk_a is not None


def test_restored_document_whose_clean_text_was_deleted_is_reprocessed(db, source_id):
    a = record(db, source_id, HASH_A, T1)
    db.execute(
        "UPDATE knowledge.documents SET status = 'embedded', clean_object_key = 'clean/a', "
        "clean_deleted_at = now() WHERE id = %s",
        (a,),
    )
    record(db, source_id, HASH_B, T2)
    record(db, source_id, HASH_A, T3)
    status, key, deleted_at = db.execute(
        "SELECT status, clean_object_key, clean_deleted_at FROM knowledge.documents WHERE id = %s", (a,)
    ).fetchone()
    assert (status, key, deleted_at) == ("fetched", None, None)
