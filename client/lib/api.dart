import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

/// Адрес сервера. Для эмулятора Android: --dart-define=API_URL=http://10.0.2.2:8000
const apiUrl = String.fromEnvironment('API_URL', defaultValue: 'http://localhost:8000');

enum Payment { cash, card }

class Trip {
  Trip({
    required this.id,
    required this.startRaw,
    required this.endRaw,
    required this.amount,
    required this.payment,
    required this.commission,
  });

  final String id;

  /// Время храним строкой как пришло с сервера: показываем водителю часы в поясе
  /// поездки, а не в поясе телефона (DateTime.parse переводит всё в UTC).
  final String startRaw;
  final String endRaw;
  final int amount;
  final Payment payment;
  final int commission;

  String get startClock => startRaw.substring(11, 16);
  String get endClock => endRaw.substring(11, 16);
  bool get endsNextDay => endRaw.substring(0, 10) != startRaw.substring(0, 10);
  int get minutes => DateTime.parse(endRaw).difference(DateTime.parse(startRaw)).inMinutes;

  factory Trip.fromJson(Map<String, dynamic> j) => Trip(
        id: j['id'] as String,
        startRaw: j['start'] as String,
        endRaw: j['end'] as String,
        amount: j['amount'] as int,
        payment: Payment.values.byName(j['payment'] as String),
        commission: j['commission'] as int,
      );
}

class PaymentPart {
  PaymentPart(this.count, this.amount);
  final int count;
  final int amount;

  factory PaymentPart.fromJson(Map<String, dynamic> j) => PaymentPart(j['count'] as int, j['amount'] as int);
}

class DaySummary {
  DaySummary({
    required this.tripsCount,
    required this.revenue,
    required this.commission,
    required this.net,
    required this.cash,
    required this.card,
    required this.minutesOnTrips,
  });

  final int tripsCount;
  final int revenue;
  final int commission;
  final int net;
  final PaymentPart cash;
  final PaymentPart card;
  final int minutesOnTrips;

  factory DaySummary.fromJson(Map<String, dynamic> j) => DaySummary(
        tripsCount: j['trips_count'] as int,
        revenue: j['revenue'] as int,
        commission: j['commission'] as int,
        net: j['net'] as int,
        cash: PaymentPart.fromJson(j['cash'] as Map<String, dynamic>),
        card: PaymentPart.fromJson(j['card'] as Map<String, dynamic>),
        minutesOnTrips: j['minutes_on_trips'] as int,
      );
}

class DayReport {
  DayReport(this.summary, this.trips);
  final DaySummary summary;
  final List<Trip> trips;
}

class DayInfo {
  DayInfo(this.date, this.tripsCount);
  final DateTime date;
  final int tripsCount;
}

class NewTrip {
  NewTrip({
    required this.start,
    required this.end,
    required this.amount,
    required this.payment,
    required this.commission,
  });

  /// Местное время телефона; отправляем с его часовым поясом.
  final DateTime start;
  final DateTime end;
  final int amount;
  final Payment payment;
  final int commission;
}

class AddResult {
  AddResult(this.trip, this.created);
  final Trip trip;
  final bool created;
}

/// Ошибка, которую можно показать водителю как есть.
class ApiException implements Exception {
  ApiException(this.messages);
  final List<String> messages;

  @override
  String toString() => messages.join('\n');
}

class Api {
  Api({http.Client? client, this.baseUrl = apiUrl}) : _http = client ?? http.Client();

  final http.Client _http;
  final String baseUrl;

  Future<List<DayInfo>> days() async {
    final list = await _get('/api/days') as List;
    return [
      for (final d in list.cast<Map<String, dynamic>>())
        DayInfo(DateTime.parse(d['date'] as String), d['trips_count'] as int),
    ];
  }

  Future<DayReport> day(DateTime day) async {
    final j = await _get('/api/days/${isoDate(day)}') as Map<String, dynamic>;
    return DayReport(
      DaySummary.fromJson(j['summary'] as Map<String, dynamic>),
      [for (final t in (j['trips'] as List).cast<Map<String, dynamic>>()) Trip.fromJson(t)],
    );
  }

  /// [id] создаётся один раз на форму: повторное нажатие «Сохранить» после сбоя
  /// сети шлёт тот же id, и сервер не заведёт вторую поездку.
  Future<AddResult> addTrip(String id, NewTrip t) async {
    final http.Response resp;
    try {
      resp = await _http.post(
        Uri.parse('$baseUrl/api/trips'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'id': id,
          'start': isoWithOffset(t.start),
          'end': isoWithOffset(t.end),
          'amount': t.amount,
          'payment': t.payment.name,
          'commission': t.commission,
        }),
      );
    } catch (_) {
      throw ApiException(['Нет связи с сервером. Нажмите «Сохранить» ещё раз — дубля не будет.']);
    }
    final body = jsonDecode(utf8.decode(resp.bodyBytes));
    if (resp.statusCode == 200 || resp.statusCode == 201) {
      return AddResult(Trip.fromJson(body['trip'] as Map<String, dynamic>), body['created'] as bool);
    }
    throw _errorFrom(body, resp.statusCode);
  }

  Future<dynamic> _get(String path) async {
    final http.Response resp;
    try {
      resp = await _http.get(Uri.parse('$baseUrl$path'));
    } catch (_) {
      throw ApiException(['Нет связи с сервером ($baseUrl)']);
    }
    final body = jsonDecode(utf8.decode(resp.bodyBytes));
    if (resp.statusCode != 200) throw _errorFrom(body, resp.statusCode);
    return body;
  }

  ApiException _errorFrom(dynamic body, int status) {
    if (body is Map && body['errors'] is List) {
      return ApiException([
        for (final e in (body['errors'] as List).cast<Map<String, dynamic>>())
          [if (e['field'] != null) fieldNames[e['field']] ?? e['field'], e['message']].join(': '),
      ]);
    }
    return ApiException(['Сервер ответил ошибкой $status']);
  }
}

const fieldNames = {
  'start': 'Начало',
  'end': 'Окончание',
  'amount': 'Сумма',
  'payment': 'Оплата',
  'commission': 'Комиссия',
};

String isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${_pad2(d.month)}-${_pad2(d.day)}';

String isoWithOffset(DateTime local) {
  final off = local.timeZoneOffset;
  final sign = off.isNegative ? '-' : '+';
  final abs = off.abs();
  return '${isoDate(local)}T${_pad2(local.hour)}:${_pad2(local.minute)}:00'
      '$sign${_pad2(abs.inHours)}:${_pad2(abs.inMinutes % 60)}';
}

String _pad2(int n) => n.toString().padLeft(2, '0');

final _rnd = Random.secure();

String newTripId() => 'c-${List.generate(12, (_) => _rnd.nextInt(16).toRadixString(16)).join()}';
