package app.zapmirror.phone;

import android.content.ClipData;
import android.os.Binder;
import android.os.IBinder;
import android.os.Parcel;
import android.os.SystemClock;

import java.lang.reflect.InvocationHandler;
import java.lang.reflect.Method;
import java.lang.reflect.Proxy;
import java.util.ArrayList;
import java.util.List;

/**
 * The phone's system services: status bar panels, clipboard, screen power, rotation and staying awake. Everything
 * changed here is put back by {@link #restore} when the session ends.
 */
final class Phone {
    private static final String PACKAGE = ShellContext.PACKAGE;
    private static final int POWER_MODE_OFF = 0;
    private static final int POWER_MODE_NORMAL = 2;
    private static final int SCREEN_BRIGHT_WAKE_LOCK = 0x0000000a;

    private static volatile boolean screenTurnedOff;
    private static volatile Boolean rotationWasFrozen; // null until we lock the rotation
    private static volatile String lastFromMac;
    /** When the Mac last asked for a copy (uptime, ms). Clipboard changes reach the Mac only just after one. */
    private static volatile long copyRequested = Long.MIN_VALUE / 2;
    private static final long COPY_WINDOW_MS = 2_000;
    private static final int MAX_CLIPBOARD_CHARS = 1 << 20;

    private Phone() {}

    // Power

    static boolean isAwake() {
        try {
            return (Boolean) Hidden.call(Hidden.service("power", "android.os.IPowerManager"), "isInteractive");
        } catch (Exception e) {
            Log.w("couldn't tell whether the screen is on", e);
            return true;
        }
    }

    /** Keeps the screen on while mirroring. The lock belongs to this process, so Android drops it when we exit. */
    static void stayAwake() {
        try {
            Object power = Hidden.service("power", "android.os.IPowerManager");
            Hidden.call(power, "acquireWakeLock", new Binder(), SCREEN_BRIGHT_WAKE_LOCK, "Zapmirror:mirroring", PACKAGE);
        } catch (Exception e) {
            Log.w("couldn't keep the phone awake", e);
        }
    }

    /** Turns the phone's own screen off or on. The display keeps running, so mirroring carries on. */
    static void setScreenPower(boolean on) {
        try {
            Class<?> surfaceControl = Class.forName("android.view.SurfaceControl");
            List<IBinder> displays = physicalDisplays();
            for (IBinder display : displays) {
                Hidden.call(surfaceControl, "setDisplayPowerMode", display, on ? POWER_MODE_NORMAL : POWER_MODE_OFF);
            }
            screenTurnedOff = !on && !displays.isEmpty();
            Log.i("screen " + (on ? "on" : "off") + " (" + displays.size() + " display" + (displays.size() == 1 ? ")" : "s)"));
        } catch (Exception e) {
            Log.w("couldn't switch the screen " + (on ? "on" : "off"), e);
        }
    }

    private static ClassLoader displayControlLoader;

    private static List<IBinder> physicalDisplays() throws Exception {
        List<IBinder> tokens = new ArrayList<>();
        Class<?> surfaceControl = Class.forName("android.view.SurfaceControl");
        Class<?> lookup = surfaceControl;
        if (!Hidden.has(surfaceControl, "getPhysicalDisplayIds")) {
            // Android 14 moved the physical display list into the system server's DisplayControl, whose native
            // half lives in libandroid_servers.
            lookup = displayControl();
        }
        long[] ids = (long[]) Hidden.call(lookup, "getPhysicalDisplayIds");
        for (long id : ids) {
            IBinder token = (IBinder) Hidden.call(lookup, "getPhysicalDisplayToken", id);
            if (token != null) tokens.add(token);
        }
        return tokens;
    }

    private static synchronized Class<?> displayControl() throws Exception {
        if (displayControlLoader == null) {
            ClassLoader loader = new dalvik.system.PathClassLoader("/system/framework/services.jar",
                    ClassLoader.getSystemClassLoader());
            Class<?> type = loader.loadClass("com.android.server.display.DisplayControl");
            Method load = Runtime.class.getDeclaredMethod("loadLibrary0", Class.class, String.class);
            load.setAccessible(true);
            load.invoke(Runtime.getRuntime(), type, "android_servers");
            displayControlLoader = loader;
        }
        return displayControlLoader.loadClass("com.android.server.display.DisplayControl");
    }

    // Status bar

    /** 0 notifications, 1 quick settings, 2 close. */
    static void panel(int which) {
        try {
            Object bar = Hidden.service("statusbar", "com.android.internal.statusbar.IStatusBarService");
            Hidden.call(bar, which == 0 ? "expandNotificationsPanel" : which == 1 ? "expandSettingsPanel" : "collapsePanels");
        } catch (Exception e) {
            Log.w("couldn't open the panel", e);
        }
    }

    // Rotation

