package org.orbtchess.orbt.platform

import android.app.Activity
import android.app.Application
import android.os.Bundle
import com.google.android.play.core.review.ReviewManagerFactory
import org.orbtchess.orbt.BuildConfig
import java.lang.ref.WeakReference

/**
 * Google Play's In-App Review: Play shows its rating sheet over the activity in front, or
 * nothing (its quota, or an app not installed from Play).
 */
class PlayReview(private val app: Application) : StoreReview {
    private val manager = ReviewManagerFactory.create(app)
    private var resumed: WeakReference<Activity>? = null

    init {
        app.registerActivityLifecycleCallbacks(object : Application.ActivityLifecycleCallbacks {
            override fun onActivityResumed(activity: Activity) {
                resumed = WeakReference(activity)
            }

            override fun onActivityPaused(activity: Activity) {
                if (resumed?.get() === activity) resumed = null
            }

            override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) = Unit
            override fun onActivityStarted(activity: Activity) = Unit
            override fun onActivityStopped(activity: Activity) = Unit
            override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) = Unit
            override fun onActivityDestroyed(activity: Activity) = Unit
        })
    }

    override val version: String = BuildConfig.VERSION_NAME

    override val pageUrl = "https://play.google.com/store/apps/details?id=${app.packageName}"

    override fun request() {
        manager.requestReviewFlow().addOnSuccessListener { info ->
            resumed?.get()?.let { manager.launchReviewFlow(it, info) }
        }
    }
}
