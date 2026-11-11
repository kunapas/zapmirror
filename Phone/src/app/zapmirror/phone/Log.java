package app.zapmirror.phone;

import java.lang.reflect.InvocationTargetException;

/** Lines for the Mac, which shows them in its log as "phone: zapmirror: …". */
final class Log {
    private Log() {}

    static void i(String message) {
        System.out.println("zapmirror: " + message);
        System.out.flush();
    }

    static void w(String message, Throwable error) {
        i(message + ": " + describe(error));
    }

    /** The innermost cause, unwrapped from reflection's wrappers: that's the part worth reading. */
    static String describe(Throwable error) {
        Throwable root = error;
        while (true) {
            Throwable next = root instanceof InvocationTargetException
                    ? ((InvocationTargetException) root).getTargetException() : root.getCause();
            if (next == null || next == root) break;
            root = next;
        }
        String message = root.getMessage();
        return root.getClass().getSimpleName() + (message == null ? "" : " (" + message + ")");
    }
}
