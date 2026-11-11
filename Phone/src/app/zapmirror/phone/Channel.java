package app.zapmirror.phone;

import android.net.LocalSocket;

import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.Closeable;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;

/**
 * One connection with the Mac. Every message is a frame: a type byte, a big-endian length, the payload
 * (docs/PHONE-PROTOCOL.md). Sending is thread-safe; reading belongs to one thread.
 */
final class Channel implements Closeable {
    static final int MAX_PAYLOAD = 32 << 20;

    /** A received frame. `payload` is big-endian, positioned at the start. */
    static final class Frame {
        final int type;
        final ByteBuffer payload;

        Frame(int type, byte[] bytes) {
            this.type = type;
            payload = ByteBuffer.wrap(bytes);
        }

        /** The rest of the payload as text. */
        String text() {
            String text = new String(payload.array(), payload.position(), payload.remaining(), StandardCharsets.UTF_8);
            payload.position(payload.limit());
            return text;
        }
    }

    private final LocalSocket socket;
    private final DataInputStream in;
    private final DataOutputStream out;
    private byte[] scratch = new byte[1 << 16];

    Channel(LocalSocket socket) throws IOException {
        this.socket = socket;
        in = new DataInputStream(new BufferedInputStream(socket.getInputStream()));
        out = new DataOutputStream(new BufferedOutputStream(socket.getOutputStream(), 1 << 16));
    }

    Frame read() throws IOException {
        int type = in.readUnsignedByte();
        int length = in.readInt();
        if (length < 0 || length > MAX_PAYLOAD) throw new IOException("frame of " + length + " bytes");
        byte[] payload = new byte[length];
        in.readFully(payload);
        return new Frame(type, payload);
    }

    synchronized void send(int type, byte[] payload, int offset, int length) throws IOException {
        out.writeByte(type);
        out.writeInt(length);
        out.write(payload, offset, length);
        out.flush();
    }

    void send(int type, byte[] payload) throws IOException {
        send(type, payload, 0, payload.length);
    }

    void sendText(int type, String text) throws IOException {
        send(type, text.getBytes(StandardCharsets.UTF_8));
    }

    /** A frame whose payload is `header` followed by the remaining bytes of `data` (a codec's direct buffer). */
    synchronized void send(int type, byte[] header, ByteBuffer data) throws IOException {
        int length = data.remaining();
        if (scratch.length < length) scratch = new byte[Integer.highestOneBit(length) << 1];
        data.get(scratch, 0, length);
        out.writeByte(type);
        out.writeInt(header.length + length);
        out.write(header);
        out.write(scratch, 0, length);
        out.flush();
    }

    @Override
    public void close() {
        try {
            socket.shutdownInput();
        } catch (IOException ignored) {
        }
        try {
            socket.close();
        } catch (IOException ignored) {
        }
    }
}
