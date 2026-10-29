package org.orbtchess.orbt

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    private val model get() = (application as OrbtApplication).model

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
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
