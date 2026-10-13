import 'package:flutter_test/flutter_test.dart';
import 'package:heardy/services/legal_texts.dart';

void main() {
  test('sin versión aceptada hay que pedir aceptación', () {
    expect(needsLegalAcceptance(null), isTrue);
  });

  test('una versión anterior vuelve a pedirla; la vigente no', () {
    expect(needsLegalAcceptance('2000-01-01'), isTrue);
    expect(needsLegalAcceptance(legalVersion), isFalse);
  });

  test('los textos no nombran plataformas de origen', () {
    final all = [...termsSections, ...privacySections].map((s) => '${s.title} ${s.body}').join(' ').toLowerCase();
    expect(all.contains('youtube'), isFalse);
    expect(all.contains('spotify'), isFalse);
  });

  String bodyOf(String prefix) =>
      termsSections.firstWhere((s) => s.title.startsWith(prefix)).body;

  test('la versión tiene formato de fecha y fue subida a 2026-10-13', () {
    expect(RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(legalVersion), isTrue);
    expect(legalVersion, '2026-10-13');
  });

  test('la sección 9 trata el retiro y cita el correo de contacto', () {
    final s9 = termsSections.firstWhere((s) => s.title.startsWith('9. '));
    expect(s9.title.toLowerCase(), contains('retiro'));
    expect(s9.body, contains(legalContactEmail));
  });

  test('la sección 2 ya no niega que el operador transmita y describe el servidor', () {
    final s2 = bodyOf('2. ');
    expect(s2.contains('transmite'), isFalse);
    expect(s2, contains('caché técnica temporal'));
  });

  test('la licencia es GPL-3.0 y ya no se menciona MIT', () {
    final all = termsSections.map((s) => '${s.title} ${s.body}').join(' ');
    expect(all, contains('GPL-3.0'));
    expect(all.contains('MIT'), isFalse);
  });
}
