package android.util;

/** JVM tests exercise failure handling without an Android logging runtime. */
public final class Log {
    public static int e(String tag, String message) { return 0; }
}
