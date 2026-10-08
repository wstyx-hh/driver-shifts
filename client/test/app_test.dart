import 'dart:convert';

import 'package:driver_shifts/add_trip_sheet.dart';
import 'package:driver_shifts/api.dart';
import 'package:driver_shifts/main.dart';
import 'package:driver_shifts/outbox.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

/// Сервер в миниатюре: помнит поездки по id, как настоящий, и умеет «пропадать».
class FakeServer {
  final trips = <String, Map<String, dynamic>>{};
  final postedIds = <String>[];
  bool up = true;

  /// Записать поездку, но «потерять» ответ — как обрыв связи после записи.
  bool loseNextReply = false;

  /// Ответить отказом на следующую поездку.
  http.Response? rejectNext;

  late final api = Api(client: MockClient((req) async {
    if (!up) throw http.ClientException('Connection refused');
    if (req.method == 'POST') {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      postedIds.add(body['id'] as String);
      if (rejectNext != null) {
        final r = rejectNext!;
        rejectNext = null;
        return r;
      }
      final created = !trips.containsKey(body['id']);
      trips.putIfAbsent(body['id'] as String, () => body);
      if (loseNextReply) {
        loseNextReply = false;
        throw http.ClientException('connection reset');
      }
      return json({'created': created, 'trip': trips[body['id']]}, created ? 201 : 200);
    }
    if (req.url.path == '/api/days') return json([{'date': '2026-10-01', 'trips_count': 2}]);
    return json(day1);
  }));
}

Future<Outbox> freshOutbox(Api api) async {
  SharedPreferences.setMockInitialValues({});
  return Outbox(api, await SharedPreferences.getInstance());
}

final trip = NewTrip(
  start: DateTime(2026, 10, 1, 12),
  end: DateTime(2026, 10, 1, 12, 25),
  amount: 2000,
  payment: Payment.cash,
  commission: 300,
);

/// Открывает форму так же, как экран дня, и собирает то, что она вернула.
Future<List<SubmitResult?>> openSheet(WidgetTester tester, Outbox outbox) async {
  final results = <SubmitResult?>[];
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () async => results.add(await showModalBottomSheet<SubmitResult>(
              context: context,
              isScrollControlled: true,
              builder: (_) => AddTripSheet(
                outbox: outbox,
                day: DateTime(2026, 10, 1),
                start: const TimeOfDay(hour: 12, minute: 0),
                end: const TimeOfDay(hour: 12, minute: 25),
              ),
            )),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return results;
}

