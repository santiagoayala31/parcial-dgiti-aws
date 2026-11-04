"""Configuración de la aplicación leída desde variables de entorno.

En EC2 estas variables las escribe user_data.sh en /etc/dgiti-app.env
(la contraseña de la BD se obtiene de AWS Secrets Manager, nunca del código).
"""
import os

APP_NAME = os.getenv("APP_NAME", "dgiti-api")
APP_VERSION = os.getenv("APP_VERSION", "dev")
ENVIRONMENT = os.getenv("ENVIRONMENT", "local")

DB_HOST = os.getenv("DB_HOST", "")
DB_REPLICA_HOST = os.getenv("DB_REPLICA_HOST", "") or DB_HOST
DB_PORT = int(os.getenv("DB_PORT", "5432"))
DB_NAME = os.getenv("DB_NAME", "appdb")
DB_USER = os.getenv("DB_USER", "appuser")
DB_PASSWORD = os.getenv("DB_PASSWORD", "")

# Si no hay host de BD se usa un repositorio en memoria (pruebas unitarias / local)
USE_DATABASE = bool(DB_HOST)
