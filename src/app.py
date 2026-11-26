"""FastAPI application for Pre-order Merchandise (Track A: EC2 + RDS MySQL)."""

from datetime import datetime, timedelta, timezone
import uuid
from typing import Literal, Optional

from fastapi import FastAPI, Header, Query, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field, field_validator

from src.db import check_db_health, get_connection, load_config

app = FastAPI(title="Merch Pre-order API", version="1.0.0")

VALID_SIZES = ("S", "M", "L", "XL")
ACTIVE_STATUSES = ("pending", "paid")


class ApiError(Exception):
    """Structured API error mapped to consistent JSON responses."""

    def __init__(self, status_code: int, code: str, message: str) -> None:
        self.status_code = status_code
        self.code = code
        self.message = message


@app.exception_handler(ApiError)
async def handle_api_error(_request: Request, exc: ApiError) -> JSONResponse:
    return JSONResponse(
        status_code=exc.status_code,
        content={"error": exc.code, "message": exc.message},
    )


@app.exception_handler(RequestValidationError)
async def handle_validation_error(_request: Request, exc: RequestValidationError) -> JSONResponse:
    return JSONResponse(
        status_code=400,
        content={"error": "VALIDATION_ERROR", "message": str(exc.errors()[0]["msg"])},
    )


class CreateOrderRequest(BaseModel):
    size: Literal["S", "M", "L", "XL"]
    qty: int = Field(..., ge=1)
    customerName: str = Field(..., min_length=1, max_length=100)
    contact: str = Field(..., min_length=6, max_length=32)

    @field_validator("customerName")
    @classmethod
    def strip_name(cls, v: str) -> str:
        cleaned = v.strip()
        if not cleaned:
            raise ValueError("customerName tidak boleh kosong")
        return cleaned

    @field_validator("contact")
    @classmethod
    def validate_contact(cls, v: str) -> str:
        cleaned = v.strip()
        if not cleaned.isdigit():
            raise ValueError("contact harus berupa angka")
        return cleaned


class UpdateOrderRequest(BaseModel):
    size: Optional[Literal["S", "M", "L", "XL"]] = None
    status: Optional[Literal["paid", "picked-up"]] = None


def _utc_now() -> datetime:
    return datetime.now(timezone.utc).replace(tzinfo=None, microsecond=0)


def _iso_utc(dt: datetime | None) -> str | None:
    if dt is None:
        return None
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def _serialize_order(row: dict) -> dict:
    payload = {
        "orderId": row["order_id"],
        "batchId": row["batch_id"],
        "customerName": row["customer_name"],
        "contact": row["contact"],
        "size": row["size"],
        "qty": row["qty"],
        "status": row["status"],
        "createdAt": _iso_utc(row["created_at"]),
        "updatedAt": _iso_utc(row["updated_at"]),
    }
    if row["pay_deadline"] is not None:
        payload["payDeadline"] = _iso_utc(row["pay_deadline"])
    return payload


@app.get("/health")
def health():
    """Health check endpoint verifying MySQL connectivity."""
    try:
        check_db_health()
        return {"status": "ok", "database": "connected"}
    except Exception as exc:
        return JSONResponse(
            status_code=503,
            content={"status": "error", "database": str(exc)},
        )


@app.post("/batches/{batch_id}/orders", status_code=201)
def create_order(
    batch_id: str,
    body: CreateOrderRequest,
    idempotency_key: Optional[str] = Header(default=None, alias="Idempotency-Key"),
):
    """Create a new pre-order with atomic SQL quota and per-person limit checks."""
    cfg = load_config()
    if not cfg.po_open:
        raise ApiError(409, "BATCH_NOT_OPEN", "Pre-order sedang ditutup")

    if body.qty > cfg.per_person_limit:
        raise ApiError(
            400,
            "VALIDATION_ERROR",
            f"qty maksimal {cfg.per_person_limit} pcs per pesanan",
        )

    order_id = (idempotency_key or "").strip() or str(uuid.uuid4())
    if len(order_id) > 64:
        raise ApiError(400, "VALIDATION_ERROR", "Idempotency-Key maksimal 64 karakter")

    conn = get_connection(cfg)
    try:
        with conn.cursor() as cur:
            # Idempotency check (R10): return existing order if already created.
            cur.execute("SELECT * FROM orders WHERE order_id = %s", (order_id,))
            existing = cur.fetchone()
            if existing:
                return JSONResponse(status_code=200, content=_serialize_order(existing))

            conn.begin()
            cur.execute(
                "SELECT qty, contact FROM orders WHERE batch_id = %s AND status IN ('pending', 'paid') FOR UPDATE",
                (batch_id,),
            )
            active_rows = cur.fetchall()

            used_quota = sum(r["qty"] for r in active_rows)
            if used_quota + body.qty > cfg.po_quota:
                conn.rollback()
                raise ApiError(409, "QUOTA_EXCEEDED", "Kuota batch sudah penuh")

            buyer_used = sum(r["qty"] for r in active_rows if r["contact"] == body.contact)
            if buyer_used + body.qty > cfg.per_person_limit:
                conn.rollback()
                raise ApiError(
                    409,
                    "BUYER_LIMIT_EXCEEDED",
                    f"Maksimal {cfg.per_person_limit} pcs per orang untuk batch ini",
                )

            now = _utc_now()
            pay_deadline = now + timedelta(hours=cfg.pay_window_hours)

            cur.execute(
                """
                INSERT INTO orders (
                    order_id, batch_id, customer_name, contact,
                    size, qty, status, pay_deadline, created_at, updated_at
                ) VALUES (%s, %s, %s, %s, %s, %s, 'pending', %s, %s, %s)
                """,
                (
                    order_id,
                    batch_id,
                    body.customerName,
                    body.contact,
                    body.size,
                    body.qty,
                    pay_deadline,
                    now,
                    now,
                ),
            )
            conn.commit()

            cur.execute("SELECT * FROM orders WHERE order_id = %s", (order_id,))
            created = cur.fetchone()
            return _serialize_order(created)
    except ApiError:
        raise
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


