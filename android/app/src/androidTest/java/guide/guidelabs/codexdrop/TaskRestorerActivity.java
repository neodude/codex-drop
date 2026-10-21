package guide.guidelabs.codexdrop;

import android.app.Activity;
import android.app.ActivityManager;
import android.os.Bundle;

/** Test APK only: bring an existing saved task forward, without a new share intent. */
public final class TaskRestorerActivity extends Activity {
    @Override public void onCreate(Bundle savedState) {
        super.onCreate(savedState);
        int task = getIntent().getIntExtra("taskId",-1);
        if (task >= 0) getSystemService(ActivityManager.class).moveTaskToFront(task,0);
        finish();
    }
}
