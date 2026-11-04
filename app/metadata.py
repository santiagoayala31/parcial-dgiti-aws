"""Obtiene la identidad de la instancia EC2 usando IMDSv2.

Esto permite demostrar en vivo que el balanceador reparte el tráfico:
cada respuesta indica qué instancia y qué zona de disponibilidad la atendió.
"""
import socket
import urllib.request

_IMDS = "http://169.254.169.254/latest"
_cache: dict = {}


def _imds_get(path: str, token: str) -> str:
    req = urllib.request.Request(
        f"{_IMDS}/{path}", headers={"X-aws-ec2-metadata-token": token}
    )
    with urllib.request.urlopen(req, timeout=1) as resp:  # nosec B310
        return resp.read().decode()


def get_instance_identity() -> dict:
    if _cache:
        return _cache
    identity = {
        "instance_id": "local",
        "availability_zone": "local",
        "private_ip": "127.0.0.1",
        "hostname": socket.gethostname(),
    }
    try:
        token_req = urllib.request.Request(
            f"{_IMDS}/api/token",
            method="PUT",
            headers={"X-aws-ec2-metadata-token-ttl-seconds": "21600"},
        )
        with urllib.request.urlopen(token_req, timeout=1) as resp:  # nosec B310
            token = resp.read().decode()
        identity["instance_id"] = _imds_get("meta-data/instance-id", token)
        identity["availability_zone"] = _imds_get(
            "meta-data/placement/availability-zone", token
        )
        identity["private_ip"] = _imds_get("meta-data/local-ipv4", token)
    except Exception as exc:  # noqa: BLE001 - fuera de EC2 se usan valores locales
        identity["imds_error"] = type(exc).__name__
    _cache.update(identity)
    return _cache
