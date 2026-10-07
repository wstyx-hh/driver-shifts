from collections.abc import Iterable

from .models import DaySummary, PaymentBreakdown, Trip


def summarize(trips: Iterable[Trip]) -> DaySummary:
    cash = PaymentBreakdown()
    card = PaymentBreakdown()
    revenue = commission = seconds = count = 0

    for trip in trips:
        count += 1
        revenue += trip.amount
        commission += trip.commission
        seconds += int((trip.end - trip.start).total_seconds())
        bucket = cash if trip.payment == "cash" else card
        bucket.count += 1
        bucket.amount += trip.amount

    return DaySummary(
        trips_count=count,
        revenue=revenue,
        commission=commission,
        net=revenue - commission,
        cash=cash,
        card=card,
        minutes_on_trips=seconds // 60,
    )
