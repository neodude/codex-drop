package guide.guidelabs.codexdrop;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.graphics.Bitmap;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.nio.ByteBuffer;

/** Standalone test APK process: Java fixture has no dependency on target-app classes. */
public final class ImageFixtureProvider extends ContentProvider {
    private final java.util.concurrent.ConcurrentHashMap<String,java.util.concurrent.CountDownLatch> gates = new java.util.concurrent.ConcurrentHashMap<>();
    @Override public android.os.Bundle call(String method, String arg, android.os.Bundle extras) {
        if ("release".equals(method) && arg != null) gates.computeIfAbsent(arg,k -> new java.util.concurrent.CountDownLatch(1)).countDown();
        return new android.os.Bundle();
    }
    @Override public boolean onCreate() { return true; }
    @Override public String getType(Uri uri) { return uri.getPath().endsWith(".jpg") ? "image/jpeg" : "image/png"; }
    @Override public ParcelFileDescriptor openFile(Uri uri, String mode) throws FileNotFoundException {
        if (!mode.equals("r") || "missing".equals(uri.getLastPathSegment())) throw new FileNotFoundException();
        if ("denied".equals(uri.getLastPathSegment())) throw new SecurityException("Synthetic revoked grant");
        final ParcelFileDescriptor[] pipe;
        try { pipe = ParcelFileDescriptor.createPipe(); } catch (IOException e) { throw new FileNotFoundException(); }
        new Thread(() -> {
            try (ParcelFileDescriptor.AutoCloseOutputStream stream = new ParcelFileDescriptor.AutoCloseOutputStream(pipe[1])) {
                if (uri.getLastPathSegment().startsWith("gated-")) {
                    try {
                        if (!gates.computeIfAbsent(uri.getLastPathSegment(),k -> new java.util.concurrent.CountDownLatch(1)).await(18,java.util.concurrent.TimeUnit.SECONDS)) return;
                    } catch (InterruptedException e) { Thread.currentThread().interrupt(); return; }
                }
                if ("slow.png".equals(uri.getLastPathSegment()) || "blocked.png".equals(uri.getLastPathSegment())) {
                    try { Thread.sleep("blocked.png".equals(uri.getLastPathSegment()) ? 15000 : 3000); } catch (InterruptedException e) { Thread.currentThread().interrupt(); return; }
                }
                switch (uri.getLastPathSegment()) {
                    case "noise.png":
                        Bitmap noise = Bitmap.createBitmap(1024,1024,Bitmap.Config.ARGB_8888);
                        int[] pixels = new int[1024*1024]; int value = 12345;
                        for (int i = 0; i < pixels.length; i++) { value ^= value << 13; value ^= value >>> 17; value ^= value << 5; pixels[i] = 0xff000000 | (value & 0x00ffffff); }
                        noise.setPixels(pixels,0,1024,0,0,1024,1024);
                        try { noise.compress(Bitmap.CompressFormat.PNG,100,stream); } finally { noise.recycle(); }
                        break;
                    case "too-large":
                        byte[] buffer = new byte[1024];
                        for (int i = 0; i < 20 * 1024 + 1; i++) stream.write(buffer);
                        break;
                    case "not-image": stream.write(new byte[]{1,2,3}); break;
                    case "too-many-pixels.png":
                        stream.write(ByteBuffer.allocate(33).put(new byte[]{-119,80,78,71,13,10,26,10}).putInt(13).put(new byte[]{73,72,68,82}).putInt(12_000_001).putInt(1).put(new byte[]{8,6,0,0,0}).putInt(0).array()); break;
                    default:
                        Bitmap bitmap = Bitmap.createBitmap(4,4,Bitmap.Config.ARGB_8888);
                        try { bitmap.compress(uri.getPath().endsWith(".jpg") ? Bitmap.CompressFormat.JPEG : Bitmap.CompressFormat.PNG,100,stream); }
                        finally { bitmap.recycle(); }
                }
            } catch (IOException ignored) { /* Reader may close an over-limit pipe. */ }
        }, "CodexDrop-test-image").start();
        return pipe[0];
    }
    @Override public Cursor query(Uri uri, String[] projection, String selection, String[] args, String order) { return null; }
    @Override public Uri insert(Uri uri, ContentValues values) { throw new UnsupportedOperationException(); }
    @Override public int update(Uri uri, ContentValues values, String selection, String[] args) { return 0; }
    @Override public int delete(Uri uri, String selection, String[] args) { return 0; }
}
