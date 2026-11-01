plugins {
    kotlin("multiplatform") version "2.3.0" apply false
    kotlin("plugin.compose") version "2.3.0" apply false
    id("org.jetbrains.compose") version "1.13.0-beta01" apply false
    id("com.android.application") version "9.5.0" apply false
    id("com.android.kotlin.multiplatform.library") version "9.5.0" apply false
}

// The app's version and build number, from ../Version.xcconfig (shared with Xcode): the Android
// app's versionName and versionCode, the desktop app's packageVersion.
val appVersion: Map<String, String> = rootProject.file("../Version.xcconfig").readLines()
    .map { it.substringBefore("//").trim() }
    .filter { "=" in it }
    .associate { it.substringBefore("=").trim() to it.substringAfter("=").trim() }
extra["orbtVersionName"] = appVersion.getValue("MARKETING_VERSION")
extra["orbtVersionCode"] = appVersion.getValue("CURRENT_PROJECT_VERSION").toInt()
