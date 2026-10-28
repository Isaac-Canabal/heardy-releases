package com.ryanheise.just_audio;

import androidx.annotation.NonNull;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodChannel.Result;
import java.util.List;

/**
 * Parámetros compartidos del ecualizador de Heardy (fork local de just_audio).
 *
 * El hilo principal escribe con {@link #configure}; cada {@link EqualizerAudioProcessor} compara
 * {@link #version()} al empezar un buffer y sólo copia los valores cuando cambiaron.
 */
public final class HeardyEqualizer {
    public static final String CHANNEL = "heardy/equalizer";
    public static final int BAND_COUNT = 10;
    public static final double[] BAND_FREQUENCIES_HZ = {
        31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000
    };
    public static final double MIN_GAIN_DB = -12;
    public static final double MAX_GAIN_DB = 12;
    public static final double MIN_PREAMP_DB = -24;
    public static final double MAX_PREAMP_DB = 0;

    private static final Object lock = new Object();
    private static final double[] gainsDb = new double[BAND_COUNT];
    private static boolean enabled;
    private static double preampDb;
    private static volatile int version;

    private HeardyEqualizer() {}

    /** Valores ya acotados; el arreglo de ganancias debe tener {@link #BAND_COUNT} elementos. */
    public static void configure(boolean enabled, double preampDb, @NonNull double[] gainsDb) {
        if (gainsDb.length != BAND_COUNT) {
            throw new IllegalArgumentException("gainsDb debe tener " + BAND_COUNT + " valores");
        }
        synchronized (lock) {
            HeardyEqualizer.enabled = enabled;
            HeardyEqualizer.preampDb = clamp(preampDb, MIN_PREAMP_DB, MAX_PREAMP_DB);
            for (int i = 0; i < BAND_COUNT; i++) {
                HeardyEqualizer.gainsDb[i] = clamp(gainsDb[i], MIN_GAIN_DB, MAX_GAIN_DB);
            }
            version++;
        }
    }

    public static int version() {
        return version;
    }

    /** Copia los parámetros actuales en {@code out} sin asignar memoria y devuelve su versión. */
    static int copyTo(@NonNull Params out) {
        synchronized (lock) {
            out.enabled = enabled;
            out.preampDb = preampDb;
            System.arraycopy(gainsDb, 0, out.gainsDb, 0, BAND_COUNT);
            return version;
        }
    }

    static final class Params {
        boolean enabled;
        double preampDb;
        final double[] gainsDb = new double[BAND_COUNT];
    }

    private static double clamp(double value, double min, double max) {
        if (Double.isNaN(value)) return 0;
        return Math.max(min, Math.min(max, value));
    }

    static final class MethodHandler implements MethodChannel.MethodCallHandler {
        @Override
        public void onMethodCall(@NonNull MethodCall call, @NonNull Result result) {
            if (!"configure".equals(call.method)) {
                result.notImplemented();
                return;
            }
            Object enabledArg = call.argument("enabled");
            Object preampArg = call.argument("preampDb");
            Object gainsArg = call.argument("gainsDb");
            if (!(enabledArg instanceof Boolean) || !(preampArg instanceof Number)
                    || !(gainsArg instanceof List) || ((List<?>) gainsArg).size() != BAND_COUNT) {
                result.error("bad_args",
                        "configure espera {enabled: bool, preampDb: double, gainsDb: List<double>("
                                + BAND_COUNT + ")}",
                        null);
                return;
            }
            List<?> gainsList = (List<?>) gainsArg;
            double[] gains = new double[BAND_COUNT];
            for (int i = 0; i < BAND_COUNT; i++) {
                Object gain = gainsList.get(i);
                if (!(gain instanceof Number)) {
                    result.error("bad_args", "gainsDb[" + i + "] no es un número", null);
                    return;
                }
                gains[i] = ((Number) gain).doubleValue();
            }
            configure((Boolean) enabledArg, ((Number) preampArg).doubleValue(), gains);
            result.success(true);
        }
    }
}
