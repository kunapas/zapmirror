package app.zapmirror.phone;

import android.graphics.Rect;
import android.hardware.display.DisplayManager;
import android.hardware.display.VirtualDisplay;
import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaFormat;
import android.os.Build;
import android.os.Bundle;
import android.os.IBinder;
import android.os.SystemClock;
import android.view.Surface;

import java.io.IOException;
import java.nio.ByteBuffer;

/**
 * Streams the phone's screen as H.264: a mirror of display 0 drawn into a hardware encoder's input surface. When the
 * phone rotates, the encoder is rebuilt at the new size.
 */
final class Screen {
    private Screen() {}

    /** Display 0 as it is now: logical size (in the current rotation), rotation, and layer stack. */
    static final class Display {
        final int width, height, rotation, layerStack;

        Display(int width, int height, int rotation, int layerStack) {
            this.width = width;
            this.height = height;
            this.rotation = rotation;
            this.layerStack = layerStack;
        }

        boolean sameSize(Display other) {
            return other != null && width == other.width && height == other.height;
        }
    }

    private static volatile Display current;
    private static volatile boolean keyFrameWanted;

    /** The Mac wants a frame it can start from (it began recording): the encoder sends one as its next frame. */
    static void requestKeyFrame() {
        keyFrameWanted = true;
    }

    /** The last display state the video thread saw; touches are scaled to it. */
    static Display current() throws Exception {
        Display display = current;
        return display != null ? display : read();
    }

    static Display read() throws Exception {
        Object global = Hidden.call(Class.forName("android.hardware.display.DisplayManagerGlobal"), "getInstance");
        Object info = Hidden.call(global, "getDisplayInfo", 0);
        if (info == null) throw new IllegalStateException("no display 0");
        Display display = new Display(Hidden.intField(info, "logicalWidth"), Hidden.intField(info, "logicalHeight"),
                Hidden.intField(info, "rotation"), Hidden.intField(info, "layerStack"));
        current = display;
        return display;
    }

    static void stream(Channel video, Main.Options options) throws Exception {
        video.sendText('I', "{\"name\":" + json(Build.MODEL) + ",\"manufacturer\":" + json(Build.MANUFACTURER)
                + ",\"android\":" + json(Build.VERSION.RELEASE) + "}");
        int maxSize = options.maxSize;
        while (true) {
            Display display = read();
            int[] size = videoSize(display, maxSize);
            MediaCodec codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC);
            try {
                codec.configure(format(size, options), null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
            } catch (RuntimeException e) {
                codec.release();
                // Some encoders refuse large sizes: step down until one fits.
                if (maxSize == 0 || maxSize > 1024) {
                    Log.w("encoder refused " + size[0] + "×" + size[1], e);
                    maxSize = maxSize == 0 ? 1920 : maxSize * 3 / 4;
                    continue;
                }
                throw e;
            }
            Surface surface = codec.createInputSurface();
            Mirror mirror = null;
            try {
                mirror = Mirror.create(display, size[0], size[1], surface);
                codec.start();
                video.send('D', ByteBuffer.allocate(8).putInt(size[0]).putInt(size[1]).array());
                Log.i("video " + size[0] + "×" + size[1] + " from " + display.width + "×" + display.height);
                encode(codec, video, display, mirror, surface);
            } finally {
                try {
                    codec.stop();
                } catch (RuntimeException ignored) {
                }
                codec.release();
                if (mirror != null) mirror.release();
                surface.release();
            }
        }
    }

