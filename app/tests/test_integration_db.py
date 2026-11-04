"""Pruebas de integración contra PostgreSQL real.

En GitHub Actions se levanta un contenedor PostgreSQL como 'service'
y se exporta DB_HOST. Si no hay DB_HOST, estas pruebas se omiten.
"""
import os

import pytest

pytestmark = pytest.mark.skipif(
    not os.getenv("DB_HOST"), reason="Requiere PostgreSQL (DB_HOST)"
)


def test_status_uses_postgresql(client):
    body = client.get("/status").json()
    assert body["database_backend"] == "postgresql"
    assert body["database"]["primary"]["ok"] is True


def test_write_then_read_roundtrip(client):
    created = client.post(
        "/api/items", json={"name": "integracion", "description": "postgres"}
    ).json()["item"]
    fetched = client.get(f"/api/items/{created['id']}").json()["item"]
    assert fetched["name"] == "integracion"
    assert fetched["created_by"]
