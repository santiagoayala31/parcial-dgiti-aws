"""Pruebas unitarias de la API (repositorio en memoria si no hay DB_HOST)."""


def test_health_ok(client):
    r = client.get("/health")
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "ok"
    assert "instance_id" in body


def test_health_adds_instance_headers(client):
    r = client.get("/health")
    assert "X-Instance-Id" in r.headers
    assert "X-Availability-Zone" in r.headers
    assert float(r.headers["X-Response-Time-ms"]) >= 0


def test_status_reports_primary_and_replica(client):
    r = client.get("/status")
    assert r.status_code == 200
    db = r.json()["database"]
    assert db["primary"]["ok"] is True
    assert db["replica"]["ok"] is True


def test_create_and_get_item(client):
    r = client.post("/api/items", json={"name": "prueba", "description": "pytest"})
    assert r.status_code == 201
    assert r.json()["written_to"] == "primary"
    item_id = r.json()["item"]["id"]

    r = client.get(f"/api/items/{item_id}")
    assert r.status_code == 200
    assert r.json()["item"]["name"] == "prueba"
    assert r.json()["read_from"] == "replica"


def test_list_items(client):
    client.post("/api/items", json={"name": "a"})
    r = client.get("/api/items?limit=10")
    assert r.status_code == 200
    assert r.json()["count"] >= 1


def test_item_not_found(client):
    assert client.get("/api/items/999999").status_code == 404


def test_create_item_validation(client):
    assert client.post("/api/items", json={"name": ""}).status_code == 422


def test_stress_endpoint(client):
    r = client.get("/api/stress?iterations=1000")
    assert r.status_code == 200
    assert r.json()["iterations"] == 1000


def test_stress_rejects_abusive_values(client):
    assert client.get("/api/stress?iterations=99999999").status_code == 422


def test_demo_page_and_swagger(client):
    assert "Distribución del tráfico" in client.get("/").text
    assert client.get("/docs").status_code == 200
    assert client.get("/openapi.json").status_code == 200