    /** Switches between portrait and landscape, locking the rotation there until the session ends. */
    static void rotate() {
        try {
            Object windows = Hidden.service("window", "android.view.IWindowManager");
            int target = Screen.read().rotation % 2 == 0 ? 1 : 0;
            if (rotationWasFrozen == null) rotationWasFrozen = rotationFrozen(windows);
            if (Hidden.has(windows.getClass(), "freezeDisplayRotation")) {
                Hidden.call(windows, "freezeDisplayRotation", 0, target, "Zapmirror"); // display 0, rotation
            } else {
                Hidden.call(windows, "freezeRotation", target, "Zapmirror");
            }
        } catch (Exception e) {
            Log.w("couldn't rotate", e);
        }
    }

    private static boolean rotationFrozen(Object windows) throws Exception {
        if (Hidden.has(windows.getClass(), "isDisplayRotationFrozen")) {
            return (Boolean) Hidden.call(windows, "isDisplayRotationFrozen", 0);
        }
        return (Boolean) Hidden.call(windows, "isRotationFrozen");
    }

    // Clipboard

    private static Object clipboard() throws Exception {
        return Hidden.service("clipboard", "android.content.IClipboard");
    }

    static String clipboardText() {
        try {
            ClipData clip = (ClipData) Hidden.call(clipboard(), "getPrimaryClip", PACKAGE);
            if (clip == null || clip.getItemCount() == 0) return null;
            CharSequence text = clip.getItemAt(0).getText();
            return text == null ? null : text.toString();
        } catch (Exception e) {
            Log.w("couldn't read the clipboard", e);
            return null;
        }
    }

    static void setClipboard(String text, boolean fromMac) {
        try {
            if (fromMac) lastFromMac = text;
            Hidden.call(clipboard(), "setPrimaryClip", ClipData.newPlainText("Zapmirror", text), PACKAGE);
        } catch (Exception e) {
            Log.w("couldn't set the clipboard", e);
        }
    }

    /** The Mac pressed Copy or Cut: the clipboard change that follows is its answer. */
    static void expectCopy() {
        copyRequested = SystemClock.uptimeMillis();
    }

    /**
     * Calls `changed` with the new text when the phone's clipboard changes because the Mac asked for a copy. Other
     * changes stay on the phone: what the user copies there (a password, say) is not the Mac's business, and an app
     * on the phone must not be able to replace the Mac's clipboard.
     * Android delivers the change to a binder object; a dynamic proxy stands in for the listener interface, which
     * isn't in the SDK.
     */
    interface ClipboardListener {
        void changed(String text);
    }

    static void watchClipboard(final ClipboardListener listener) {
        try {
            String descriptor = "android.content.IOnPrimaryClipChangedListener";
            Binder binder = new Binder() {
                @Override
                protected boolean onTransact(int code, Parcel data, Parcel reply, int flags) {
                    if (code != FIRST_CALL_TRANSACTION) return false;
                    if (SystemClock.uptimeMillis() - copyRequested > COPY_WINDOW_MS) return true;
                    copyRequested = Long.MIN_VALUE / 2;
                    String text = clipboardText();
                    if (text != null && text.length() <= MAX_CLIPBOARD_CHARS && !text.equals(lastFromMac)) {
                        listener.changed(text);
                    }
                    return true;
                }
            };
            binder.attachInterface(null, descriptor);
            Class<?> listenerType = Class.forName(descriptor);
            Object standIn = Proxy.newProxyInstance(listenerType.getClassLoader(), new Class<?>[] {listenerType},
                    new InvocationHandler() {
                        @Override
                        public Object invoke(Object proxy, Method method, Object[] args) {
                            switch (method.getName()) {
                                case "asBinder": return binder;
                                case "hashCode": return System.identityHashCode(proxy);
                                case "equals": return proxy == args[0];
                                case "toString": return "Zapmirror clipboard listener";
                                default: return null;
                            }
                        }
                    });
            Hidden.call(clipboard(), "addPrimaryClipChangedListener", standIn, PACKAGE);
        } catch (Exception e) {
            Log.w("couldn't watch the clipboard; ⌘C won't reach the Mac", e);
        }
    }

    // End of session

    static void restore() {
        if (screenTurnedOff) setScreenPower(true);
        Boolean wasFrozen = rotationWasFrozen;
        if (wasFrozen != null && !wasFrozen) {
            try {
                Object windows = Hidden.service("window", "android.view.IWindowManager");
                if (Hidden.has(windows.getClass(), "thawDisplayRotation")) {
                    Hidden.call(windows, "thawDisplayRotation", 0, "Zapmirror");
                } else {
                    Hidden.call(windows, "thawRotation", "Zapmirror");
                }
            } catch (Exception e) {
                Log.w("couldn't unlock the rotation", e);
            }
        }
    }
}
