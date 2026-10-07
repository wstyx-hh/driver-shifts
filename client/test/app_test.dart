import 'dart:convert';

import 'package:driver_shifts/add_trip_sheet.dart';
import 'package:driver_shifts/api.dart';
import 'package:driver_shifts/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';

const day1 = {
  'date': '2026-10-01',
  'summary': {
    'trips_count': 2,
    'revenue': 3900,
    'commission': 585,
    'net': 3315,
    'cash': {'count': 1, 'amount': 1500},
    'card': {'count': 1, 'amount': 2400},
    'minutes_on_trips': 37,
  },
  'trips': [
    {'id': 't1', 'start': '2026-10-01T08:10:00+05:00', 'end': '2026-10-01T08:32:00+05:00',
     'amount': 2400, 'payment': 'card', 'commission': 360},
    {'id': 't2', 'start': '2026-10-01T09:05:00+05:00', 'end': '2026-10-01T09:20:00+05:00',
     'amount': 1500, 'payment': 'cash', 'commission': 225},
  ],
};

http.Response json(Object body, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), status, headers: {'content-type': 'application/json'});

Future<void> openSheet(WidgetTester tester, Api api) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: AddTripSheet(
        api: api,
        day: DateTime(2026, 10, 2),
        start: const TimeOfDay(hour: 12, minute: 0),
        end: const TimeOfDay(hour: 12, minute: 25),
      ),
    ),
  ));
}

void main() {
  setUpAll(() => initializeDateFormatting('ru'));

  testWidgets('водитель видит «на руки», разбивку и поездки за выбранный день', (tester) async {
    final api = Api(client: MockClient((req) async {
      if (req.url.path == '/api/days') return json([{'date': '2026-10-01', 'trips_count': 2}]);
      if (req.url.path == '/api/days/2026-10-01') return json(day1);
      return json({}, 404);
    }));

    await tester.pumpWidget(DriverShiftsApp(api: api));
    await tester.pumpAndSettle();

    expect(find.text('1 октября, четверг'), findsOneWidget);
    expect(find.byKey(const Key('net')), findsOneWidget);
    expect((tester.widget<Text>(find.byKey(const Key('net')))).data!.replaceAll(RegExp(r'\s'), ''), '3315₸');
    expect(find.text('08:10 – 08:32'), findsOneWidget);
    expect(find.text('09:05 – 09:20'), findsOneWidget);
    expect(find.text('2 поездки · 37 мин в пути'), findsOneWidget);
  });

  testWidgets('повторное «Сохранить» после сбоя сети шлёт тот же id — сервер не заведёт дубль',
      (tester) async {
    final sentIds = <String>[];
    var calls = 0;
    final api = Api(client: MockClient((req) async {
      sentIds.add(jsonDecode(req.body)['id'] as String);
      if (++calls == 1) throw http.ClientException('connection reset');
      return json({
        'created': true,
        'trip': {...jsonDecode(req.body) as Map<String, dynamic>},
      }, 201);
    }));

    await openSheet(tester, api);
    await tester.enterText(find.byKey(const Key('amount')), '2000');
    await tester.tap(find.byKey(const Key('save')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Нет связи с сервером'), findsOneWidget);

    await tester.tap(find.byKey(const Key('save')));
    await tester.pumpAndSettle();

    expect(sentIds, hasLength(2));
    expect(sentIds[0], sentIds[1]);
  });

  testWidgets('комиссия больше суммы не уходит на сервер', (tester) async {
    var calls = 0;
    final api = Api(client: MockClient((_) async {
      calls++;
      return json({}, 500);
    }));

    await openSheet(tester, api);
    await tester.enterText(find.byKey(const Key('amount')), '1000');
    await tester.enterText(find.byKey(const Key('commission')), '1500');
    await tester.tap(find.byKey(const Key('save')));
    await tester.pumpAndSettle();

    expect(find.text('Комиссия не может быть больше суммы поездки'), findsOneWidget);
    expect(calls, 0);
  });

  testWidgets('комиссия подставляется 15% от суммы, пока её не правили руками', (tester) async {
    await openSheet(tester, Api(client: MockClient((_) async => json({}))));
    await tester.enterText(find.byKey(const Key('amount')), '2400');
    expect(find.text('360'), findsOneWidget);
  });

  test('время уходит на сервер с часовым поясом телефона', () {
    final s = isoWithOffset(DateTime(2026, 10, 1, 8, 5));
    expect(s, matches(RegExp(r'^2026-10-01T08:05:00[+-]\d\d:\d\d$')));
  });

  test('поездка через полночь помечается и считается по минутам', () {
    final t = Trip.fromJson({
      'id': 't39', 'start': '2026-10-06T23:52:00+05:00', 'end': '2026-10-07T00:18:00+05:00',
      'amount': 3800, 'payment': 'cash', 'commission': 570,
    });
    expect(t.endsNextDay, isTrue);
    expect(t.minutes, 26);
    expect(t.startClock, '23:52');
  });

  test('ошибки сервера показываются водителю без задвоенных слов', () async {
    final api = Api(client: MockClient((_) async => json({
          'errors': [
            {'field': 'amount', 'message': 'должно быть больше 0'},
            {'field': 'end', 'message': 'Окончание поездки должно быть позже начала'},
          ],
        }, 422)));
    final trip = NewTrip(
      start: DateTime(2026, 10, 2, 12), end: DateTime(2026, 10, 2, 11),
      amount: 0, payment: Payment.cash, commission: 0,
    );
    await expectLater(
      api.addTrip('c-1', trip),
      throwsA(isA<ApiException>().having((e) => e.messages, 'messages',
          ['Сумма: должно быть больше 0', 'Окончание поездки должно быть позже начала'])),
    );
  });

  testWidgets('сервер ответил HTML-страницей — экран показывает ошибку, а не крутится вечно',
      (tester) async {
    final api = Api(client: MockClient((_) async => http.Response('<html>502 Bad Gateway</html>', 502)));
    await tester.pumpWidget(DriverShiftsApp(api: api));
    await tester.pumpAndSettle();
    expect(find.text('Сервер ответил ошибкой 502'), findsOneWidget);
    expect(find.text('Повторить'), findsOneWidget);
  });

  testWidgets('сервер выключен — водитель видит, что делать, и может повторить', (tester) async {
    var up = false;
    final api = Api(client: MockClient((req) async {
      if (!up) throw http.ClientException('Connection refused');
      if (req.url.path == '/api/days') return json([{'date': '2026-10-01', 'trips_count': 2}]);
      return json(day1);
    }));
    await tester.pumpWidget(DriverShiftsApp(api: api));
    await tester.pumpAndSettle();
    expect(find.textContaining('Сервер не отвечает'), findsOneWidget);

    up = true;
    await tester.tap(find.text('Повторить'));
    await tester.pumpAndSettle();
    expect(find.text('08:10 – 08:32'), findsOneWidget);
  });
}
