package app.zapmirror.phone;

import android.net.LocalServerSocket;
import android.net.LocalSocket;
import android.os.Build;
import android.os.Looper;
import android.os.Process;
import android.view.KeyEvent;

import java.io.IOException;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

// No lambdas here or elsewhere in Phone/: android.jar has no LambdaMetafactory to compile them against.

/**
 * Zapmirror's phone component. The Mac starts it through adb as the shell user; it streams the screen and sound and
 * carries out the Mac's input. docs/PHONE-PROTOCOL.md describes the conversation.
 */
public final class Main {
    /** The protocol version. The Mac passes the one it speaks; any other is refused. */
    static final String VERSION = "1";

    static final class Options {
        int maxSize = 1920;
        int bitRate = 8_000_000;
        int fps = 60;
        boolean audio = true;
        boolean stayAwake = true;

        static Options parse(String[] args, int start) {
            Options options = new Options();
            for (int i = start; i < args.length; i++) {
                switch (args[i]) {
                    case "--max-size": options.maxSize = Integer.parseInt(args[++i]); break;
                    case "--bit-rate": options.bitRate = Integer.parseInt(args[++i]); break;
                    case "--fps": options.fps = Integer.parseInt(args[++i]); break;
                    case "--no-audio": options.audio = false; break;
                    case "--no-stay-awake": options.stayAwake = false; break;
                    default: Log.i("ignoring option " + args[i]);
                }
            }
            return options;
        }
    }

    private static final CountDownLatch finished = new CountDownLatch(1);
    private static volatile boolean videoConnected;
    private static final java.util.Set<String> connected = new java.util.HashSet<>();

    private Main() {}

    public static void main(String[] args) {
        try {
            run(args);
        } catch (Throwable e) {
            Log.w("stopped", e);
        } finally {
            Phone.restore();
            removeOurselves();
            Log.i("bye");
            System.exit(0);
        }
    }

    /** Deletes the component's jar from the phone; the Mac installs a fresh copy for every session. */
    private static void removeOurselves() {
        String path = System.getenv("CLASSPATH");
        if (path != null && path.startsWith("/data/local/tmp/") && path.endsWith(".jar")) new java.io.File(path).delete();
    }

    private static void run(String[] args) throws Exception {
        if (args.length < 2 || !VERSION.equals(args[0])) {
            Log.i("error: this is protocol " + VERSION + ", but the Mac asked for "
                    + (args.length > 0 ? args[0] : "nothing") + ". Update Zapmirror.");
            return;
        }
        Options options = Options.parse(args, 2);
        Looper.prepareMainLooper(); // some framework classes expect one to exist
        LocalServerSocket server = new LocalServerSocket("zapmirror-" + args[1]);
        Log.i("listening");

        Thread accepting = new Thread(new Runnable() {
            @Override
            public void run() {
                accept(server, options);
            }
        }, "accept");
        accepting.setDaemon(true);
        accepting.start();
        if (!finished.await(15, TimeUnit.SECONDS) && !videoConnected) {
            Log.i("the Mac didn't connect");
            return;
        }
        finished.await();
        try {
            server.close();
        } catch (IOException ignored) {
            // already closed once every channel had connected
        }
    }

    private static void finish(String why) {
        if (finished.getCount() > 0) Log.i("ending: " + why);
        finished.countDown();
    }

