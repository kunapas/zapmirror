package app.zapmirror.phone;

import android.os.IBinder;

import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.util.ArrayList;
import java.util.List;

/**
 * Reaches Android's non-public system APIs by reflection. The shell user may call them, but they aren't in the SDK, and
 * their parameter lists grow between Android versions; {@link #call} copes with that.
 */
final class Hidden {
    private Hidden() {}

    /** The client side of a system service, e.g. {@code service("clipboard", "android.content.IClipboard")}. */
    static Object service(String name, String aidlInterface) throws Exception {
        IBinder binder = (IBinder) Class.forName("android.os.ServiceManager")
                .getMethod("getService", String.class).invoke(null, name);
        if (binder == null) throw new IllegalStateException("no " + name + " service");
        return Class.forName(aidlInterface + "$Stub").getMethod("asInterface", IBinder.class).invoke(null, binder);
    }

    /**
     * Calls the method `name` on `target` (or, when `target` is a Class, its static method), filling the parameters by
     * type: each parameter takes the first unused value that fits it, and anything left over gets null, 0 or false.
     * So {@code call(clipboard, "getPrimaryClip", "com.android.shell")} works whether Android wants
     * (String package), (String package, int user) or (String package, String tag, int user, int device).
     * Among overloads, the one that uses the most values wins, then the shortest.
     */
    static Object call(Object target, String name, Object... values) throws Exception {
        Class<?> type = target instanceof Class ? (Class<?>) target : target.getClass();
        boolean statics = target instanceof Class;
        Method best = null;
        Object[] bestArguments = null;
        int bestUsed = -1;
        for (Method method : allMethods(type)) {
            if (!method.getName().equals(name) || Modifier.isStatic(method.getModifiers()) != statics) continue;
            boolean[] used = new boolean[values.length];
            Class<?>[] parameters = method.getParameterTypes();
            Object[] arguments = new Object[parameters.length];
            int count = 0;
            for (int i = 0; i < parameters.length; i++) {
                arguments[i] = defaultValue(parameters[i]);
                for (int v = 0; v < values.length; v++) {
                    if (!used[v] && fits(parameters[i], values[v])) {
                        arguments[i] = values[v];
                        used[v] = true;
                        count++;
                        break;
                    }
                }
            }
            if (count > bestUsed || (count == bestUsed && parameters.length < bestArguments.length)) {
                best = method;
                bestArguments = arguments;
                bestUsed = count;
            }
        }
        if (best == null) throw new NoSuchMethodException(type.getName() + "." + name);
        best.setAccessible(true);
        return best.invoke(statics ? null : target, bestArguments);
    }

    static boolean has(Class<?> type, String name) {
        for (Method method : allMethods(type)) if (method.getName().equals(name)) return true;
        return false;
    }

    static int intField(Object target, String name) throws Exception {
        Field field = target.getClass().getField(name);
        return field.getInt(target);
    }

    private static List<Method> allMethods(Class<?> type) {
        List<Method> methods = new ArrayList<>();
        for (Class<?> c = type; c != null; c = c.getSuperclass()) {
            for (Method m : c.getDeclaredMethods()) methods.add(m);
        }
        for (Method m : type.getMethods()) methods.add(m); // interface methods, for AIDL proxies
        return methods;
    }

    private static boolean fits(Class<?> parameter, Object value) {
        if (value == null) return false;
        if (parameter.isPrimitive()) {
            return (parameter == int.class && value instanceof Integer)
                    || (parameter == long.class && value instanceof Long)
                    || (parameter == boolean.class && value instanceof Boolean)
                    || (parameter == float.class && value instanceof Float);
        }
        return parameter.isInstance(value);
    }

    private static Object defaultValue(Class<?> type) {
        if (!type.isPrimitive()) return null;
        if (type == boolean.class) return false;
        if (type == long.class) return 0L;
        if (type == float.class) return 0f;
        if (type == double.class) return 0d;
        if (type == byte.class) return (byte) 0;
        if (type == short.class) return (short) 0;
        if (type == char.class) return (char) 0;
        return 0;
    }
}
