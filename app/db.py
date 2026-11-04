"""Capa de datos.

- Escrituras  -> instancia PRIMARIA de RDS.
- Lecturas    -> RÉPLICA de lectura de RDS (read/write splitting).
- Sin DB_HOST -> repositorio en memoria (pruebas unitarias y desarrollo local).
"""
import threading
import time
from datetime import datetime, timezone

import config

SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS items (
    id          SERIAL PRIMARY KEY,
    name        VARCHAR(120) NOT NULL,
    description TEXT DEFAULT '',
    created_by  VARCHAR(64)  NOT NULL,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);
"""


class InMemoryRepository:
    """Implementación en memoria con la misma interfaz que PostgresRepository."""

    backend = "memory"

    def __init__(self):
        self._items: list[dict] = []
        self._lock = threading.Lock()

    def init_schema(self):
        return None

    def close(self):
        return None

    def create_item(self, name: str, description: str, created_by: str) -> dict:
        with self._lock:
            item = {
                "id": len(self._items) + 1,
                "name": name,
                "description": description,
                "created_by": created_by,
                "created_at": datetime.now(timezone.utc).isoformat(),
            }
            self._items.append(item)
            return item

    def list_items(self, limit: int = 50) -> list[dict]:
        return list(reversed(self._items))[:limit]

    def get_item(self, item_id: int) -> dict | None:
        return next((i for i in self._items if i["id"] == item_id), None)

    def check(self) -> dict:
        return {
            "primary": {"ok": True, "latency_ms": 0.0},
            "replica": {"ok": True, "latency_ms": 0.0},
        }


class PostgresRepository:
    backend = "postgresql"

    def __init__(self):
        from psycopg_pool import ConnectionPool  # import diferido

        conninfo = (
            f"port={config.DB_PORT} dbname={config.DB_NAME} "
            f"user={config.DB_USER} password={config.DB_PASSWORD} "
            "connect_timeout=3"
        )
        self.primary = ConnectionPool(
            f"host={config.DB_HOST} {conninfo}", min_size=1, max_size=5, timeout=5, open=True
        )
        self.replica = ConnectionPool(
            f"host={config.DB_REPLICA_HOST} {conninfo}",
            min_size=1,
            max_size=5,
            timeout=5,
            open=True,
        )

    @staticmethod
    def _row(cur, row) -> dict:
        cols = [c.name for c in cur.description]
        data = dict(zip(cols, row))
        if isinstance(data.get("created_at"), datetime):
            data["created_at"] = data["created_at"].isoformat()
        return data

    def close(self):
        self.primary.close()
        self.replica.close()

    def init_schema(self):
        with self.primary.connection() as conn:
            conn.execute(SCHEMA_SQL)

    def create_item(self, name: str, description: str, created_by: str) -> dict:
        with self.primary.connection() as conn, conn.cursor() as cur:
            cur.execute(
                "INSERT INTO items (name, description, created_by) "
                "VALUES (%s, %s, %s) RETURNING *",
                (name, description, created_by),
            )
            return self._row(cur, cur.fetchone())

    def list_items(self, limit: int = 50) -> list[dict]:
        with self.replica.connection() as conn, conn.cursor() as cur:
            cur.execute("SELECT * FROM items ORDER BY id DESC LIMIT %s", (limit,))
            return [self._row(cur, r) for r in cur.fetchall()]

    def get_item(self, item_id: int) -> dict | None:
        with self.replica.connection() as conn, conn.cursor() as cur:
            cur.execute("SELECT * FROM items WHERE id = %s", (item_id,))
            row = cur.fetchone()
            return self._row(cur, row) if row else None

    def _ping(self, pool) -> dict:
        start = time.perf_counter()
        try:
            with pool.connection() as conn, conn.cursor() as cur:
                cur.execute("SELECT pg_is_in_recovery()")
                in_recovery = cur.fetchone()[0]
            return {
                "ok": True,
                "latency_ms": round((time.perf_counter() - start) * 1000, 2),
                "read_only_replica": bool(in_recovery),
            }
        except Exception as exc:  # noqa: BLE001
            return {"ok": False, "error": type(exc).__name__}

    def check(self) -> dict:
        return {"primary": self._ping(self.primary), "replica": self._ping(self.replica)}


def build_repository():
    if config.USE_DATABASE:
        return PostgresRepository()
    return InMemoryRepository()
