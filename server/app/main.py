import os
import shutil
from datetime import date
from pathlib import Path

from fastapi import FastAPI, Request, Response
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from .models import AddTripResult, DayInfo, DayReport, TripIn
from .store import TripConflict, TripStore
from .summary import summarize

DATA_DIR = Path(__file__).resolve().parent.parent / "data"

# Короткие русские подписи к ошибкам pydantic: клиент показывает их водителю как есть.
_MESSAGES = {
    "missing": "обязательное поле",
    "greater_than": "должно быть больше {gt}",
    "greater_than_equal": "должно быть не меньше {ge}",
    "int_type": "нужно целое число",
    "literal_error": "допустимо: {expected}",
    "timezone_aware": "нужно время с часовым поясом, например 2026-10-01T08:10:00+05:00",
    "datetime_from_date_parsing": "неверный формат даты и времени",
    "datetime_parsing": "неверный формат даты и времени",
    "datetime_type": "неверный формат даты и времени",
    "string_too_short": "не может быть пустым",
    "string_too_long": "слишком длинное значение",
    "string_type": "нужна строка",
    "json_invalid": "тело запроса — не JSON",
    "model_attributes_type": "ожидается объект поездки",
    "date_from_datetime_parsing": "нужна дата в виде ГГГГ-ММ-ДД",
    "date_parsing": "нужна дата в виде ГГГГ-ММ-ДД",
}


def _humanize(err: dict) -> dict:
    # loc выглядит как ("body", "amount") или ("path", "day"); у битого JSON — ("body", 0).
    parts = [str(p) for p in err["loc"] if p not in ("body", "path", "query") and not isinstance(p, int)]
    field = ".".join(parts) or None
    if err["type"] == "value_error":
        message = str(err["ctx"]["error"])
    elif err["type"] in _MESSAGES:
        message = _MESSAGES[err["type"]].format(**err.get("ctx", {}))
    else:
        message = err["msg"]
    return {"field": field, "message": message}


def create_app(store: TripStore) -> FastAPI:
    app = FastAPI(title="Дневник смен водителя")
    app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

    @app.exception_handler(RequestValidationError)
    async def _validation_error(_: Request, exc: RequestValidationError) -> JSONResponse:
        return JSONResponse(status_code=422, content={"errors": [_humanize(e) for e in exc.errors()]})

    @app.get("/api/days", response_model=list[DayInfo])
    def list_days() -> list[DayInfo]:
        return [DayInfo(date=d, trips_count=n) for d, n in store.days()]

    @app.get("/api/days/{day}", response_model=DayReport)
    def day_report(day: date) -> DayReport:
        trips = store.by_day(day)
        return DayReport(date=day, summary=summarize(trips), trips=trips)

    @app.post("/api/trips", response_model=AddTripResult, status_code=201)
    def add_trip(data: TripIn, response: Response):
        try:
            trip, created = store.add(data)
        except TripConflict as e:
            return JSONResponse(
                status_code=409,
                content={
                    "errors": [{"field": None, "message": e.message}],
                    "existing": e.existing.model_dump(mode="json"),
                },
            )
        if not created:
            response.status_code = 200
        return AddTripResult(trip=trip, created=created)

    return app


def default_app() -> FastAPI:
    """Точка входа для `uvicorn app.main:default_app --factory`."""
    path = Path(os.environ.get("TRIPS_FILE", DATA_DIR / "trips.json"))
    if not path.exists():
        # Первый запуск: начинаем с примера, чтобы было что посмотреть.
        path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(DATA_DIR / "sample_trips.json", path)
    return create_app(TripStore(path))
