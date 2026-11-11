package app.zapmirror.phone;

import android.media.AudioFormat;
import android.media.AudioRecord;
import android.media.MediaRecorder;
import android.os.Build;

import java.io.IOException;

/**
 * Streams what the phone is playing as raw PCM. Android's remote submix source taps the output mix; while it's being
 * captured, the phone's own speaker goes quiet.
 */
final class Sound {
    static final int RATE = 48_000;
    static final int CHANNELS = 2;

    private Sound() {}

    static void stream(Channel audio) throws IOException {
        AudioRecord record;
        try {
            record = open();
            record.startRecording();
            if (record.getRecordingState() != AudioRecord.RECORDSTATE_RECORDING) {
                record.release();
                throw new IllegalStateException("recording didn't start");
            }
        } catch (Throwable e) {
            Log.w("no sound", e);
            audio.sendText('E', Log.describe(e));
            return;
        }
        audio.sendText('I', "{\"encoding\":\"pcm16le\",\"rate\":" + RATE + ",\"channels\":" + CHANNELS + "}");
        Log.i("sound " + RATE + " Hz");
        byte[] buffer = new byte[RATE / 100 * CHANNELS * 2]; // 10 ms
        try {
            while (true) {
                int count = record.read(buffer, 0, buffer.length);
                if (count < 0) throw new IOException("AudioRecord.read returned " + count);
                if (count > 0) audio.send('S', buffer, 0, count);
            }
        } finally {
            record.stop();
            record.release();
        }
    }

    private static AudioRecord open() throws Exception {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            throw new UnsupportedOperationException("Android 11 or later is needed to share the phone's sound");
        }
        int channelMask = AudioFormat.CHANNEL_IN_STEREO;
        int encoding = AudioFormat.ENCODING_PCM_16BIT;
        AudioFormat format = new AudioFormat.Builder()
                .setSampleRate(RATE).setChannelMask(channelMask).setEncoding(encoding).build();
        int minimum = AudioRecord.getMinBufferSize(RATE, channelMask, encoding);
        AudioRecord.Builder builder = new AudioRecord.Builder()
                .setAudioSource(MediaRecorder.AudioSource.REMOTE_SUBMIX)
                .setAudioFormat(format)
                .setBufferSizeInBytes(Math.max(minimum * 4, RATE / 10 * CHANNELS * 2)); // ≥ 100 ms
        // Android 12+ checks the recording permission against the context's package: the shell's.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) builder.setContext(ShellContext.INSTANCE);
        return builder.build();
    }
}
