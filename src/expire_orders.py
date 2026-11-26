"""Cron script to mark overdue pending orders as expired."""

from datetime import datetime, timezone
from src.db import get_connection


def expire_overdue_orders() -> int:
    """Transition pending orders past pay_deadline to expired and return count."""
    now = datetime.now(timezone.utc).replace(tzinfo=None, microsecond=0)
    conn = get_connection()
    try:
        with conn.cursor() as cur:
            cur.execute(
                """
                UPDATE orders
                SET status = 'expired', updated_at = %s
                WHERE status = 'pending' AND pay_deadline IS NOT NULL AND pay_deadline < %s
                """,
                (now, now),
            )
            affected = cur.rowcount
        conn.commit()
        return affected
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


if __name__ == "__main__":
    expired_count = expire_overdue_orders()
    print(f"Expired {expired_count} overdue order(s)")

