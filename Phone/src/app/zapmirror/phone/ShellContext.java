package app.zapmirror.phone;

import android.content.AttributionSource;
import android.content.Context;
import android.content.ContextWrapper;
import android.os.Process;

/**
 * Just enough of a Context for APIs that only want to know who is calling. The component isn't an app: it runs as the
 * shell user, whose package is com.android.shell, and that's who Android checks permissions for.
 */
final class ShellContext extends ContextWrapper {
    static final String PACKAGE = "com.android.shell";
    static final ShellContext INSTANCE = new ShellContext();

    private ShellContext() {
        super(null);
    }

    @Override
    public String getPackageName() {
        return PACKAGE;
    }

    @Override
    public String getOpPackageName() {
        return PACKAGE;
    }

    @Override
    public String getAttributionTag() {
        return null;
    }

    @Override
    public AttributionSource getAttributionSource() {
        return new AttributionSource.Builder(Process.myUid()).setPackageName(PACKAGE).build();
    }

    @Override
    public int getDeviceId() {
        return Context.DEVICE_ID_DEFAULT;
    }

    @Override
    public Context getApplicationContext() {
        return this;
    }
}
