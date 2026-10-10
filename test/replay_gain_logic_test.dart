import 'package:flutter_test/flutter_test.dart';
import 'package:heardy/services/replay_gain_logic.dart';

void main() {
  group('parseReplayGainDb', () {
    test('lee valores con signo y sufijo dB', () {
      expect(parseReplayGainDb('-6.54 dB'), closeTo(-6.54, 1e-9));
      expect(parseReplayGainDb('+1.20 dB'), closeTo(1.2, 1e-9));
      expect(parseReplayGainDb('  -3.0dB '), closeTo(-3.0, 1e-9));
    });

    test('acepta coma decimal y minusculas', () {
      expect(parseReplayGainDb('-3,25 db'), closeTo(-3.25, 1e-9));
    });

    test('devuelve null con basura o vacio', () {
      expect(parseReplayGainDb(null), isNull);
      expect(parseReplayGainDb(''), isNull);
      expect(parseReplayGainDb('abc'), isNull);
      expect(parseReplayGainDb('nan dB'), isNull);
    });
  });

  group('replayGainFactor', () {
    test('atenua con ganancia negativa', () {
      expect(replayGainFactor(-6.0206), closeTo(0.5, 1e-3));
      expect(replayGainFactor(-20), closeTo(0.1, 1e-9));
    });

    test('nunca supera 1.0 aunque la ganancia sea positiva', () {
      expect(replayGainFactor(4.0), 1.0);
      expect(replayGainFactor(0), 1.0);
    });

    test('tiene un piso para no silenciar la pista', () {
      expect(replayGainFactor(-60), closeTo(0.1, 1e-9));
    });
  });

  group('pickTrackGainDb', () {
    test('prefiere la ganancia de pista sin importar mayusculas', () {
      final db = pickTrackGainDb({
        'replaygain_album_gain': '-2.0 dB',
        'ReplayGain_Track_Gain': '-5.5 dB',
      });
      expect(db, closeTo(-5.5, 1e-9));
    });

    test('cae a la de album si no hay de pista', () {
      expect(
        pickTrackGainDb({'REPLAYGAIN_ALBUM_GAIN': '-2.0 dB'}),
        closeTo(-2.0, 1e-9),
      );
    });

    test('sin etiquetas devuelve null', () {
      expect(pickTrackGainDb({'TITLE': 'x'}), isNull);
      expect(pickTrackGainDb({}), isNull);
    });
  });
}
