package com.spokenmargins.android;

import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import androidx.core.content.IntentCompat;
import com.getcapacitor.BridgeActivity;

public class MainActivity extends BridgeActivity {

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        if (savedInstanceState != null) {
            // Recreated after Android reclaimed the app: the file in the launch intent was already opened.
            setIntent(new Intent(Intent.ACTION_MAIN));
        } else {
            setIntent(asViewIntent(getIntent()));
        }
        super.onCreate(savedInstanceState);
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(asViewIntent(intent));
    }

    /**
     * A file shared to the app (ACTION_SEND) is handed on as ACTION_VIEW of that file, which the App plugin reports
     * to the page as appUrlOpen, the same way as "Open with" (#3009). The read grant from the sending app belongs to
     * this app, so the page can still read the file.
     */
    static Intent asViewIntent(Intent intent) {
        if (intent == null || !Intent.ACTION_SEND.equals(intent.getAction())) return intent;
        Uri stream = IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri.class);
        if (stream == null) return intent;
        Intent view = new Intent(Intent.ACTION_VIEW, stream);
        view.setDataAndType(stream, intent.getType());
        view.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
        return view;
    }
}
