from datetime import date
from typing import Literal

from pydantic import AwareDatetime, BaseModel, Field, model_validator

Payment = Literal["cash", "card"]


class TripIn(BaseModel):
    """Поездка, как её присылает клиент.

    `id` необязателен: если клиент его не прислал, сервер выведет id из времени
    поездки — тогда повторная отправка той же поездки всё равно попадёт в тот же id.
    Суммы — целые тенге: дробные копейки в такси не встречаются, а float в деньгах
    даёт ошибки округления.
    """

    id: str | None = Field(default=None, min_length=1, max_length=64)
    start: AwareDatetime
    end: AwareDatetime
    amount: int = Field(gt=0, strict=True)
    payment: Payment
    commission: int = Field(ge=0, strict=True)

    @model_validator(mode="after")
    def _check_consistency(self) -> "TripIn":
        if self.end <= self.start:
            raise ValueError("Окончание поездки должно быть позже начала")
        if self.commission > self.amount:
            raise ValueError("Комиссия не может быть больше суммы поездки")
        return self


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
