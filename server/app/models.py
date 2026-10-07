from datetime import date, datetime
from typing import Annotated, Literal

from pydantic import (
    AwareDatetime,
    BaseModel,
    Field,
    StringConstraints,
    ValidationInfo,
    field_validator,
)

Payment = Literal["cash", "card"]


class TripIn(BaseModel):
    """Поездка, как её присылает клиент.

    `id` необязателен: если клиент его не прислал, сервер выведет id из времени
    поездки — тогда повторная отправка той же поездки всё равно попадёт в тот же id.
    Суммы — целые тенге: дробные копейки в такси не встречаются, а float в деньгах
    даёт ошибки округления.
    """

    # Пробелы по краям срезаем: id из одних пробелов — не id, а "t1 " и "t1" — одна поездка.
    id: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=64)] | None = None
    start: AwareDatetime
    end: AwareDatetime
    amount: int = Field(gt=0, strict=True)
    payment: Payment
    commission: int = Field(ge=0, strict=True)

    # Проверки «поле против поля» — валидаторами полей, а не всей модели: валидатор
    # модели не запускается, если хоть одно поле с ошибкой, и водитель с суммой 0
    # и перепутанным временем узнал бы о времени только со второй попытки.
    @field_validator("end")
    @classmethod
    def _end_after_start(cls, end: datetime, info: ValidationInfo) -> datetime:
        start = info.data.get("start")
        if start is not None and end <= start:
            raise ValueError("Окончание поездки должно быть позже начала")
        return end

    @field_validator("commission")
    @classmethod
    def _commission_within_amount(cls, commission: int, info: ValidationInfo) -> int:
        amount = info.data.get("amount")
        if amount is not None and commission > amount:
            raise ValueError("Комиссия не может быть больше суммы поездки")
        return commission


class Trip(TripIn):
    id: str

    @property
    def day(self) -> date:
        # День — по местному времени начала поездки (в том поясе, что прислал
        # клиент). Поездка через полночь остаётся в смене, где началась.
        return self.start.date()

    def same_as(self, other: TripIn) -> bool:
        # Сравниваем моменты времени, а не строки: 08:10+05:00 и 03:10Z — одно и то же.
        return (
            self.start == other.start
            and self.end == other.end
            and self.amount == other.amount
            and self.payment == other.payment
            and self.commission == other.commission
        )


class PaymentBreakdown(BaseModel):
    count: int = 0
    amount: int = 0


class DaySummary(BaseModel):
    trips_count: int
    revenue: int
    commission: int
    net: int  # «на руки»: выручка минус комиссия
    cash: PaymentBreakdown
    card: PaymentBreakdown
    minutes_on_trips: int


class DayReport(BaseModel):
    date: date
    summary: DaySummary
    trips: list[Trip]


class DayInfo(BaseModel):
    date: date
    trips_count: int


class AddTripResult(BaseModel):
    trip: Trip
    created: bool


class ErrorItem(BaseModel):
    field: str | None
    message: str


class ErrorBody(BaseModel):
    """Так сервер отвечает на 409 и 422 — описано, чтобы /docs не показывал стандартную схему FastAPI."""

    errors: list[ErrorItem]
    existing: Trip | None = None
