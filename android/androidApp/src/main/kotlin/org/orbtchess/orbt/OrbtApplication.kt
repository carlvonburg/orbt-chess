package org.orbtchess.orbt

import android.app.Application
import android.net.ConnectivityManager
import android.net.Network
import android.os.Handler
import android.os.Looper
import org.orbtchess.orbt.platform.androidPlatform

/** Holds the app model for the process, so it outlives activities. */
class OrbtApplication : Application() {
    val model: AppModel by lazy { AppModel(androidPlatform(this)) }

    override fun onCreate() {
        super.onCreate()
        // The sync goes on as soon as the network is back, not at its next retry.
        val main = Handler(Looper.getMainLooper())
        getSystemService(ConnectivityManager::class.java)?.registerDefaultNetworkCallback(
            object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    main.post { model.sync.networkAvailable() }
                }
            },
        )
    }
}
