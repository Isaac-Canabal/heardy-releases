package com.ryanheise.just_audio;

import android.content.Context;
import androidx.media3.common.audio.AudioProcessor;
import androidx.media3.exoplayer.DefaultRenderersFactory;
import androidx.media3.exoplayer.audio.AudioSink;
import androidx.media3.exoplayer.audio.DefaultAudioSink;

/** Igual que el de Media3, pero con el {@link EqualizerAudioProcessor} de Heardy en el sink. */
final class HeardyRenderersFactory extends DefaultRenderersFactory {
    HeardyRenderersFactory(Context context) {
        super(context);
    }

    @Override
    protected AudioSink buildAudioSink(
            Context context, boolean enableFloatOutput, boolean enableAudioTrackPlaybackParams) {
        return new DefaultAudioSink.Builder(context)
                .setEnableFloatOutput(enableFloatOutput)
                .setEnableAudioTrackPlaybackParams(enableAudioTrackPlaybackParams)
                .setAudioProcessors(new AudioProcessor[] {new EqualizerAudioProcessor()})
                .build();
    }
}
