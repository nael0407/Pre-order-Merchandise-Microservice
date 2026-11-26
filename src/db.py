"""Database connection and environment configuration helpers."""

import os
from dataclasses import dataclass
import pymysql
from pymysql.cursors import DictCursor


@dataclass(frozen=True)
class AppConfig:
    """Application settings loaded from environment variables."""

    db_host: str
    db_port: int
    db_user: str
    db_pass: str
    db_name: str
    po_open: bool
    po_quota: int
    per_person_limit: int
    pay_window_hours: int
    admin_api_key: str


def load_config() -> AppConfig:
    """Read runtime configuration from environment variables."""
    return AppConfig(
        db_host=os.getenv("DB_HOST", "127.0.0.1"),
        db_port=int(os.getenv("DB_PORT", "3306")),
        db_user=os.getenv("DB_USER", "admin"),
        db_pass=os.getenv("DB_PASS", ""),
        db_name=os.getenv("DB_NAME", "merch_preorder"),
        po_open=os.getenv("PO_OPEN", "true").strip().lower() in {"1", "true", "yes"},
        po_quota=int(os.getenv("PO_QUOTA", "50")),
        per_person_limit=int(os.getenv("PER_PERSON_LIMIT", "2")),
        pay_window_hours=int(os.getenv("PAY_WINDOW_HOURS", "24")),
        admin_api_key=os.getenv("ADMIN_API_KEY", "dev-admin-key"),
    )


def get_connection(cfg: AppConfig | None = None) -> pymysql.connections.Connection:
    """Create a new PyMySQL connection with DictCursor and manual transactions."""
    conf = cfg or load_config()
    return pymysql.connect(
        host=conf.db_host,
        port=conf.db_port,
        user=conf.db_user,
        password=conf.db_pass,
        database=conf.db_name,
        charset="utf8mb4",
        cursorclass=DictCursor,
        autocommit=False,
        connect_timeout=5,
    )


def check_db_health(cfg: AppConfig | None = None) -> bool:
    """Verify RDS MySQL connectivity with a lightweight SELECT 1 query."""
    conn = get_connection(cfg)
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT 1")
            cur.fetchone()
        return True
    finally:
        conn.close()

