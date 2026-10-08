import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'api.dart';
import 'day_screen.dart';
import 'outbox.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('ru');
  final api = Api();
  runApp(DriverShiftsApp(api: api, outbox: await Outbox.open(api)));
}

class DriverShiftsApp extends StatelessWidget {
  const DriverShiftsApp({super.key, required this.api, required this.outbox, this.initialDay});

  final Api api;
  final Outbox outbox;
  final DateTime? initialDay;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Дневник смен',
      debugShowCheckedModeBanner: false,
      locale: const Locale('ru'),
      supportedLocales: const [Locale('ru')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(colorSchemeSeed: const Color(0xFF1B7F5B), useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: const Color(0xFF1B7F5B),
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: DayScreen(api: api, outbox: outbox, initialDay: initialDay),
    );
  }
}