@app.get("/batches/{batch_id}/orders")
def list_orders(batch_id: str, limit: int = Query(default=50, ge=1, le=100)):
    """List orders for a given batch with a bounded LIMIT."""
    conn = get_connection()
    try:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT * FROM orders WHERE batch_id = %s ORDER BY created_at DESC LIMIT %s",
                (batch_id, limit),
            )
            rows = cur.fetchall()
            return {"batchId": batch_id, "orders": [_serialize_order(r) for r in rows]}
    finally:
        conn.close()


@app.get("/batches/{batch_id}/orders/{order_id}")
def get_order(batch_id: str, order_id: str):
    """Fetch a single order by batch_id and order_id."""
    conn = get_connection()
    try:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT * FROM orders WHERE order_id = %s AND batch_id = %s",
                (order_id, batch_id),
            )
            row = cur.fetchone()
            if not row:
                raise ApiError(404, "NOT_FOUND", "Pesanan tidak ditemukan")
            return _serialize_order(row)
    finally:
        conn.close()


@app.put("/batches/{batch_id}/orders/{order_id}")
def update_order(
    batch_id: str,
    order_id: str,
    body: UpdateOrderRequest,
    x_api_key: Optional[str] = Header(default=None, alias="X-API-Key"),
):
    """Update order size (buyer, while pending) or status (admin with X-API-Key)."""
    if body.size is None and body.status is None:
        raise ApiError(400, "VALIDATION_ERROR", "Body harus mengisi size atau status")
    if body.size is not None and body.status is not None:
        raise ApiError(400, "VALIDATION_ERROR", "Ubah size dan status secara terpisah")

    cfg = load_config()
    if body.status is not None and x_api_key != cfg.admin_api_key:
        raise ApiError(401, "UNAUTHORIZED", "X-API-Key admin tidak valid")

    conn = get_connection(cfg)
    try:
        with conn.cursor() as cur:
            conn.begin()
            cur.execute(
                "SELECT * FROM orders WHERE order_id = %s AND batch_id = %s FOR UPDATE",
                (order_id, batch_id),
            )
            row = cur.fetchone()
            if not row:
                conn.rollback()
                raise ApiError(404, "NOT_FOUND", "Pesanan tidak ditemukan")

            now = _utc_now()
            current_status = row["status"]

            if body.size is not None:
                if current_status != "pending":
                    conn.rollback()
                    raise ApiError(
                        409,
                        "INVALID_TRANSITION",
                        "Ukuran hanya bisa diubah saat status pending",
                    )
                cur.execute(
                    "UPDATE orders SET size = %s, updated_at = %s WHERE order_id = %s",
                    (body.size, now, order_id),
                )
            elif body.status == "paid":
                if current_status != "pending":
                    conn.rollback()
                    raise ApiError(409, "INVALID_TRANSITION", "Pesanan harus berstatus pending")
                if row["pay_deadline"] is not None and now > row["pay_deadline"]:
                    conn.rollback()
                    raise ApiError(409, "INVALID_TRANSITION", "Pesanan sudah melewati tenggat bayar")
                cur.execute(
                    "UPDATE orders SET status = 'paid', updated_at = %s WHERE order_id = %s",
                    (now, order_id),
                )
            elif body.status == "picked-up":
                if current_status != "paid":
                    conn.rollback()
                    raise ApiError(409, "INVALID_TRANSITION", "Pesanan harus berstatus paid")
                cur.execute(
                    "UPDATE orders SET status = 'picked-up', updated_at = %s WHERE order_id = %s",
                    (now, order_id),
                )

            conn.commit()
            cur.execute("SELECT * FROM orders WHERE order_id = %s", (order_id,))
            updated = cur.fetchone()
            return _serialize_order(updated)
    except ApiError:
        raise
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


@app.delete("/batches/{batch_id}/orders/{order_id}")
def cancel_order(batch_id: str, order_id: str):
    """Soft-delete (cancel) an order if it is still pending or paid."""
    conn = get_connection()
    try:
        with conn.cursor() as cur:
            now = _utc_now()
            cur.execute(
                """
                UPDATE orders
                SET status = 'cancelled', updated_at = %s
                WHERE order_id = %s AND batch_id = %s AND status IN ('pending', 'paid')
                """,
                (now, order_id, batch_id),
            )
            if cur.rowcount == 0:
                cur.execute(
                    "SELECT status FROM orders WHERE order_id = %s AND batch_id = %s",
                    (order_id, batch_id),
                )
                existing = cur.fetchone()
                if not existing:
                    raise ApiError(404, "NOT_FOUND", "Pesanan tidak ditemukan")
                raise ApiError(
                    409,
                    "INVALID_TRANSITION",
                    f"Pesanan sudah berstatus akhir ({existing['status']})",
                )
            conn.commit()
            cur.execute("SELECT * FROM orders WHERE order_id = %s", (order_id,))
            return _serialize_order(cur.fetchone())
    except ApiError:
        raise
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()

