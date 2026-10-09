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
}
