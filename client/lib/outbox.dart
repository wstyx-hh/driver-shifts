import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';

/// Итог «Сохранить»: либо сервер ответил, либо поездка ждёт в очереди на телефоне.
sealed class SubmitResult {}

class Sent extends SubmitResult {
  Sent(this.result);
  final AddResult result;
}

class Queued extends SubmitResult {
  Queued(this.trip);
  final Trip trip;
}

/// Поездку отправить так и не удалось: сервер отказал (например, 409 —
/// под этим временем уже другая поездка). Показываем водителю, чтобы не потерялась молча.
class Rejected {
  Rejected(this.trip, this.messages);
  final Trip trip;
  final List<String> messages;
}

/// Очередь неотправленных поездок, хранится на телефоне.
///
/// Водитель в туннеле или за городом без сети всё равно записывает поездку:
/// она сохраняется сюда и уходит на сервер, когда связь вернётся. Дублей это не
/// создаёт: у поездки один id с момента открытия формы, а сервер на повтор
/// с тем же id отвечает «уже есть». Поэтому в очередь пишем ДО запроса — если
/// приложение закроют посреди отправки, поездка не потеряется, а лишний повтор безвреден.
class Outbox extends ChangeNotifier {
  Outbox(this._api, this._prefs) {
    final raw = _prefs.getString(_key);
    if (raw != null) {
      _pending.addAll((jsonDecode(raw) as List).cast<Map<String, dynamic>>());
    }
  }

  static const _key = 'outbox.v1';

  static Future<Outbox> open(Api api) async => Outbox(api, await SharedPreferences.getInstance());

  final Api _api;
  final SharedPreferences _prefs;
  final List<Map<String, dynamic>> _pending = [];
  final List<Rejected> _rejected = [];
  bool _flushing = false;

  List<Trip> get pending => [for (final b in _pending) Trip.fromJson(b)];
  List<Rejected> get rejected => List.unmodifiable(_rejected);

  List<Trip> pendingOn(DateTime day) {
    final key = isoDate(day);
    return [for (final t in pending) if (t.startRaw.startsWith(key)) t];
  }

  Future<SubmitResult> submit(String id, NewTrip trip) async {
    final body = Api.tripBody(id, trip);
    _pending.removeWhere((b) => b['id'] == id);
    _pending.add(body);
    await _save();
    try {
      final result = await _api.sendTrip(body);
      await _drop(id);
      return Sent(result);
    } on OfflineException {
      return Queued(Trip.fromJson(body));
    } on ApiException {
      // Сервер отказал прямо сейчас — водитель ещё в форме и увидит ошибку там.
      await _drop(id);
      rethrow;
    }
  }

  /// Отправляет всё, что накопилось. Возвращает, сколько поездок ушло.
  /// Останавливается на первой ошибке сети: значит, связи всё ещё нет.
  Future<int> flush() async {
    if (_flushing || _pending.isEmpty) return 0;
    _flushing = true;
    var sent = 0;
    try {
      for (final body in List.of(_pending)) {
        try {
          await _api.sendTrip(body);
          sent++;
        } on OfflineException {
          break;
        } on ApiException catch (e) {
          _rejected.add(Rejected(Trip.fromJson(body), e.messages));
        }
        await _drop(body['id'] as String);
      }
    } finally {
      _flushing = false;
    }
    return sent;
  }

  void dismissRejected() {
    _rejected.clear();
    notifyListeners();
  }

  Future<void> _drop(String id) async {
    _pending.removeWhere((b) => b['id'] == id);
    await _save();
  }

  Future<void> _save() async {
    await _prefs.setString(_key, jsonEncode(_pending));
    notifyListeners();
  }
}
