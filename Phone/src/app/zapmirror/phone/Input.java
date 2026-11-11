package app.zapmirror.phone;

import android.os.SystemClock;
import android.view.InputDevice;
import android.view.InputEvent;
import android.view.KeyCharacterMap;
import android.view.KeyEvent;
import android.view.MotionEvent;

import java.lang.reflect.Method;

/** Turns the Mac's touches, scrolls, keys and text into Android input events on display 0. */
final class Input {
    private static final int INJECT_ASYNC = 0;
    private static final int FINGERS = 2;

    private final Object manager;
    private final Method inject;
    private final KeyCharacterMap characters = KeyCharacterMap.load(KeyCharacterMap.VIRTUAL_KEYBOARD);

    private final boolean[] fingerDown = new boolean[FINGERS];
    private final MotionEvent.PointerCoords[] fingerAt = new MotionEvent.PointerCoords[FINGERS];
    private long touchStarted;

    Input() throws Exception {
        Class<?> type;
        try {
            type = Class.forName("android.hardware.input.InputManagerGlobal"); // Android 14+
        } catch (ClassNotFoundException e) {
            type = Class.forName("android.hardware.input.InputManager");
        }
        manager = type.getMethod("getInstance").invoke(null);
        inject = type.getMethod("injectInputEvent", InputEvent.class, int.class);
        for (int i = 0; i < FINGERS; i++) fingerAt[i] = new MotionEvent.PointerCoords();
    }

    private void inject(InputEvent event) {
        try {
            if (!(Boolean) inject.invoke(manager, event, INJECT_ASYNC)) Log.i("Android refused " + event);
        } catch (Exception e) {
            Log.w("couldn't inject input", e);
        }
    }

    // Keys and text

    void key(int action, int keycode, int metaState, int repeat) {
        long now = SystemClock.uptimeMillis();
        inject(new KeyEvent(now, now, action, keycode, repeat, metaState, KeyCharacterMap.VIRTUAL_KEYBOARD, 0, 0,
                InputDevice.SOURCE_KEYBOARD));
    }

    void press(int keycode) {
        key(KeyEvent.ACTION_DOWN, keycode, 0, 0);
        key(KeyEvent.ACTION_UP, keycode, 0, 0);
    }

    /** Types `text` as key presses; text the virtual keyboard can't produce (emoji, most accents) is pasted. */
    void type(String text) {
        KeyEvent[] events = characters.getEvents(text.toCharArray());
        if (events == null) {
            Phone.setClipboard(text, true);
            press(KeyEvent.KEYCODE_PASTE);
            return;
        }
        for (KeyEvent event : events) inject(event);
    }

    // Touch

    /** `action`: 0 down, 1 move, 2 up. `x` and `y` are fractions of the screen. */
    void touch(int action, int finger, float x, float y, float pressure) throws Exception {
        if (finger < 0 || finger >= FINGERS) return;
        Screen.Display display = Screen.current();
        MotionEvent.PointerCoords at = fingerAt[finger];
        at.x = clamp(x) * (display.width - 1);
        at.y = clamp(y) * (display.height - 1);
        at.pressure = pressure;
        at.size = 1;

        int down = 0;
        for (boolean d : fingerDown) if (d) down++;
        int motion;
        if (action == 0) {
            if (fingerDown[finger]) return;
            fingerDown[finger] = true;
            if (down == 0) {
                touchStarted = SystemClock.uptimeMillis();
                motion = MotionEvent.ACTION_DOWN;
            } else {
                motion = MotionEvent.ACTION_POINTER_DOWN | (indexOf(finger) << MotionEvent.ACTION_POINTER_INDEX_SHIFT);
            }
        } else if (action == 1) {
            if (!fingerDown[finger]) return;
            motion = MotionEvent.ACTION_MOVE;
        } else {
            if (!fingerDown[finger]) return;
            motion = down == 1 ? MotionEvent.ACTION_UP
                    : MotionEvent.ACTION_POINTER_UP | (indexOf(finger) << MotionEvent.ACTION_POINTER_INDEX_SHIFT);
        }
        injectFingers(motion);
        if (action == 2) fingerDown[finger] = false;
    }

    /** The position of `finger` among the fingers that are down. */
    private int indexOf(int finger) {
        int index = 0;
        for (int i = 0; i < finger; i++) if (fingerDown[i]) index++;
        return index;
    }

    private void injectFingers(int motion) {
        int count = 0;
        for (boolean d : fingerDown) if (d) count++;
        MotionEvent.PointerProperties[] properties = new MotionEvent.PointerProperties[count];
        MotionEvent.PointerCoords[] coords = new MotionEvent.PointerCoords[count];
        for (int finger = 0, n = 0; finger < FINGERS; finger++) {
            if (!fingerDown[finger]) continue;
            properties[n] = new MotionEvent.PointerProperties();
            properties[n].id = finger;
            properties[n].toolType = MotionEvent.TOOL_TYPE_FINGER;
            coords[n] = fingerAt[finger];
            n++;
        }
        MotionEvent event = MotionEvent.obtain(touchStarted, SystemClock.uptimeMillis(), motion, count, properties,
                coords, 0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0);
        inject(event);
        event.recycle();
    }

    /** A mouse wheel at (`x`, `y`): positive `horizontal` scrolls right, positive `vertical` up. */
    void scroll(float x, float y, float horizontal, float vertical) throws Exception {
        Screen.Display display = Screen.current();
        MotionEvent.PointerProperties properties = new MotionEvent.PointerProperties();
        properties.toolType = MotionEvent.TOOL_TYPE_MOUSE;
        MotionEvent.PointerCoords at = new MotionEvent.PointerCoords();
        at.x = clamp(x) * (display.width - 1);
        at.y = clamp(y) * (display.height - 1);
        at.setAxisValue(MotionEvent.AXIS_HSCROLL, horizontal);
        at.setAxisValue(MotionEvent.AXIS_VSCROLL, vertical);
        long now = SystemClock.uptimeMillis();
        MotionEvent event = MotionEvent.obtain(now, now, MotionEvent.ACTION_SCROLL, 1,
                new MotionEvent.PointerProperties[] {properties}, new MotionEvent.PointerCoords[] {at},
                0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_MOUSE, 0);
        inject(event);
        event.recycle();
    }

    private static float clamp(float f) {
        return Float.isNaN(f) ? 0 : Math.max(0, Math.min(1, f));
    }
}
