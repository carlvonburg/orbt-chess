package org.orbtchess.orbt

import android.content.pm.ActivityInfo
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    private val model get() = (application as OrbtApplication).model

    override fun onCreate(savedInstanceState: Bundle?) {
        // The icon on the app's background (Theme.Orbt.Starting), then Theme.Orbt.
        installSplashScreen()
        // No scrim behind 3-button navigation: the app's bottom bars (the navigation bar, the board
        // screens' docked toolbar) draw behind the buttons themselves, as Android's edge-to-edge
        // guide asks of apps with a bottom bar.
        enableEdgeToEdge()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) window.isNavigationBarContrastEnforced = false
        // Phones in portrait only, as on iPhone; tablets and unfolded foldables turn freely
        // (Android's "restrict orientation on phones but not on large screens"). A phone is a
        // screen less than 600 dp across its shorter side, Material's compact width; folding or
        // unfolding recreates the activity, which decides again.
        requestedOrientation = if (resources.configuration.smallestScreenWidthDp < 600) {
            ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        } else {
            ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
        }
        super.onCreate(savedInstanceState)
        setContent { App(model) }
    }

    override fun onResume() {
        super.onResume()
        lifecycleScope.launch { model.resume() }
    }

    override fun onStop() {
        super.onStop()
        lifecycleScope.launch { model.flush() }
    }
}
