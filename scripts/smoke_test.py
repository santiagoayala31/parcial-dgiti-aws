#!/usr/bin/env python3
"""Smoke test post-despliegue: espera a que el ALB responda y valida los endpoints.

Uso: python3 scripts/smoke_test.py http://<alb-dns>
"""
import json
import sys
import time
import urllib.error
import urllib.request

BASE = sys.argv[1].rstrip("/")
TIMEOUT_S = 900  # en el primer despliegue las EC2 tardan unos minutos en instalar


def call(method: str, path: str, body: dict | None = None, retries: int = 8):
    """Llama a la API; reintenta ante 502/503/504 (instancias que aún arrancan)."""
    data = json.dumps(body).encode() if body is not None else None
    for attempt in range(retries):
        req = urllib.request.Request(
            BASE + path, data=data, method=method, headers={"Content-Type": "application/json"}
        )
        try:
            with urllib.request.urlopen(req, timeout=10) as r:  # nosec B310 - URL del ALB propio
                return r.status, json.loads(r.read().decode())
        except urllib.error.HTTPError as exc:
            if exc.code in (502, 503, 504) and attempt < retries - 1:
                print(f"{method} {path}: HTTP {exc.code}, reintentando...")
                time.sleep(5)
                continue
            raise


start = time.time()
while True:
    try:
        status, body = call("GET", "/health")
        if status == 200:
            print(f"/health OK -> {body}")
            break
    except Exception as exc:  # noqa: BLE001
        print(f"Esperando al servicio... ({type(exc).__name__})")
    if time.time() - start > TIMEOUT_S:
        sys.exit("El servicio no respondió a tiempo")
    time.sleep(15)

for _ in range(20):  # /status depende de la BD y de que todas las instancias estén listas
    try:
        status, body = call("GET", "/status")
        if status == 200:
            print(f"/status OK -> BD: {body['database']}")
            break
    except Exception as exc:  # noqa: BLE001
        print(f"/status aún no listo ({type(exc).__name__})")
    time.sleep(15)
else:
    sys.exit("/status no respondió OK")

status, body = call("POST", "/api/items", {"name": "smoke-test", "description": "GitHub Actions"})
assert status == 201, status
print(f"POST /api/items OK -> {body['item']}")

seen = set()
for _ in range(20):
    _, body = call("GET", "/api/info")
    seen.add(body["instance_id"])
print(f"Instancias que respondieron a través del ALB: {sorted(seen)}")
print("SMOKE TEST EXITOSO")
