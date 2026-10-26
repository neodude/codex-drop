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
    @Override public String getType(Uri uri) {
        String name = uri.getLastPathSegment();
        if (name.startsWith("unknown-")) return null;
        if (name.startsWith("generic-")) return "application/octet-stream";
        if (name.endsWith(".mp4")) return "video/mp4";
        if (name.endsWith(".mov")) return "video/quicktime";
        if (name.endsWith(".pdf")) return "application/pdf";
        if (name.endsWith(".webm")) return "video/webm";
        return uri.getPath().endsWith(".jpg") ? "image/jpeg" : "image/png";
    }
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
                if ("slow.png".equals(uri.getLastPathSegment()) || uri.getLastPathSegment().startsWith("blocked")) {
                    try { Thread.sleep(uri.getLastPathSegment().startsWith("blocked") ? 15000 : 3000); } catch (InterruptedException e) { Thread.currentThread().interrupt(); return; }
                }
                String name = uri.getLastPathSegment();
                if (name.endsWith(".mp4") || name.endsWith(".mov")) {
                    String resourceName = name.endsWith(".mov") ? "/synthetic-video.mov" : "/synthetic-video.mp4";
                    try (java.io.InputStream resource = ImageFixtureProvider.class.getResourceAsStream(resourceName)) {
                        if (resource == null) throw new IOException("Missing synthetic video fixture");
                        byte[] bytes = new byte[16384];int n;while ((n = resource.read(bytes)) != -1) stream.write(bytes,0,n);
                    }
                    if (name.startsWith("over-limit")) {
                        byte[] zeros = new byte[16384];
                        for (int remaining = 50 * 1024 * 1024 + 1; remaining > 0;) { int n = Math.min(zeros.length, remaining);stream.write(zeros,0,n);remaining -= n; }
                    }
                    return;
                }
                if (name.equals("camera.png") || name.equals("camera.jpg") || name.startsWith("oriented-") || name.equals("large.jpg") || name.equals("original.webp")) {
                    int width = name.startsWith("oriented-") ? 4000 : name.equals("large.jpg") ? 5000 : 3024;
                    int height = name.startsWith("oriented-") ? 3500 : name.equals("large.jpg") ? 4000 : 4032;
                    Bitmap photo = Bitmap.createBitmap(width,height,Bitmap.Config.ARGB_8888);
                    android.graphics.Canvas canvas = new android.graphics.Canvas(photo);
                    android.graphics.Paint paint = new android.graphics.Paint();
                    int[] colors = { android.graphics.Color.RED,android.graphics.Color.GREEN,android.graphics.Color.BLUE,android.graphics.Color.YELLOW };
                    for (int i = 0; i < 4; i++) { paint.setColor(colors[i]);canvas.drawRect((i % 2) * width / 2f,(i / 2) * height / 2f,(i % 2 + 1) * width / 2f,(i / 2 + 1) * height / 2f,paint); }
                    java.io.File temporary = java.io.File.createTempFile("photo-fixture-", ".jpg", getContext().getCacheDir());
                    try {
                        try (java.io.FileOutputStream file = new java.io.FileOutputStream(temporary)) { photo.compress(name.endsWith(".png") ? Bitmap.CompressFormat.PNG : name.endsWith(".webp") ? Bitmap.CompressFormat.WEBP_LOSSLESS : Bitmap.CompressFormat.JPEG,100,file); }
                        finally { photo.recycle(); }
                        if (name.startsWith("oriented-")) {
                            android.media.ExifInterface exif = new android.media.ExifInterface(temporary.getAbsolutePath());
                            exif.setAttribute(android.media.ExifInterface.TAG_ORIENTATION, name.substring(9,10));
                            exif.setAttribute(android.media.ExifInterface.TAG_ARTIST, "Synthetic original metadata");
                            exif.setAttribute(android.media.ExifInterface.TAG_USER_COMMENT, "Preserve this original file exactly");
                            exif.saveAttributes();
                        }
                        try (java.io.FileInputStream file = new java.io.FileInputStream(temporary)) {
                            if (name.startsWith("oriented-")) {
                                // Insert a generated LittleCMS sRGB ICC APP2 record without changing the EXIF JPEG payload.
                                stream.write(file.read());stream.write(file.read());
                                byte[] profile;
                                try (java.io.InputStream resource = ImageFixtureProvider.class.getResourceAsStream("/sRGB.icc")) {
                                    if (resource == null) throw new IOException("Missing synthetic ICC fixture");
                                    java.io.ByteArrayOutputStream profileBytes = new java.io.ByteArrayOutputStream();
                                    byte[] buffer = new byte[4096];int n;while ((n = resource.read(buffer)) != -1) profileBytes.write(buffer,0,n);
                                    profile = profileBytes.toByteArray();
                                }
                                java.io.DataOutputStream record = new java.io.DataOutputStream(stream);
                                record.writeByte(0xff);record.writeByte(0xe2);record.writeShort(profile.length + 16);
                                record.write(new byte[]{73,67,67,95,80,82,79,70,73,76,69,0,1,1});record.write(profile);
                            }
                            byte[] bytes = new byte[16384];int n;while ((n = file.read(bytes)) != -1) stream.write(bytes,0,n);
                        }
                    } finally { temporary.delete(); }
                    return;
                }
                if (name.equals("padded-25.png") || name.equals("padded-50.png") || name.equals("padded-over.png")) {
                    Bitmap tiny = Bitmap.createBitmap(4,4,Bitmap.Config.ARGB_8888);
                    java.io.ByteArrayOutputStream png = new java.io.ByteArrayOutputStream();
                    try { tiny.compress(Bitmap.CompressFormat.PNG,100,png); } finally { tiny.recycle(); }
                    byte[] base = png.toByteArray();
                    int total = name.equals("padded-25.png") ? 25 * 1024 * 1024 : 50 * 1024 * 1024 + (name.equals("padded-over.png") ? 1 : 0);
                    int chunkLength = total - base.length - 12;
                    stream.write(base,0,base.length - 12);
                    java.io.DataOutputStream data = new java.io.DataOutputStream(stream);
                    data.writeInt(chunkLength);
                    byte[] type = new byte[]{114,112,65,100};data.write(type);
                    java.util.zip.CRC32 crc = new java.util.zip.CRC32();crc.update(type);
                    byte[] zeros = new byte[16384];
                    for (int remaining = chunkLength; remaining > 0;) { int n = Math.min(zeros.length,remaining);data.write(zeros,0,n);crc.update(zeros,0,n);remaining -= n; }
                    data.writeInt((int)crc.getValue());data.write(base,base.length - 12,12);
                    return;
                }
                if (name.equals("original.gif")) {
                    stream.write(android.util.Base64.decode("R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7", android.util.Base64.DEFAULT));
                    return;
                }
                if (name.equals("original.heic")) {
                    // Task-generated valid ImageIO HEIC fixture, containing no personal image data.
                    try (java.io.InputStream resource = ImageFixtureProvider.class.getResourceAsStream("/synthetic.heic")) {
                        if (resource == null) throw new IOException("Missing synthetic HEIC fixture");
                        byte[] bytes = new byte[4096];int n;while ((n = resource.read(bytes)) != -1) stream.write(bytes,0,n);
                    }
                    return;
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
                        for (int i = 0; i < 50 * 1024 + 1; i++) stream.write(buffer);
                        break;
                    case "not-image": stream.write(new byte[]{1,2,3}); break;
                    case "too-many-pixels.png":
                        stream.write(ByteBuffer.allocate(33).put(new byte[]{-119,80,78,71,13,10,26,10}).putInt(13).put(new byte[]{73,72,68,82}).putInt(8001).putInt(8000).put(new byte[]{8,6,0,0,0}).putInt(0).array()); break;
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