    /** Sends encoded frames until the display changes size (returns) or the Mac goes away (throws). */
    private static void encode(MediaCodec codec, Channel video, Display display, Mirror mirror, Surface surface)
            throws Exception {
        MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
        ByteBuffer header = ByteBuffer.allocate(9);
        long lastCheck = SystemClock.uptimeMillis();
        while (true) {
            if (keyFrameWanted) {
                keyFrameWanted = false;
                Bundle now = new Bundle();
                now.putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0);
                codec.setParameters(now);
                // The encoder only makes a frame when the screen changes. A still screen would keep the Mac waiting,
                // so have the display drawn again.
                mirror.redraw(surface);
            }
            int index = codec.dequeueOutputBuffer(info, 50_000);
            if (index >= 0) {
                try {
                    ByteBuffer data = codec.getOutputBuffer(index);
                    if (data != null && info.size > 0) {
                        data.position(info.offset).limit(info.offset + info.size);
                        if ((info.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) {
                            video.send('C', new byte[0], data);
                        } else {
                            boolean key = (info.flags & MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0;
                            header.clear();
                            header.putLong(info.presentationTimeUs).put((byte) (key ? 1 : 0));
                            video.send('F', header.array(), data);
                        }
                    }
                } finally {
                    codec.releaseOutputBuffer(index, false);
                }
                if ((info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) throw new IOException("encoder stopped");
            }
            long now = SystemClock.uptimeMillis();
            if (now - lastCheck >= 250) {
                lastCheck = now;
                if (!display.sameSize(read())) return; // rotated, or the resolution changed
            }
        }
    }

    /** The display scaled so its longest side is at most `maxSize`, in multiples of 16 (what encoders like best). */
    static int[] videoSize(Display display, int maxSize) {
        double scale = maxSize > 0 ? Math.min(1.0, (double) maxSize / Math.max(display.width, display.height)) : 1.0;
        return new int[] {roundTo16(display.width * scale), roundTo16(display.height * scale)};
    }

    private static String json(String text) {
        StringBuilder out = new StringBuilder("\"");
        for (char c : (text == null ? "" : text).toCharArray()) {
            if (c == '"' || c == '\\') out.append('\\').append(c);
            else if (c < 0x20) out.append(String.format("\\u%04x", (int) c));
            else out.append(c);
        }
        return out.append('"').toString();
    }

    private static int roundTo16(double value) {
        return Math.max(16, (int) Math.round(value / 16) * 16);
    }

    private static MediaFormat format(int[] size, Main.Options options) {
        MediaFormat format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, size[0], size[1]);
        format.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface);
        format.setInteger(MediaFormat.KEY_BIT_RATE, options.bitRate);
        format.setInteger(MediaFormat.KEY_FRAME_RATE, options.fps);
        format.setFloat(MediaFormat.KEY_MAX_FPS_TO_ENCODER, options.fps);
        format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 10);
        // A still screen draws nothing; repeat the last frame so the Mac still gets fresh ones.
        format.setLong(MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER, 100_000);
        format.setInteger(MediaFormat.KEY_PRIORITY, 0); // real time
        return format;
    }

    /** A display that shows what display 0 shows, drawn into the encoder's surface. */
    private static final class Mirror {
        private final VirtualDisplay virtualDisplay;
        private final IBinder token;

        private Mirror(VirtualDisplay virtualDisplay, IBinder token) {
            this.virtualDisplay = virtualDisplay;
            this.token = token;
        }

        static Mirror create(Display display, int width, int height, Surface surface) throws Exception {
            // Android 12 and later: DisplayManager can mirror another display directly.
            try {
                VirtualDisplay virtualDisplay = (VirtualDisplay) DisplayManager.class
                        .getMethod("createVirtualDisplay", String.class, int.class, int.class, int.class, Surface.class)
                        .invoke(null, "Zapmirror", width, height, 0, surface);
                if (virtualDisplay != null) return new Mirror(virtualDisplay, null);
            } catch (NoSuchMethodException ignored) {
                // older Android
            } catch (Exception e) {
                Log.w("DisplayManager mirroring failed; trying SurfaceControl", e);
            }
            // Before that: a SurfaceControl display that shows display 0's layer stack.
            Class<?> sc = Class.forName("android.view.SurfaceControl");
            IBinder token = (IBinder) Hidden.call(sc, "createDisplay", "Zapmirror", false);
            Hidden.call(sc, "openTransaction");
            try {
                Hidden.call(sc, "setDisplaySurface", token, surface);
                Hidden.call(sc, "setDisplayProjection", token, 0, new Rect(0, 0, display.width, display.height),
                        new Rect(0, 0, width, height));
                Hidden.call(sc, "setDisplayLayerStack", token, display.layerStack);
            } finally {
                Hidden.call(sc, "closeTransaction");
            }
            return new Mirror(null, token);
        }

        /** Makes the system draw the mirrored display into `surface` again, which gives the encoder a new frame. */
        void redraw(Surface surface) {
            try {
                if (virtualDisplay != null) {
                    virtualDisplay.setSurface(null);
                    virtualDisplay.setSurface(surface);
                } else {
                    Class<?> sc = Class.forName("android.view.SurfaceControl");
                    Hidden.call(sc, "openTransaction");
                    try {
                        Hidden.call(sc, "setDisplaySurface", token, surface);
                    } finally {
                        Hidden.call(sc, "closeTransaction");
                    }
                }
            } catch (Exception e) {
                Log.w("couldn't redraw the mirror", e);
            }
        }

        void release() {
            if (virtualDisplay != null) {
                virtualDisplay.release();
                return;
            }
            try {
                Hidden.call(Class.forName("android.view.SurfaceControl"), "destroyDisplay", token);
            } catch (Exception e) {
                Log.w("couldn't remove the mirror display", e);
            }
        }
    }
}
