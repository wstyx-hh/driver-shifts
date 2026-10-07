import 'package:flutter/material.dart';

import 'add_trip_sheet.dart';
import 'api.dart';
import 'format.dart';

class DayScreen extends StatefulWidget {
  const DayScreen({super.key, required this.api, this.initialDay});

  final Api api;

  /// Если не задан — открываем последний день, где есть поездки.
  final DateTime? initialDay;

  @override
  State<DayScreen> createState() => _DayScreenState();
}

class _DayScreenState extends State<DayScreen> {
  DateTime? _day;
  List<DayInfo> _days = [];
  DayReport? _report;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      _days = await widget.api.days();
    } on ApiException catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
      return;
    }
    final now = DateTime.now();
    await _open(widget.initialDay ?? (_days.isEmpty ? DateTime(now.year, now.month, now.day) : _days.last.date));
  }

  Future<void> _open(DateTime day) async {
    setState(() {
      _day = day;
      _loading = true;
      _error = null;
    });
    try {
      final report = await widget.api.day(day);
      if (!mounted || _day != day) return; // пока грузили, водитель уже листнул дальше
      setState(() {
        _report = report;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted || _day != day) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _pickDay() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _day!,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked != null) _open(picked);
  }

  Future<void> _addTrip() async {
    final result = await showModalBottomSheet<AddResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => AddTripSheet(api: widget.api, day: _day ?? DateTime.now()),
    );
    if (result == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(result.created ? 'Поездка добавлена' : 'Такая поездка уже записана — дубль не создан'),
    ));
    // Поездка уже сохранена. Если сервер пропал сразу после этого, кнопки дней
    // останутся старыми, а ошибку покажет _open — без необработанного исключения.
    try {
      _days = await widget.api.days();
    } on ApiException {
      // кнопки дней обновятся при следующей удачной загрузке
    }
    await _open(DateTime.parse(result.trip.startRaw.substring(0, 10)));
  }

  @override
  Widget build(BuildContext context) {
    final day = _day;
    return Scaffold(
      appBar: AppBar(title: const Text('Дневник смен')),
      floatingActionButton: day == null
          ? null
          : FloatingActionButton.extended(
              onPressed: _addTrip,
              icon: const Icon(Icons.add),
              label: const Text('Поездка'),
            ),
      body: day == null
          ? _body()
          : Column(children: [
              _DaySwitcher(
                day: day,
                onPrev: () => _open(day.subtract(const Duration(days: 1))),
                onNext: () => _open(day.add(const Duration(days: 1))),
                onPick: _pickDay,
              ),
              if (_days.isNotEmpty) _DayChips(days: _days, selected: day, onTap: _open),
              const Divider(height: 1),
              Expanded(child: _body()),
            ]),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _day == null ? _start : () => _open(_day!),
              child: const Text('Повторить'),
            ),
          ]),
        ),
      );
    }
    final report = _report!;
    return RefreshIndicator(
      onRefresh: () => _open(_day!),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          _SummaryCard(summary: report.summary),
          const SizedBox(height: 16),
          if (report.trips.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(child: Text('В этот день поездок нет')),
            )
          else ...[
            Text('Поездки', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            for (final t in report.trips) _TripTile(trip: t),
          ],
        ],
      ),
    );
  }
}

class _DaySwitcher extends StatelessWidget {
  const _DaySwitcher({required this.day, required this.onPrev, required this.onNext, required this.onPick});

  final DateTime day;
  final VoidCallback onPrev, onNext, onPick;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Row(children: [
        IconButton(onPressed: onPrev, icon: const Icon(Icons.chevron_left), tooltip: 'Предыдущий день'),
        Expanded(
          child: TextButton.icon(
            onPressed: onPick,
            icon: const Icon(Icons.calendar_today, size: 18),
            label: Text(dayTitle(day), style: Theme.of(context).textTheme.titleMedium),
          ),
        ),
        IconButton(onPressed: onNext, icon: const Icon(Icons.chevron_right), tooltip: 'Следующий день'),
      ]),
    );
  }
}

/// Быстрый переход по дням, где были поездки: стрелки идут по календарю,
/// а выходные без работы так проскакивать удобнее.
class _DayChips extends StatelessWidget {
  const _DayChips({required this.days, required this.selected, required this.onTap});

  final List<DayInfo> days;
  final DateTime selected;
  final ValueChanged<DateTime> onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        reverse: true, // свежие дни справа и видны сразу
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (final d in days.reversed)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: ChoiceChip(
                label: Text('${dayShort(d.date)} · ${d.tripsCount}'),
                selected: DateUtils.isSameDay(d.date, selected),
                onSelected: (_) => onTap(d.date),
              ),
            ),
        ],
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.summary});

  final DaySummary summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = summary;
    return Card(
      elevation: 0,
      color: theme.colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('На руки', style: theme.textTheme.labelLarge),
          Text(
            money(s.net),
            key: const Key('net'),
            style: theme.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w600),
          ),
          Text('${trips(s.tripsCount)} · ${duration(s.minutesOnTrips)} в пути', style: theme.textTheme.bodyMedium),
          const SizedBox(height: 16),
          Row(children: [
            _Figure('Выручка', money(s.revenue)),
            _Figure('Комиссия', '−${money(s.commission)}'),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            _Figure('Наличные', money(s.cash.amount), note: trips(s.cash.count), icon: Icons.payments_outlined),
            _Figure('Карта', money(s.card.amount), note: trips(s.card.count), icon: Icons.credit_card),
          ]),
        ]),
      ),
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure(this.label, this.value, {this.note, this.icon});

  final String label, value;
  final String? note;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          if (icon != null) ...[Icon(icon, size: 16), const SizedBox(width: 4)],
          Text(label, style: theme.textTheme.labelMedium),
        ]),
        Text(value, style: theme.textTheme.titleMedium),
        if (note != null) Text(note!, style: theme.textTheme.bodySmall),
      ]),
    );
  }
}

class _TripTile extends StatelessWidget {
  const _TripTile({required this.trip});

  final Trip trip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cash = trip.payment == Payment.cash;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        child: Icon(cash ? Icons.payments_outlined : Icons.credit_card, size: 20),
      ),
      title: Text('${trip.startClock} – ${trip.endClock}${trip.endsNextDay ? ' (+1)' : ''}'),
      subtitle: Text('${duration(trip.minutes)} · ${cash ? 'наличные' : 'карта'}'),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(money(trip.amount), style: theme.textTheme.titleMedium),
          Text('−${money(trip.commission)}', style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}
