package guide.guidelabs.codexdrop;

import android.app.Activity;
import android.os.Bundle;
import android.content.Intent;
import android.net.Uri;
import java.io.File;
import java.io.FileOutputStream;
import java.util.ArrayList;

/** Test APK only: an external source retains the saved share Activity's task. */
public final class TaskSourceActivity extends Activity {
    @Override public void onCreate(Bundle savedState) {
        super.onCreate(savedState);
        try (FileOutputStream out = new FileOutputStream(new File(getFilesDir(),"source-task.txt"))) {
            out.write(Integer.toString(getTaskId()).getBytes(java.nio.charset.StandardCharsets.US_ASCII));
        } catch (java.io.IOException e) { throw new IllegalStateException(e); }
        if (savedState != null) return;
        String source = getIntent().getStringExtra("source");
        if (!"blocked.png".equals(source) && !"tiny.png".equals(source)) throw new IllegalArgumentException();
        ArrayList<Uri> images = new ArrayList<>();
        for (int i=0;i<3;i++) images.add(Uri.parse("content://guide.guidelabs.codexdrop.test.images/"+source));
        Intent share = new Intent(Intent.ACTION_SEND_MULTIPLE).setClassName("guide.guidelabs.codexdrop","guide.guidelabs.codexdrop.ShareActivity").setType("image/png").addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        share.putParcelableArrayListExtra(Intent.EXTRA_STREAM,images);
        startActivity(share);
    }
}
