import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  // Шаблон Flutter кладёт INTERNET только в debug-манифест: в эмуляторе всё
  // работает, а у водителя релизный APK молча не видит сервер.
  test('релизный APK может ходить в сеть', () {
    final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    expect(manifest, contains('android.permission.INTERNET'));
    // Пока демо-сервер без HTTPS, Android 9+ без этого флага режет http://.
    expect(manifest, contains('android:usesCleartextTraffic="true"'));
  });
}
