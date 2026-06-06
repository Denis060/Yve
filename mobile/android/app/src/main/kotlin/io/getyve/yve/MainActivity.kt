package io.getyve.yve

import android.os.Bundle
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    // Android 15 (SDK 35) draws apps edge-to-edge by default and Google
    // recommends opting in early so the deprecation warning in Play
    // Console for setStatusBarColor / setNavigationBarColor clears.
    // WindowCompat is the version-agnostic API (works on androidx.core
    // which Flutter already pulls in) — equivalent to the newer
    // enableEdgeToEdge() extension but doesn't require bumping the
    // androidx.activity dependency.
    override fun onCreate(savedInstanceState: Bundle?) {
        WindowCompat.setDecorFitsSystemWindows(window, false)
        super.onCreate(savedInstanceState)
    }
}
