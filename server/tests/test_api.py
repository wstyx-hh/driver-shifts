import json

import pytest
from fastapi.testclient import TestClient

from app.main import create_app
from app.store import TripStore

NEW_TRIP = {
    "id": "t100",
    "start": "2026-10-02T12:00:00+05:00",
    "end": "2026-10-02T12:25:00+05:00",
    "amount": 2000,
    "payment": "cash",
    "commission": 300,
}


@pytest.fixture
def data_file(tmp_path):
    path = tmp_path / "trips.json"
    path.write_text(
        json.dumps(
            [
                {"id": "t1", "start": "2026-10-01T08:10:00+05:00", "end": "2026-10-01T08:32:00+05:00",
                 "amount": 2400, "payment": "card", "commission": 360},
                {"id": "t2", "start": "2026-10-01T09:05:00+05:00", "end": "2026-10-01T09:20:00+05:00",
                 "amount": 1500, "payment": "cash", "commission": 225},
                # Поездка через полночь — относится к дню начала.
                {"id": "t3", "start": "2026-10-01T23:50:00+05:00", "end": "2026-10-02T00:20:00+05:00",
                 "amount": 3000, "payment": "card", "commission": 450},
            ]
        ),
        encoding="utf-8",
    )
    return path


@pytest.fixture
def client(data_file):
    return TestClient(create_app(TripStore(data_file)))


def count_on(client, day):
    return client.get(f"/api/days/{day}").json()["summary"]["trips_count"]


# --- сводка и список за день ---


def test_день_отдаёт_поездки_по_порядку_и_сводку(client):
    body = client.get("/api/days/2026-10-01").json()
    assert [t["id"] for t in body["trips"]] == ["t1", "t2", "t3"]
    assert body["summary"]["revenue"] == 6900
    assert body["summary"]["net"] == 6900 - 1035


def test_поездка_через_полночь_не_попадает_в_следующий_день(client):
    assert client.get("/api/days/2026-10-02").json()["trips"] == []


def test_список_дней_для_переключения(client):
    assert client.get("/api/days").json() == [{"date": "2026-10-01", "trips_count": 3}]


# --- защита от дублей ---


def test_повторная_отправка_не_создаёт_дубль(client):
    first = client.post("/api/trips", json=NEW_TRIP)
    again = client.post("/api/trips", json=NEW_TRIP)
    assert first.status_code == 201 and first.json()["created"] is True
    assert again.status_code == 200 and again.json()["created"] is False
    assert count_on(client, "2026-10-02") == 1


def test_повтор_с_тем_же_временем_в_другом_поясе_тоже_дубль(client):
    client.post("/api/trips", json=NEW_TRIP)
    utc = {**NEW_TRIP, "start": "2026-10-02T07:00:00Z", "end": "2026-10-02T07:25:00Z"}
    assert client.post("/api/trips", json=utc).status_code == 200
    assert count_on(client, "2026-10-02") == 1


def test_повтор_без_id_не_создаёт_дубль(client):
    no_id = {k: v for k, v in NEW_TRIP.items() if k != "id"}
    first = client.post("/api/trips", json=no_id)
    again = client.post("/api/trips", json=no_id)
    assert first.status_code == 201
    assert again.status_code == 200
    assert first.json()["trip"]["id"] == again.json()["trip"]["id"]
    assert count_on(client, "2026-10-02") == 1


def test_та_же_поездка_под_новым_id_не_создаёт_дубль(client):
    # Клиент потерял ответ и при повторе сгенерировал id заново.
    client.post("/api/trips", json=NEW_TRIP)
    resp = client.post("/api/trips", json={**NEW_TRIP, "id": "t100-retry"})
    assert resp.status_code == 200
    assert resp.json()["trip"]["id"] == "t100"
    assert count_on(client, "2026-10-02") == 1


def test_тот_же_id_с_другой_суммой_это_конфликт_а_не_перезапись(client):
    client.post("/api/trips", json=NEW_TRIP)
    resp = client.post("/api/trips", json={**NEW_TRIP, "amount": 9999})
    assert resp.status_code == 409
    assert resp.json()["existing"]["amount"] == 2000
    assert client.get("/api/days/2026-10-02").json()["summary"]["revenue"] == 2000


def test_дубль_не_появляется_после_перезапуска(data_file):
    TestClient(create_app(TripStore(data_file))).post("/api/trips", json=NEW_TRIP)
    restarted = TestClient(create_app(TripStore(data_file)))
    assert restarted.post("/api/trips", json=NEW_TRIP).status_code == 200
    assert count_on(restarted, "2026-10-02") == 1


# --- проверка данных ---


@pytest.mark.parametrize(
    "patch, field",
    [
        ({"amount": 0}, "amount"),
        ({"amount": -100}, "amount"),
        ({"amount": 1500.5}, "amount"),
        ({"commission": -1}, "commission"),
        ({"payment": "crypto"}, "payment"),
        ({"start": "2026-10-02T12:00:00"}, "start"),  # без часового пояса день не определить
    ],
)
def test_неверные_поля_отклоняются_с_понятной_ошибкой(client, patch, field):
    resp = client.post("/api/trips", json={**NEW_TRIP, **patch})
    assert resp.status_code == 422
    assert field in [e["field"] for e in resp.json()["errors"]]
    assert count_on(client, "2026-10-02") == 0


@pytest.mark.parametrize("end", ["2026-10-02T12:00:00+05:00", "2026-10-02T11:59:00+05:00"])
def test_окончание_не_позже_начала_отклоняется(client, end):
    resp = client.post("/api/trips", json={**NEW_TRIP, "end": end})
    assert resp.status_code == 422
    assert resp.json()["errors"][0]["message"] == "Окончание поездки должно быть позже начала"


def test_комиссия_больше_суммы_отклоняется(client):
    resp = client.post("/api/trips", json={**NEW_TRIP, "commission": 2001})
    assert resp.status_code == 422
    assert "Комиссия" in resp.json()["errors"][0]["message"]


def test_одновременные_повторы_создают_ровно_одну_поездку(data_file):
    # Двойной тап по «Сохранить» или ретрай, пока первый запрос ещё идёт.
    from concurrent.futures import ThreadPoolExecutor

    store = TripStore(data_file)
    client = TestClient(create_app(store))
    with ThreadPoolExecutor(max_workers=10) as pool:
        codes = list(pool.map(lambda _: client.post("/api/trips", json=NEW_TRIP).status_code, range(20)))
    assert codes.count(201) == 1
    assert codes.count(200) == 19
    assert count_on(client, "2026-10-02") == 1
