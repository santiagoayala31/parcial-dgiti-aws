#!/usr/bin/env python3
"""Demuestra el funcionamiento del balanceador: envía N solicitudes concurrentes
al ALB y muestra cuántas atendió cada instancia y cada zona de disponibilidad.

Uso: python3 scripts/lb_distribution.py http://<alb-dns> [solicitudes] [hilos]
"""
import json
import sys
import time
import urllib.request
from collections import Counter
from concurrent.futures import ThreadPoolExecutor

BASE = sys.argv[1].rstrip("/")
TOTAL = int(sys.argv[2]) if len(sys.argv) > 2 else 300
THREADS = int(sys.argv[3]) if len(sys.argv) > 3 else 20


def hit(_):
    start = time.perf_counter()
    try:
        with urllib.request.urlopen(f"{BASE}/api/info", timeout=10) as r:  # nosec B310
            body = json.loads(r.read().decode())
            return body["instance_id"], body["availability_zone"], (time.perf_counter() - start) * 1000, None
    except Exception as exc:  # noqa: BLE001
        return None, None, (time.perf_counter() - start) * 1000, type(exc).__name__


t0 = time.perf_counter()
with ThreadPoolExecutor(max_workers=THREADS) as pool:
    results = list(pool.map(hit, range(TOTAL)))
elapsed = time.perf_counter() - t0

by_instance = Counter((r[0], r[1]) for r in results if r[0])
errors = Counter(r[3] for r in results if r[3])
latencies = sorted(r[2] for r in results if r[0])

print(f"\nDistribución de {TOTAL} solicitudes ({THREADS} concurrentes) a través del ALB\n")
print(f"{'Instancia':<22}{'AZ':<14}{'Respuestas':>11}   %")
print("-" * 72)
for (inst, az), n in by_instance.most_common():
    pct = 100 * n / TOTAL
    print(f"{inst:<22}{az:<14}{n:>11}  {pct:5.1f}% {'█' * int(pct / 2)}")
print("-" * 72)
ok = sum(by_instance.values())
print(f"Exitosas: {ok}/{TOTAL}  ·  Errores: {sum(errors.values())} {dict(errors) or ''}")
if latencies:
    p95 = latencies[int(len(latencies) * 0.95) - 1]
    print(f"Latencia promedio: {sum(latencies) / len(latencies):.1f} ms  ·  p95: {p95:.1f} ms")
print(f"Throughput: {TOTAL / elapsed:.1f} req/s  ·  Instancias distintas: {len(by_instance)}\n")
