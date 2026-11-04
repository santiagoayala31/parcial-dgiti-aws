// Prueba de carga con k6 contra el Application Load Balancer.
//
// Uso:
//   k6 run -e BASE_URL=http://<alb-dns> load-tests/k6-load.js
//   k6 run -e BASE_URL=http://<alb-dns> -e PROFILE=quick load-tests/k6-load.js   (≈2 min, para el video)
//
// Mide: tiempo de respuesta (avg, p90, p95), usuarios virtuales concurrentes,
// % de errores, throughput y la distribución de respuestas entre instancias/AZ.
import http from "k6/http";
import { check, sleep } from "k6";
import { Counter, Rate, Trend } from "k6/metrics";
import { textSummary } from "https://jslib.k6.io/k6-summary/0.1.0/index.js";

const BASE_URL = (__ENV.BASE_URL || "").replace(/\/$/, "");
if (!BASE_URL) throw new Error("Defina BASE_URL, ej: -e BASE_URL=http://mi-alb.us-east-1.elb.amazonaws.com");

const PROFILES = {
  // Perfil completo: suficiente para disparar el autoescalado por CPU
  full: [
    { duration: "1m", target: 30 },
    { duration: "2m", target: 80 },
    { duration: "4m", target: 150 },
    { duration: "1m", target: 0 },
  ],
  // Perfil corto para demostrar en vivo dentro del video
  quick: [
    { duration: "30s", target: 50 },
    { duration: "1m", target: 120 },
    { duration: "30s", target: 0 },
  ],
};

export const options = {
  scenarios: {
    usuarios: {
      executor: "ramping-vus",
      startVUs: 0,
      stages: PROFILES[__ENV.PROFILE || "full"],
      gracefulRampDown: "10s",
    },
  },
  thresholds: {
    http_req_failed: ["rate<0.05"], // menos de 5% de errores
    http_req_duration: ["p(95)<2000"], // p95 menor a 2 s
    "http_req_duration{endpoint:health}": ["p(95)<800"],
  },
  summaryTrendStats: ["avg", "min", "med", "p(90)", "p(95)", "max"],
};

const hitsByAz = new Counter("hits_por_az");
const lecturasReplica = new Trend("lectura_replica_ms", true);
const errores = new Rate("errores_funcionales");

export default function () {
  const r = Math.random();
  let res;

  if (r < 0.35) {
    // Tráfico ligero
    res = http.get(`${BASE_URL}/api/info`, { tags: { endpoint: "info" } });
  } else if (r < 0.55) {
    res = http.get(`${BASE_URL}/health`, { tags: { endpoint: "health" } });
  } else if (r < 0.75) {
    // Lectura desde la réplica de RDS
    res = http.get(`${BASE_URL}/api/items?limit=20`, { tags: { endpoint: "items_read" } });
    lecturasReplica.add(res.timings.duration);
  } else if (r < 0.8) {
    // Escritura en la primaria de RDS
    res = http.post(
      `${BASE_URL}/api/items`,
      JSON.stringify({ name: `k6-vu${__VU}`, description: `iter ${__ITER}` }),
      { headers: { "Content-Type": "application/json" }, tags: { endpoint: "items_write" } }
    );
  } else {
    // Trabajo de CPU: provoca saturación y autoescalado
    res = http.get(`${BASE_URL}/api/stress?iterations=30000`, { tags: { endpoint: "stress" } });
  }

  const ok = check(res, {
    "status 2xx": (x) => x.status >= 200 && x.status < 300,
    "atendido por una instancia": (x) => !!x.headers["X-Instance-Id"],
  });
  errores.add(!ok);
  if (res.headers["X-Availability-Zone"]) {
    hitsByAz.add(1, { az: res.headers["X-Availability-Zone"] });
  }
  sleep(Math.random() * 0.5 + 0.2);
}

export function handleSummary(data) {
  const ts = new Date().toISOString().replace(/[:.]/g, "-");
  return {
    stdout: textSummary(data, { indent: "  ", enableColors: true }),
    [`k6-summary-${ts}.json`]: JSON.stringify(data, null, 2),
  };
}
