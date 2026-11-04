"""DGITI API - Evaluación final de Diseño y Gestión de Infraestructura Tecnológica.

Endpoints principales
  GET  /               Página demo: muestra qué instancia/AZ atendió (balanceo en vivo)
  GET  /health         Liveness para el Target Group del ALB (no toca la BD)
  GET  /status         Readiness: verifica BD primaria y réplica
  GET  /api/info       Identidad de la instancia que respondió
  GET  /api/items      Lista ítems (lee desde la RÉPLICA)
  POST /api/items      Crea ítem (escribe en la PRIMARIA)
  GET  /api/items/{id} Consulta un ítem (RÉPLICA)
  GET  /api/stress     Carga de CPU controlada para la prueba de saturación
  GET  /docs           Swagger UI (automático de FastAPI)
"""
import hashlib
import logging
import time
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, Query, Request
from fastapi.responses import HTMLResponse
from pydantic import BaseModel, Field

import config
from db import build_repository
from metadata import get_instance_identity

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger(config.APP_NAME)

STARTED_AT = time.time()


@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.repo = build_repository()
    try:
        app.state.repo.init_schema()
    except Exception as exc:  # noqa: BLE001 - la app arranca aunque la BD tarde
        log.warning("No se pudo inicializar el esquema: %s", exc)
    yield
    app.state.repo.close()


app = FastAPI(
    title="DGITI API",
    description="Servicio desplegado en AWS (ALB + Auto Scaling + RDS con réplica) "
    "mediante Terraform y GitHub Actions.",
    version=config.APP_VERSION,
    lifespan=lifespan,
)


class ItemIn(BaseModel):
    name: str = Field(..., min_length=1, max_length=120, examples=["Servidor web"])
    description: str = Field("", max_length=500, examples=["Creado desde Swagger"])


@app.middleware("http")
async def add_instance_headers(request: Request, call_next):
    start = time.perf_counter()
    response = await call_next(request)
    ident = get_instance_identity()
    response.headers["X-Instance-Id"] = ident["instance_id"]
    response.headers["X-Availability-Zone"] = ident["availability_zone"]
    response.headers["X-Response-Time-ms"] = f"{(time.perf_counter() - start) * 1000:.2f}"
    return response


@app.get("/health", tags=["validación"])
def health():
    ident = get_instance_identity()
    return {
        "status": "ok",
        "service": config.APP_NAME,
        "version": config.APP_VERSION,
        "instance_id": ident["instance_id"],
        "availability_zone": ident["availability_zone"],
        "uptime_s": round(time.time() - STARTED_AT, 1),
    }


@app.get("/status", tags=["validación"])
def status(request: Request):
    checks = request.app.state.repo.check()
    healthy = all(c.get("ok") for c in checks.values())
    body = {
        "status": "ok" if healthy else "degraded",
        "database_backend": request.app.state.repo.backend,
        "database": checks,
        "environment": config.ENVIRONMENT,
        **get_instance_identity(),
    }
    if not healthy:
        raise HTTPException(status_code=503, detail=body)
    return body


@app.get("/api/info", tags=["api"])
def info():
    return {"service": config.APP_NAME, "version": config.APP_VERSION, **get_instance_identity()}


@app.get("/api/items", tags=["api"])
def list_items(request: Request, limit: int = Query(50, ge=1, le=200)):
    items = request.app.state.repo.list_items(limit)
    return {"read_from": "replica", "count": len(items), "items": items}


@app.post("/api/items", status_code=201, tags=["api"])
def create_item(item: ItemIn, request: Request):
    created = request.app.state.repo.create_item(
        item.name, item.description, get_instance_identity()["instance_id"]
    )
    return {"written_to": "primary", "item": created}


@app.get("/api/items/{item_id}", tags=["api"])
def get_item(item_id: int, request: Request):
    item = request.app.state.repo.get_item(item_id)
    if item is None:
        raise HTTPException(status_code=404, detail="Ítem no encontrado")
    return {"read_from": "replica", "item": item}


@app.get("/api/stress", tags=["desempeño"])
def stress(iterations: int = Query(20000, ge=1, le=200000)):
    """Consume CPU de forma controlada (hash SHA-256 encadenado).

    Se usa en la prueba de carga para provocar saturación y ver el
    autoescalado y las métricas de CPU en CloudWatch.
    """
    start = time.perf_counter()
    digest = b"dgiti"
    for _ in range(iterations):
        digest = hashlib.sha256(digest).digest()
    return {
        "iterations": iterations,
        "cpu_ms": round((time.perf_counter() - start) * 1000, 2),
        "result": digest.hex()[:16],
        **get_instance_identity(),
    }


DEMO_PAGE = """<!doctype html>
<html lang="es"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>DGITI · Balanceo en vivo</title>
<style>
 body{font-family:system-ui,Segoe UI,Arial,sans-serif;background:#0f1b2a;color:#e8eef5;margin:0;padding:32px}
 h1{margin:0 0 4px;font-size:26px} .sub{color:#9fb3c8;margin-bottom:24px}
 .card{background:#16263a;border:1px solid #24405f;border-radius:12px;padding:18px 20px;margin-bottom:16px}
 .big{font-size:22px;font-weight:600;color:#ff9900} table{width:100%;border-collapse:collapse}
 td,th{padding:6px 8px;text-align:left;border-bottom:1px solid #24405f;font-size:14px}
 .bar{height:14px;background:#ff9900;border-radius:4px} a{color:#7cc4ff}
</style></head><body>
<h1>DGITI API · Diseño y Gestión de Infraestructura Tecnológica</h1>
<div class="sub">ALB → Auto Scaling Group (EC2 en 2 AZ) → RDS PostgreSQL primaria + réplica</div>
<div class="card">Esta página fue servida por:
 <div class="big">__INSTANCE__ · __AZ__</div>
 <div>Versión __VERSION__ · <a href="/docs">Swagger /docs</a> · <a href="/health">/health</a> · <a href="/status">/status</a></div></div>
<div class="card"><b>Distribución del tráfico en vivo</b> (cada segundo se consulta /api/info a través del ALB)
<table id="t"><thead><tr><th>Instancia</th><th>AZ</th><th>Respuestas</th><th style="width:45%"></th></tr></thead><tbody></tbody></table>
<div id="total" style="margin-top:8px;color:#9fb3c8"></div></div>
<script>
const counts={};let total=0;
async function tick(){
 try{const r=await fetch('/api/info',{cache:'no-store'});const j=await r.json();
  const k=j.instance_id;counts[k]=counts[k]||{az:j.availability_zone,n:0};counts[k].n++;total++;
  const rows=Object.entries(counts).sort((a,b)=>b[1].n-a[1].n).map(([id,v])=>
   `<tr><td>${id}</td><td>${v.az}</td><td>${v.n} (${(100*v.n/total).toFixed(0)}%)</td>
   <td><div class="bar" style="width:${100*v.n/total}%"></div></td></tr>`).join('');
  document.querySelector('#t tbody').innerHTML=rows;
  document.getElementById('total').textContent=`Total de solicitudes: ${total}`;
 }catch(e){document.getElementById('total').textContent='Error: '+e}}
setInterval(tick,1000);tick();
</script></body></html>"""


@app.get("/", response_class=HTMLResponse, include_in_schema=False)
def index():
    ident = get_instance_identity()
    return (
        DEMO_PAGE.replace("__INSTANCE__", ident["instance_id"])
        .replace("__AZ__", ident["availability_zone"])
        .replace("__VERSION__", config.APP_VERSION)
    )
