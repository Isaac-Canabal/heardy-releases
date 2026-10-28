package com.ryanheise.just_audio;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

import androidx.media3.common.C;
import androidx.media3.common.audio.AudioProcessor;
import androidx.media3.common.audio.AudioProcessor.AudioFormat;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import org.junit.After;
import org.junit.Test;

public class EqualizerAudioProcessorTest {
    private static final int SAMPLE_RATE = 44100;
    private static final int CHANNELS = 2;
    private static final int FRAMES = SAMPLE_RATE;
    private static final double AMPLITUDE = 0.2;

    @After
    public void tearDown() {
        HeardyEqualizer.configure(false, 0, new double[HeardyEqualizer.BAND_COUNT]);
    }

    @Test
    public void boostAt62HzQuadruplesA62HzSineFloat() throws Exception {
        configureBand(1, 12);
        double ratio = rmsRatio(C.ENCODING_PCM_FLOAT, 62);
        assertEquals(3.98, ratio, 3.98 * 0.15);
    }

    @Test
    public void boostAt62HzQuadruplesA62HzSine16Bit() throws Exception {
        configureBand(1, 12);
        double ratio = rmsRatio(C.ENCODING_PCM_16BIT, 62);
        assertEquals(3.98, ratio, 3.98 * 0.15);
    }

    @Test
    public void boostAt62HzLeaves1kHzAlmostUntouched() throws Exception {
        configureBand(1, 12);
        double db = 20 * Math.log10(rmsRatio(C.ENCODING_PCM_FLOAT, 1000));
        assertTrue("1 kHz cambió " + db + " dB", Math.abs(db) <= 1.0);
    }

    @Test
    public void flatIsBitExact() throws Exception {
        HeardyEqualizer.configure(true, 0, new double[HeardyEqualizer.BAND_COUNT]);
        for (int encoding : new int[] {C.ENCODING_PCM_FLOAT, C.ENCODING_PCM_16BIT}) {
            ByteBuffer input = sine(encoding, 62);
            ByteBuffer output = process(encoding, input);
            input.rewind();
            assertEquals(input, output);
        }
    }

    @Test
    public void disabledIsBitExactEvenWithGains() throws Exception {
        double[] gains = new double[HeardyEqualizer.BAND_COUNT];
        gains[1] = 12;
        HeardyEqualizer.configure(false, -6, gains);
        ByteBuffer input = sine(C.ENCODING_PCM_16BIT, 62);
        ByteBuffer output = process(C.ENCODING_PCM_16BIT, input);
        input.rewind();
        assertEquals(input, output);
    }

    @Test
    public void preampMinus6dBHalvesAmplitude() throws Exception {
        HeardyEqualizer.configure(true, -6, new double[HeardyEqualizer.BAND_COUNT]);
        assertEquals(0.501, rmsRatio(C.ENCODING_PCM_FLOAT, 1000), 0.01);
        assertEquals(0.501, rmsRatio(C.ENCODING_PCM_16BIT, 1000), 0.01);
    }

    @Test
    public void outputIsClampedInsteadOfWrapping() throws Exception {
        configureBand(1, 12);
        ByteBuffer input = sine(C.ENCODING_PCM_16BIT, 62, 0.9);
        ByteBuffer output = process(C.ENCODING_PCM_16BIT, input);
        int max = 0;
        while (output.hasRemaining()) {
            max = Math.max(max, Math.abs((int) output.getShort()));
        }
        assertTrue(max >= 32767);
    }

    @Test
    public void processorIsActiveWhenDisabled() throws Exception {
        HeardyEqualizer.configure(false, 0, new double[HeardyEqualizer.BAND_COUNT]);
        EqualizerAudioProcessor processor = new EqualizerAudioProcessor();
        processor.configure(new AudioFormat(SAMPLE_RATE, CHANNELS, C.ENCODING_PCM_16BIT));
        processor.flush();
        assertTrue(processor.isActive());
    }

    @Test(expected = AudioProcessor.UnhandledAudioFormatException.class)
    public void rejectsUnsupportedEncoding() throws Exception {
        new EqualizerAudioProcessor()
                .configure(new AudioFormat(SAMPLE_RATE, CHANNELS, C.ENCODING_PCM_24BIT));
    }

    private static void configureBand(int band, double db) {
        double[] gains = new double[HeardyEqualizer.BAND_COUNT];
        gains[band] = db;
        HeardyEqualizer.configure(true, 0, gains);
    }

    private static double rmsRatio(int encoding, double frequency) throws Exception {
        ByteBuffer input = sine(encoding, frequency);
        ByteBuffer output = process(encoding, input);
        input.rewind();
        return rmsOfSecondHalf(encoding, output) / rmsOfSecondHalf(encoding, input);
    }

    private static ByteBuffer process(int encoding, ByteBuffer input) throws Exception {
        EqualizerAudioProcessor processor = new EqualizerAudioProcessor();
        processor.configure(new AudioFormat(SAMPLE_RATE, CHANNELS, encoding));
        processor.flush();
        ByteBuffer result = ByteBuffer.allocate(input.remaining()).order(ByteOrder.nativeOrder());
        // Bloques pequeños, como los entrega el sink, para que el estado de los filtros cruce buffers.
        int chunk = 4096;
        while (input.hasRemaining()) {
            ByteBuffer slice = input.duplicate().order(ByteOrder.nativeOrder());
            slice.limit(Math.min(input.limit(), input.position() + chunk));
            input.position(slice.limit());
            processor.queueInput(slice);
            result.put(processor.getOutput());
        }
        result.flip();
        return result;
    }

    private static ByteBuffer sine(int encoding, double frequency) {
        return sine(encoding, frequency, AMPLITUDE);
    }

    private static ByteBuffer sine(int encoding, double frequency, double amplitude) {
        int bytesPerSample = encoding == C.ENCODING_PCM_FLOAT ? 4 : 2;
        ByteBuffer buffer = ByteBuffer.allocateDirect(FRAMES * CHANNELS * bytesPerSample)
                .order(ByteOrder.nativeOrder());
        for (int i = 0; i < FRAMES; i++) {
            double value = amplitude * Math.sin(2 * Math.PI * frequency * i / SAMPLE_RATE);
            for (int c = 0; c < CHANNELS; c++) {
                if (encoding == C.ENCODING_PCM_FLOAT) {
                    buffer.putFloat((float) value);
                } else {
                    buffer.putShort((short) Math.round(value * 32767));
                }
            }
        }
        buffer.flip();
        return buffer;
    }

    private static double rmsOfSecondHalf(int encoding, ByteBuffer buffer) {
        ByteBuffer b = buffer.duplicate().order(ByteOrder.nativeOrder());
        int bytesPerSample = encoding == C.ENCODING_PCM_FLOAT ? 4 : 2;
        int samples = b.remaining() / bytesPerSample;
        double sum = 0;
        int count = 0;
        for (int i = 0; i < samples; i++) {
            double value = encoding == C.ENCODING_PCM_FLOAT
                    ? b.getFloat(i * 4)
                    : b.getShort(i * 2) / 32768.0;
            if (i >= samples / 2) {
                sum += value * value;
                count++;
            }
        }
        return Math.sqrt(sum / count);
    }
}