Future<void> save(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(const Key('save')));
  await tester.tap(find.byKey(const Key('save')));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => initializeDateFormatting('ru'));

  testWidgets('водитель видит «на руки», разбивку и поездки за выбранный день', (tester) async {
    final server = FakeServer();
    await tester.pumpWidget(DriverShiftsApp(api: server.api, outbox: await freshOutbox(server.api)));
    await tester.pumpAndSettle();

    expect(find.text('1 октября, четверг'), findsOneWidget);
    expect((tester.widget<Text>(find.byKey(const Key('net')))).data!.replaceAll(RegExp(r'\s'), ''), '3315₸');
    expect(find.text('08:10 – 08:32'), findsOneWidget);
    expect(find.text('09:05 – 09:20'), findsOneWidget);
    expect(find.text('2 поездки · 37 мин в пути'), findsOneWidget);
  });

  // --- офлайн: поездка не теряется и не задваивается ---

  testWidgets('нет связи при сохранении — поездка остаётся на телефоне, а не теряется', (tester) async {
    final server = FakeServer()..up = false;
    final outbox = await freshOutbox(server.api);

    final results = await openSheet(tester, outbox);
    await tester.enterText(find.byKey(const Key('amount')), '2000');
    await save(tester);

    expect(results.single, isA<Queued>());
    expect(outbox.pending, hasLength(1));
    // Пережила перезапуск приложения.
    final reopened = Outbox(server.api, await SharedPreferences.getInstance());
    expect(reopened.pending.single.amount, 2000);
  });

  test('связь вернулась — очередь уходит с тем же id, что был у формы', () async {
    final server = FakeServer()..up = false;
    final outbox = await freshOutbox(server.api);
    expect(await outbox.submit('c-1', trip), isA<Queued>());

    server.up = true;
    expect(await outbox.flush(), 1);
    expect(server.trips.keys, ['c-1']);
    expect(outbox.pending, isEmpty);
  });

  test('сервер записал поездку, а ответ потерялся — досылка не создаёт дубль', () async {
    final server = FakeServer()..loseNextReply = true;
    final outbox = await freshOutbox(server.api);
    expect(await outbox.submit('c-1', trip), isA<Queued>());
    expect(server.trips, hasLength(1)); // на сервере уже есть

    await outbox.flush();
    expect(server.trips, hasLength(1));
    expect(outbox.pending, isEmpty);
  });

  test('связи всё ещё нет — очередь не теряет поездки и не тратит попытки на остальные', () async {
    final server = FakeServer()..up = false;
    final outbox = await freshOutbox(server.api);
    await outbox.submit('c-1', trip);
    await outbox.submit('c-2', trip);
    server.postedIds.clear();

    expect(await outbox.flush(), 0);
    expect(outbox.pending, hasLength(2));
  });

  test('сервер отказал при досылке — поездка не висит в очереди вечно, водитель видит причину', () async {
    final server = FakeServer()..up = false;
    final outbox = await freshOutbox(server.api);
    await outbox.submit('c-1', trip);

    server
      ..up = true
      ..rejectNext = json({
        'errors': [
          {'field': null, 'message': 'Поездка с таким же временем уже есть: t7'},
        ],
      }, 409);
    await outbox.flush();

    expect(outbox.pending, isEmpty);
    expect(outbox.rejected.single.messages, ['Поездка с таким же временем уже есть: t7']);
  });

  testWidgets('экран показывает, что не отправлено, и досылает по кнопке', (tester) async {
    final server = FakeServer()..up = false;
    final outbox = await freshOutbox(server.api);
    await outbox.submit('c-1', trip);

    await tester.pumpWidget(DriverShiftsApp(api: server.api, outbox: outbox, initialDay: DateTime(2026, 10, 1)));
    await tester.pumpAndSettle();
    expect(find.textContaining('Не отправлено: 1 поездка'), findsOneWidget);
    expect(find.textContaining('ждёт отправки'), findsOneWidget);

    server.up = true;
    await tester.tap(find.text('Отправить сейчас'));
    await tester.pumpAndSettle();
    expect(find.text('Связь есть — отправлено: 1 поездка'), findsOneWidget);
    expect(find.byKey(const Key('outbox-banner')), findsNothing);
  });

  // --- форма ---

  testWidgets('комиссия больше суммы не уходит на сервер', (tester) async {
    final server = FakeServer();
    final outbox = await freshOutbox(server.api);
    await openSheet(tester, outbox);
    await tester.enterText(find.byKey(const Key('amount')), '1000');
    await tester.enterText(find.byKey(const Key('commission')), '1500');
    await save(tester);

    expect(find.text('Комиссия не может быть больше суммы поездки'), findsOneWidget);
    expect(server.postedIds, isEmpty);
    expect(outbox.pending, isEmpty);
  });

  testWidgets('сервер отказал сразу — ошибка в форме, в очереди поездка не остаётся', (tester) async {
    final server = FakeServer()
      ..rejectNext = json({
        'errors': [
          {'field': 'amount', 'message': 'должно быть больше 0'},
        ],
      }, 422);
    final outbox = await freshOutbox(server.api);
    await openSheet(tester, outbox);
    await tester.enterText(find.byKey(const Key('amount')), '2000');
    await save(tester);

    expect(find.text('Сумма: должно быть больше 0'), findsOneWidget);
    expect(outbox.pending, isEmpty);
  });

  testWidgets('комиссия подставляется 15% от суммы, пока её не правили руками', (tester) async {
    final server = FakeServer();
    await openSheet(tester, await freshOutbox(server.api));
    await tester.enterText(find.byKey(const Key('amount')), '2400');
    expect(find.text('360'), findsOneWidget);
  });

  // --- мелочи, на которых легко ошибиться ---

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
    await expectLater(
      api.addTrip('c-1', trip),
      throwsA(isA<ApiException>().having((e) => e.messages, 'messages',
          ['Сумма: должно быть больше 0', 'Окончание поездки должно быть позже начала'])),
    );
  });

  testWidgets('сервер ответил HTML-страницей — экран показывает ошибку, а не крутится вечно',
      (tester) async {
    final api = Api(client: MockClient((_) async => http.Response('<html>502 Bad Gateway</html>', 502)));
    await tester.pumpWidget(DriverShiftsApp(api: api, outbox: await freshOutbox(api)));
    await tester.pumpAndSettle();
    expect(find.text('Сервер ответил ошибкой 502'), findsOneWidget);
    expect(find.text('Повторить'), findsOneWidget);
  });

  testWidgets('сервер выключен — водитель видит, что делать, и может повторить', (tester) async {
    final server = FakeServer()..up = false;
    await tester.pumpWidget(DriverShiftsApp(api: server.api, outbox: await freshOutbox(server.api)));
    await tester.pumpAndSettle();
    expect(find.textContaining('Сервер не отвечает'), findsOneWidget);

    server.up = true;
    await tester.tap(find.text('Повторить'));
    await tester.pumpAndSettle();
    expect(find.text('08:10 – 08:32'), findsOneWidget);
  });
}
