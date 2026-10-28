package com.ryanheise.just_audio;

import androidx.media3.common.C;
import androidx.media3.common.audio.BaseAudioProcessor;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.Arrays;

/**
 * Ecualizador gráfico de 10 bandas dentro de ExoPlayer: biquads peaking (RBJ cookbook) en
 * forma directa II transpuesta y en doble precisión, más un preamp lineal.
 *
 * Siempre está activo, aunque el ecualizador esté apagado o plano: así encender o apagar no obliga
 * a reconfigurar el AudioSink. En ese caso copia la entrada tal cual.
 */
public final class EqualizerAudioProcessor extends BaseAudioProcessor {
    private static final double Q = 1.41;
    private static final double MAX_BAND_FRACTION_OF_SAMPLE_RATE = 0.45;
    private static final int BANDS = HeardyEqualizer.BAND_COUNT;

    private final HeardyEqualizer.Params params = new HeardyEqualizer.Params();
    private final double[] b0 = new double[BANDS];
    private final double[] b1 = new double[BANDS];
    private final double[] b2 = new double[BANDS];
    private final double[] a1 = new double[BANDS];
    private final double[] a2 = new double[BANDS];
    private final int[] activeBands = new int[BANDS];
    private final boolean[] bandActive = new boolean[BANDS];
    private int activeBandCount;
    private double preampGain = 1;
    private boolean bypass = true;
    private int appliedVersion;
    private boolean paramsLoaded;

    private int sampleRate;
    private int channelCount;
    private int encoding;
    // Estado de los filtros, indexado [banda * canales + canal].
    private double[] z1 = new double[0];
    private double[] z2 = new double[0];

    @Override
    protected AudioFormat onConfigure(AudioFormat inputAudioFormat)
            throws UnhandledAudioFormatException {
        if (inputAudioFormat.encoding != C.ENCODING_PCM_16BIT
                && inputAudioFormat.encoding != C.ENCODING_PCM_FLOAT) {
            throw new UnhandledAudioFormatException(inputAudioFormat);
        }
        return inputAudioFormat;
    }

    @Override
    protected void onFlush() {
        // configure() sólo deja el formato pendiente; aquí ya es el formato en uso.
        if (inputAudioFormat.sampleRate != sampleRate
                || inputAudioFormat.channelCount != channelCount
                || inputAudioFormat.encoding != encoding) {
            sampleRate = inputAudioFormat.sampleRate;
            channelCount = inputAudioFormat.channelCount;
            encoding = inputAudioFormat.encoding;
            z1 = new double[BANDS * Math.max(channelCount, 0)];
            z2 = new double[BANDS * Math.max(channelCount, 0)];
            paramsLoaded = false;
        }
        clearState();
    }

    @Override
    protected void onReset() {
        sampleRate = 0;
        channelCount = 0;
        encoding = 0;
        z1 = new double[0];
        z2 = new double[0];
        paramsLoaded = false;
        bypass = true;
    }

    @Override
    public void queueInput(ByteBuffer inputBuffer) {
        int remaining = inputBuffer.remaining();
        if (remaining == 0) {
            return;
        }
        refreshParamsIfChanged();
        ByteBuffer output = replaceOutputBuffer(remaining);
        if (bypass || channelCount <= 0) {
            output.put(inputBuffer);
            output.flip();
            return;
        }
        ByteBuffer input = inputBuffer.order() == ByteOrder.nativeOrder()
                ? inputBuffer
                : inputBuffer.duplicate().order(ByteOrder.nativeOrder());
        int position = inputBuffer.position();
        int limit = inputBuffer.limit();
        if (encoding == C.ENCODING_PCM_FLOAT) {
            int frames = (limit - position) / (4 * channelCount);
            for (int f = 0; f < frames; f++) {
                for (int c = 0; c < channelCount; c++) {
                    double y = filter(input.getFloat(position) * preampGain, c);
                    output.putFloat((float) Math.max(-1.0, Math.min(1.0, y)));
                    position += 4;
                }
            }
        } else {
            int frames = (limit - position) / (2 * channelCount);
            for (int f = 0; f < frames; f++) {
                for (int c = 0; c < channelCount; c++) {
                    double y = filter(input.getShort(position) / 32768.0 * preampGain, c) * 32768.0;
                    long rounded = Math.round(y);
                    output.putShort((short) Math.max(Short.MIN_VALUE, Math.min(Short.MAX_VALUE, rounded)));
                    position += 2;
                }
            }
        }
        // Un frame incompleto (no debería llegar) se copia sin tocar para no perder bytes.
        while (position < limit) {
            output.put(input.get(position++));
        }
        inputBuffer.position(limit);
        output.flip();
    }

    private double filter(double x, int channel) {
        for (int i = 0; i < activeBandCount; i++) {
            int band = activeBands[i];
            int s = band * channelCount + channel;
            double y = b0[band] * x + z1[s];
            z1[s] = b1[band] * x - a1[band] * y + z2[s];
            z2[s] = b2[band] * x - a2[band] * y;
            x = y;
        }
        return x;
    }

    private void refreshParamsIfChanged() {
        if (paramsLoaded && HeardyEqualizer.version() == appliedVersion) {
            return;
        }
        appliedVersion = HeardyEqualizer.copyTo(params);
        paramsLoaded = true;
        boolean wasBypass = bypass;
        boolean anyGain = params.preampDb != 0;
        activeBandCount = 0;
        for (int band = 0; band < BANDS; band++) {
            double gainDb = params.gainsDb[band];
            double frequency = HeardyEqualizer.BAND_FREQUENCIES_HZ[band];
            boolean active = gainDb != 0
                    && sampleRate > 0
                    && frequency < MAX_BAND_FRACTION_OF_SAMPLE_RATE * sampleRate;
            if (gainDb != 0) {
                anyGain = true;
            }
            if (active) {
                computePeaking(band, frequency, gainDb);
                activeBands[activeBandCount++] = band;
            } else if (bandActive[band]) {
                // Una banda que se apaga no debe arrastrar estado viejo si luego se vuelve a encender.
                clearBandState(band);
            }
            bandActive[band] = active;
        }
        preampGain = Math.pow(10, params.preampDb / 20);
        bypass = !params.enabled || !anyGain;
        if (wasBypass && !bypass) {
            clearState();
        }
    }

    private void computePeaking(int band, double frequency, double gainDb) {
        double a = Math.pow(10, gainDb / 40);
        double w0 = 2 * Math.PI * frequency / sampleRate;
        double cosW0 = Math.cos(w0);
        double alpha = Math.sin(w0) / (2 * Q);
        double a0 = 1 + alpha / a;
        b0[band] = (1 + alpha * a) / a0;
        b1[band] = -2 * cosW0 / a0;
        b2[band] = (1 - alpha * a) / a0;
        a1[band] = -2 * cosW0 / a0;
        a2[band] = (1 - alpha / a) / a0;
    }

    private void clearState() {
        Arrays.fill(z1, 0);
        Arrays.fill(z2, 0);
    }

    private void clearBandState(int band) {
        for (int c = 0; c < channelCount; c++) {
            z1[band * channelCount + c] = 0;
            z2[band * channelCount + c] = 0;
        }
    }
}
