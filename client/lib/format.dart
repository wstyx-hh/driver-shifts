import 'package:intl/intl.dart';

final _money = NumberFormat.decimalPattern('ru');

String money(int tenge) => '${_money.format(tenge)} ₸';

String duration(int minutes) {
  if (minutes < 60) return '$minutes мин';
  final m = minutes % 60;
  return m == 0 ? '${minutes ~/ 60} ч' : '${minutes ~/ 60} ч $m мин';
}

String dayTitle(DateTime d) => DateFormat('d MMMM, EEEE', 'ru').format(d);

String dayShort(DateTime d) => DateFormat('d MMM', 'ru').format(d);

String trips(int n) {
  final mod10 = n % 10, mod100 = n % 100;
  final word = mod10 == 1 && mod100 != 11
      ? 'поездка'
      : mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)
          ? 'поездки'
          : 'поездок';
  return '$n $word';
}
