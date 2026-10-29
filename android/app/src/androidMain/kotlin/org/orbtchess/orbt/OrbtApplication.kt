package org.orbtchess.orbt

import android.app.Application
import org.orbtchess.orbt.platform.androidPlatform

/** Holds the app model for the process, so it outlives activities. */
class OrbtApplication : Application() {
    val model: AppModel by lazy { AppModel(androidPlatform(this)) }
}
