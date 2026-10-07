from app.models import Trip
from app.summary import summarize


def trip(id, start, end, amount, payment, commission):
    return Trip(id=id, start=start, end=end, amount=amount, payment=payment, commission=commission)


T1 = trip("t1", "2026-10-01T08:10:00+05:00", "2026-10-01T08:32:00+05:00", 2400, "card", 360)
T2 = trip("t2", "2026-10-01T09:05:00+05:00", "2026-10-01T09:20:00+05:00", 1500, "cash", 225)


def test_пример_из_задания_сходится_до_тенге():
    s = summarize([T1, T2])
    assert s.trips_count == 2
    assert s.revenue == 3900
    assert s.commission == 585
    assert s.net == 3315
    assert (s.cash.count, s.cash.amount) == (1, 1500)
    assert (s.card.count, s.card.amount) == (1, 2400)
    assert s.minutes_on_trips == 22 + 15


def test_наличные_и_карта_в_сумме_дают_выручку():
    trips = [T1, T2, trip("t3", "2026-10-01T10:00:00+05:00", "2026-10-01T10:30:00+05:00", 3000, "card", 450)]
    s = summarize(trips)
    assert s.cash.amount + s.card.amount == s.revenue
    assert s.cash.count + s.card.count == s.trips_count
    assert s.card == type(s.card)(count=2, amount=5400)


def test_пустой_день_даёт_нули_а_не_ошибку():
    s = summarize([])
    assert s.trips_count == s.revenue == s.commission == s.net == s.minutes_on_trips == 0
    assert s.cash.count == s.card.count == 0


def test_поездка_без_комиссии_целиком_на_руки():
    s = summarize([trip("t9", "2026-10-01T10:00:00+05:00", "2026-10-01T10:10:00+05:00", 1000, "cash", 0)])
    assert s.net == 1000
