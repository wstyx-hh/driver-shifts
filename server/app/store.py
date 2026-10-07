import hashlib
import json
import os
import threading
from collections import Counter
from datetime import date, timezone
from pathlib import Path

from .models import Trip, TripIn


class TripConflict(Exception):
    """Поездка с этим id или этим временем уже есть, но с другими данными."""

    def __init__(self, existing: Trip, message: str):
        super().__init__(message)
        self.existing = existing
        self.message = message


def natural_id(trip: TripIn) -> str:
    # Время в UTC, чтобы одна и та же поездка в разных записях пояса давала один id.
    key = "|".join(t.astimezone(timezone.utc).isoformat() for t in (trip.start, trip.end))
    return "t-" + hashlib.sha1(key.encode()).hexdigest()[:12]


class TripStore:
    """Поездки в JSON-файле. Всё держим в памяти, файл перезаписываем целиком.

    Для дневника одного водителя это сотни записей в месяц — база тут лишняя.
    Запись атомарная (временный файл + replace), чтобы падение посреди записи
    не оставило битый JSON.
    """

    def __init__(self, path: Path):
        self._path = path
        self._lock = threading.Lock()
        self._trips: dict[str, Trip] = {}
        if path.exists():
            for raw in json.loads(path.read_text(encoding="utf-8")):
                trip = Trip.model_validate(raw)
                self._trips[trip.id] = trip

    def by_day(self, day: date) -> list[Trip]:
        return sorted((t for t in self._trips.values() if t.day == day), key=lambda t: t.start)

    def days(self) -> list[tuple[date, int]]:
        counts = Counter(t.day for t in self._trips.values())
        return sorted(counts.items())

    def add(self, data: TripIn) -> tuple[Trip, bool]:
        """Добавляет поездку. Возвращает (поездка, создана ли новая).

        Повтор той же поездки (тот же id или то же время начала и конца с теми же
        данными) возвращает уже сохранённую запись и ничего не пишет: клиент мог
        не дождаться ответа и отправить ещё раз.
        """
        trip_id = data.id or natural_id(data)
        with self._lock:
            existing = self._trips.get(trip_id)
            if existing is not None:
                if existing.same_as(data):
                    return existing, False
                raise TripConflict(existing, f"Поездка {trip_id} уже есть с другими данными")

            # Тот же рейс под другим id: например, клиент заново сгенерировал id при повторе.
            twin = next(
                (t for t in self._trips.values() if t.start == data.start and t.end == data.end),
                None,
            )
            if twin is not None:
                if twin.same_as(data):
                    return twin, False
                raise TripConflict(twin, f"Поездка с таким же временем уже есть: {twin.id}")

            trip = Trip(**data.model_dump(exclude={"id"}), id=trip_id)
            self._trips[trip_id] = trip
            self._save()
            return trip, True

    def _save(self) -> None:
        self._path.parent.mkdir(parents=True, exist_ok=True)
        payload = [t.model_dump(mode="json") for t in sorted(self._trips.values(), key=lambda t: t.start)]
        tmp = self._path.with_suffix(".tmp")
        tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
        os.replace(tmp, self._path)
