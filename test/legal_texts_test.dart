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

  String privacyAll() => privacySections.map((s) => '${s.title} ${s.body}').join(' ');
  String termsAll() => termsSections.map((s) => '${s.title} ${s.body}').join(' ');

  test('los términos ya no imponen arbitraje ni renuncian a acciones de grupo', () {
    final t = termsAll().toLowerCase();
    expect(t.contains('arbitraje'), isFalse);
    expect(t.contains('cámara de comercio'), isFalse);
    expect(t.contains('acciones colectivas'), isFalse);
    expect(bodyOf('11. '), contains('Superintendencia de Industria y Comercio'));
  });

  test('la indemnidad es acotada, excluye dolo o culpa grave y a los menores', () {
    final s8 = bodyOf('8. ');
    expect(s8.contains('cualquier sanción'), isFalse);
    expect(s8, contains('razonables y documentados'));
    expect(s8, contains('dolo o culpa grave'));
    expect(s8, contains('menores'));
  });

  test('el retiro de contenido no se presenta como obligación legal y conserva los plazos', () {
    final s9 = bodyOf('9. ');
    expect(s9.contains('1915'), isFalse);
    expect(s9, contains('compromiso voluntario'));
    expect(s9, contains('tres (3) días hábiles'));
    expect(s9, contains('cinco (5) días hábiles'));
  });

  test('los términos no dicen que el operador no controle ni que no aloje', () {
    final t = termsAll();
    expect(t.contains('no selecciona, controla'), isFalse);
    expect(t.contains('no lo aloja'), isFalse);
    expect(bodyOf('3. '), contains('no revisa previamente'));
  });

  test('la privacidad describe la caché en vez de negar que haya audio', () {
    final p = privacyAll();
    expect(p.contains('ni audio'), isFalse);
    expect(p.contains('no almacena'), isFalse);
    final s10 = privacySections.firstWhere((s) => s.title.startsWith('10. ')).body;
    expect(s10, contains('caché técnica de tamaño limitado'));
    expect(s10, contains('no vinculada a tu cuenta'));
  });

  test('la privacidad de la app declara las mismas conexiones a terceros que la web', () {
    final p = privacyAll();
    for (final tercero in ['GitHub', 'LRCLIB', 'NetEase', 'MyMemory', 'yt-dlp']) {
      expect(p, contains(tercero));
    }
    expect(p, contains('Uso de Explorar, importar y buscar'));
    expect(p, contains('dejara de prestarse'));
  });
}