    private static void accept(LocalServerSocket server, Options options) {
        try {
            while (true) {
                LocalSocket socket = server.accept();
                // Only adb may connect: it runs as the shell user, like this component (or as root on debug builds).
                int peer = socket.getPeerCredentials().getUid();
                if (peer != Process.myUid() && peer != 0) {
                    Log.i("refused a connection from uid " + peer);
                    socket.close();
                    continue;
                }
                Channel channel = new Channel(socket);
                Channel.Frame hello = channel.read();
                String name = hello.type == 'h' ? hello.text() : "";
                // Each channel connects once. When all have, stop listening.
                if (!connected.add(name)) {
                    Log.i("refused a second '" + name + "' connection");
                    channel.close();
                    continue;
                }
                switch (name) {
                    case "video":
                        videoConnected = true;
                        start("video", new Job() {
                            @Override
                            public void run() throws Exception {
                                Screen.stream(channel, options);
                            }
                        }, true);
                        break;
                    case "audio":
                        if (options.audio) {
                            start("audio", new Job() {
                                @Override
                                public void run() throws Exception {
                                    Sound.stream(channel);
                                }
                            }, false);
                        }
                        else channel.sendText('E', "sound is off");
                        break;
                    case "control":
                        start("control", new Job() {
                            @Override
                            public void run() throws Exception {
                                control(channel, options);
                            }
                        }, true);
                        break;
                    default:
                        Log.i("unknown channel '" + name + "'");
                        connected.remove(name);
                        channel.close();
                }
                if (connected.contains("video") && connected.contains("control")
                        && (connected.contains("audio") || !options.audio)) {
                    server.close();
                    return;
                }
            }
        } catch (IOException e) {
            if (finished.getCount() > 0) finish("listening failed: " + Log.describe(e));
        }
    }

    private interface Job {
        void run() throws Exception;
    }

    /** Runs `job` on its own thread; when a vital one ends, so does the session. */
    private static void start(String name, Job job, boolean vital) {
        Thread thread = new Thread(new Runnable() {
            @Override
            public void run() {
                try {
                    job.run();
                    if (vital) finish(name + " ended");
                } catch (Throwable e) {
                    if (vital) finish(name + ": " + Log.describe(e));
                    else Log.w(name + " stopped", e);
                }
            }
        }, name);
        thread.setDaemon(true);
        thread.start();
    }

    /** Reads the Mac's control messages until it disconnects. */
    private static void control(Channel channel, Options options) throws Exception {
        Input input = new Input();
        if (!Phone.isAwake()) input.press(KeyEvent.KEYCODE_WAKEUP);
        if (options.stayAwake) Phone.stayAwake();
        Phone.watchClipboard(new Phone.ClipboardListener() {
            @Override
            public void changed(String text) {
                try {
                    channel.sendText('c', text);
                } catch (IOException ignored) {
                    // the session is ending
                }
            }
        });
        Log.i("ready on " + Build.MANUFACTURER + " " + Build.MODEL + ", Android " + Build.VERSION.RELEASE);

        while (true) {
            Channel.Frame frame = channel.read();
            java.nio.ByteBuffer p = frame.payload;
            try {
                switch (frame.type) {
                    case 'k': {
                        int action = p.get() & 0xff;
                        int keycode = p.getInt(), meta = p.getInt(), repeat = p.getInt();
                        input.key(action, keycode, meta, repeat);
                        break;
                    }
                    case 't': input.type(frame.text()); break;
                    case 'p': {
                        int action = p.get() & 0xff, finger = p.get() & 0xff;
                        input.touch(action, finger, p.getFloat(), p.getFloat(), p.getFloat());
                        break;
                    }
                    case 'w': input.scroll(p.getFloat(), p.getFloat(), p.getFloat(), p.getFloat()); break;
                    case 'b': input.press(Phone.isAwake() ? KeyEvent.KEYCODE_BACK : KeyEvent.KEYCODE_WAKEUP); break;
                    case 'n': Phone.panel(p.get() & 0xff); break;
                    case 'g':
                        Phone.expectCopy();
                        input.press(p.get() == 1 ? KeyEvent.KEYCODE_CUT : KeyEvent.KEYCODE_COPY);
                        break;
                    case 's': {
                        boolean paste = p.get() != 0;
                        Phone.setClipboard(frame.text(), true);
                        if (paste) input.press(KeyEvent.KEYCODE_PASTE);
                        break;
                    }
                    case 'd': Phone.setScreenPower(p.get() != 0); break;
                    case 'r': Phone.rotate(); break;
                    default: break; // from a newer Mac app: skip
                }
            } catch (java.nio.BufferUnderflowException e) {
                Log.i("short '" + (char) frame.type + "' message");
            } catch (Exception e) {
                Log.w("couldn't do '" + (char) frame.type + "'", e);
            }
        }
    }
}
