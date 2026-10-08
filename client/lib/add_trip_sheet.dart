import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'api.dart';
import 'format.dart';
import 'outbox.dart';

/// Подсказка для комиссии: подставляем, пока водитель не ввёл свою.
const defaultCommissionPercent = 15;

class AddTripSheet extends StatefulWidget {
  const AddTripSheet({super.key, required this.outbox, required this.day, this.start, this.end});

  final Outbox outbox;
  final DateTime day;
  final TimeOfDay? start;
  final TimeOfDay? end;

  @override
  State<AddTripSheet> createState() => _AddTripSheetState();
}

class _AddTripSheetState extends State<AddTripSheet> {
  // Один id на всю жизнь формы: и повторное «Сохранить», и отправка из очереди — та же поездка.
  final _id = newTripId();
  final _amount = TextEditingController();
  final _commission = TextEditingController();
  bool _commissionTouched = false;

  late DateTime _date = widget.day;
  late TimeOfDay? _start = widget.start;
  late TimeOfDay? _end = widget.end;
  bool _endsNextDay = false;
  Payment _payment = Payment.card;

  List<String> _errors = [];
  bool _saving = false;

  @override
  void dispose() {
    _amount.dispose();
    _commission.dispose();
    super.dispose();
  }

  void _onAmountChanged(String v) {
    if (_commissionTouched) return;
    final amount = int.tryParse(v);
    _commission.text = amount == null ? '' : '${amount * defaultCommissionPercent ~/ 100}';
  }

  Future<void> _pickTime(bool isStart) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: (isStart ? _start : _end) ?? _start ?? TimeOfDay.now(),
    );
    if (picked == null) return;
    setState(() {
      if (isStart) {
        _start = picked;
      } else {
        _end = picked;
      }
    });
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => _date = picked);
  }

  DateTime _at(TimeOfDay t, {int plusDays = 0}) =>
      DateTime(_date.year, _date.month, _date.day + plusDays, t.hour, t.minute);

  /// Те же правила, что на сервере: ловим очевидное до отправки.
  /// Сервер всё равно проверяет сам — клиенту он не доверяет.
  (NewTrip?, List<String>) _validate() {
    final errors = <String>[];
    final amount = int.tryParse(_amount.text);
    final commission = int.tryParse(_commission.text);
    if (_start == null) errors.add('Укажите время начала');
    if (_end == null) errors.add('Укажите время окончания');
    if (amount == null || amount <= 0) errors.add('Сумма должна быть больше нуля');
    if (commission == null || commission < 0) {
      errors.add('Комиссия — целое число, не меньше нуля');
    } else if (amount != null && commission > amount) {
      errors.add('Комиссия не может быть больше суммы поездки');
    }
    if (_start != null && _end != null) {
      final start = _at(_start!);
      final end = _at(_end!, plusDays: _endsNextDay ? 1 : 0);
      if (!end.isAfter(start)) {
        errors.add('Окончание поездки должно быть позже начала. '
            'Если поездка закончилась после полуночи — включите переключатель.');
      }
      if (errors.isEmpty) {
        return (
          NewTrip(start: start, end: end, amount: amount!, payment: _payment, commission: commission!),
          errors,
        );
      }
    }
    return (null, errors);
  }

  Future<void> _save() async {
    final (trip, errors) = _validate();
    setState(() => _errors = errors);
    if (trip == null) return;
    setState(() => _saving = true);
    try {
      final result = await widget.outbox.submit(_id, trip);
      if (mounted) Navigator.of(context).pop(result);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _errors = e.messages;
          _saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final digits = [FilteringTextInputFormatter.digitsOnly];
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Новая поездка', style: theme.textTheme.titleLarge),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _pickDate,
            icon: const Icon(Icons.calendar_today, size: 18),
            label: Text(dayTitle(_date)),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                key: const Key('start'),
                onPressed: () => _pickTime(true),
                child: Text(_start == null ? 'Начало' : 'с ${_start!.format(context)}'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton(
                key: const Key('end'),
                onPressed: () => _pickTime(false),
                child: Text(_end == null ? 'Окончание' : 'до ${_end!.format(context)}'),
              ),
            ),
          ]),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Закончилась после полуночи'),
            value: _endsNextDay,
            onChanged: (v) => setState(() => _endsNextDay = v),
          ),
          TextField(
            key: const Key('amount'),
            controller: _amount,
            keyboardType: TextInputType.number,
            inputFormatters: digits,
            decoration: const InputDecoration(labelText: 'Сумма', suffixText: '₸', border: OutlineInputBorder()),
            onChanged: _onAmountChanged,
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('commission'),
            controller: _commission,
            keyboardType: TextInputType.number,
            inputFormatters: digits,
            decoration: const InputDecoration(
              labelText: 'Комиссия',
              suffixText: '₸',
              helperText: 'По умолчанию $defaultCommissionPercent% от суммы',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => _commissionTouched = true,
          ),
          const SizedBox(height: 12),
          SegmentedButton<Payment>(
            segments: const [
              ButtonSegment(value: Payment.card, label: Text('Карта'), icon: Icon(Icons.credit_card)),
              ButtonSegment(value: Payment.cash, label: Text('Наличные'), icon: Icon(Icons.payments_outlined)),
            ],
            selected: {_payment},
            onSelectionChanged: (s) => setState(() => _payment = s.first),
          ),
          if (_errors.isNotEmpty) ...[
            const SizedBox(height: 12),
            for (final e in _errors)
              Text(e, style: TextStyle(color: theme.colorScheme.error)),
          ],
          const SizedBox(height: 16),
          FilledButton(
            key: const Key('save'),
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Сохранить'),
          ),
        ]),
      ),
    );
  }
}
