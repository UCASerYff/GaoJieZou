"""Mac JSONEncoder 默认日期：自 2001-01-01 00:00:00 UTC 起的秒数。"""

from __future__ import annotations

from datetime import datetime, timedelta, timezone

from gaojiezou.errors import AppError

COCOA_EPOCH = datetime(2001, 1, 1, tzinfo=timezone.utc)


def cocoa(dt: datetime) -> float:
    if dt.tzinfo is None:
        raise ValueError("datetime must be timezone-aware")
    return (dt.astimezone(timezone.utc) - COCOA_EPOCH).total_seconds()


def from_cocoa(seconds: float) -> datetime:
    return COCOA_EPOCH + timedelta(seconds=float(seconds))


def ensure_aware(dt: datetime, tz: timezone | None = None) -> datetime:
    if dt.tzinfo is not None:
        return dt
    zone = tz or datetime.now().astimezone().tzinfo or timezone.utc
    return dt.replace(tzinfo=zone)


def in_zone(dt: datetime, tz) -> datetime:
    return ensure_aware(dt, tz).astimezone(tz)


def start_of_day(dt: datetime, tz) -> datetime:
    local = in_zone(dt, tz)
    return local.replace(hour=0, minute=0, second=0, microsecond=0)


def add_days(dt: datetime, days: int, tz) -> datetime:
    return start_of_day(dt, tz) + timedelta(days=days)


def swift_weekday(dt: datetime, tz) -> int:
    """Swift Calendar.weekday：1 = 周日 … 7 = 周六。"""
    local = in_zone(dt, tz)
    return (local.weekday() + 1) % 7 + 1


def day_key(dt: datetime, tz) -> str:
    local = in_zone(dt, tz)
    return f"{local.year:04d}-{local.month:02d}-{local.day:02d}"


def parse_instant(value, tz) -> datetime:
    if isinstance(value, (int, float)):
        return from_cocoa(float(value)).astimezone(tz)
    if isinstance(value, str):
        text = value.replace("Z", "+00:00")
        parsed = datetime.fromisoformat(text)
        return ensure_aware(parsed, tz).astimezone(tz)
    raise AppError("时间格式无法识别。", "invalid")
