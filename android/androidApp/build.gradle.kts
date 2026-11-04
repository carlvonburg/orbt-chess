// The Android app: the activities, the manifest and what needs the app itself (Custom Tabs,
// Play services' sign-in, the core's .so files, the Dropbox key, versions and signing) around
// the shared code in `app`. AGP's built-in Kotlin compiles it.
import java.util.Properties

plugins {
    id("com.android.application")
    kotlin("plugin.compose")
}

// Dropbox's app key (the OAuth client id of the owner's Dropbox app): the Gradle property
// `orbt.dropboxAppKey` (`-P`, ~/.gradle/gradle.properties) or the same key in local.properties.
// Without it the Dropbox sign-in says the build has none.
val dropboxAppKey: String = providers.gradleProperty("orbt.dropboxAppKey").orNull
    ?: rootProject.file("local.properties").takeIf { it.exists() }?.let { file ->
        Properties().apply { file.inputStream().use { load(it) } }.getProperty("orbt.dropboxAppKey")
    }
    ?: ""

// The Play upload key: keystore.properties next to local.properties (storeFile, keyAlias; Android's
// "Sign your app"), never committed. Without it the release bundle is unsigned. The password
// (the keystore's and the key's, one in PKCS12) is the file's storePassword, else the login
// Keychain's generic password "ORBT upload key" on a Mac
// (`security add-generic-password -s "ORBT upload key" -a upload -w`).
val keystoreProperties: Properties? = rootProject.file("keystore.properties").takeIf { it.exists() }
    ?.let { file -> Properties().apply { file.inputStream().use { load(it) } } }
val uploadKeyPassword: String? = keystoreProperties?.let { properties ->
    properties.getProperty("storePassword")
        ?: providers.exec {
            commandLine("security", "find-generic-password", "-s", "ORBT upload key", "-w")
            isIgnoreExitValue = true
        }.standardOutput.asText.get().trim().ifEmpty { null }
}

android {
    namespace = "org.orbtchess.orbt"
    compileSdk { version = release(37) { minorApiLevel = 1 } }
    buildFeatures {
        buildConfig = true
    }
    defaultConfig {
        buildConfigField("String", "DROPBOX_APP_KEY", "\"$dropboxAppKey\"")
        applicationId = "org.orbtchess.orbt"
        minSdk = 29
        targetSdk = 36
        // Version.xcconfig, through the root build.
        versionCode = rootProject.extra["orbtVersionCode"] as Int
        versionName = rootProject.extra["orbtVersionName"] as String
        ndk {
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
    }
    signingConfigs {
        if (keystoreProperties != null) {
            create("upload") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = uploadKeyPassword
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword") ?: uploadKeyPassword
            }
        }
    }
    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.findByName("upload")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    jvmToolchain(17)
}

// What a release bundle must have, checked before it is built, so one without them is never
// uploaded: the Dropbox key, the upload key, and the core's .so files built (for release) from
// the core as it is now (build-android.sh records which: jniLibs.sources). Google Drive needs
// nothing here: Play services matches the app's signing certificate.
val checkReleaseInputs by tasks.registering {
    group = "verification"
    description = "Fails unless the release has its keys and up-to-date core libraries."
    val key = dropboxAppKey
    val signed = keystoreProperties != null && uploadKeyPassword != null
    val stamp = file("jniLibs.sources")
    val fingerprintScript = rootProject.file("../core/scripts/core-fingerprint.sh")
    doLast {
        val problems = mutableListOf<String>()
        if (key.isBlank()) {
            problems += "no Dropbox app key (orbt.dropboxAppKey in local.properties or -P)"
        }
        if (!signed) {
            problems += "no upload key (keystore.properties, and its password in the Keychain's \"ORBT upload key\")"
        }
        val built = stamp.takeIf { it.exists() }?.readText()?.trim()
        val current = ProcessBuilder(fingerprintScript.path).redirectErrorStream(true).start()
            .let { process -> process.inputStream.bufferedReader().readText().trim().takeIf { process.waitFor() == 0 } }
        when {
            built == null -> problems += "the core's .so files have no release build record: run core/scripts/build-android.sh"
            current == null -> problems += "could not fingerprint the core (core/scripts/core-fingerprint.sh)"
            built != current -> problems += "the core's .so files are older than the core: run core/scripts/build-android.sh"
        }
        if (problems.isNotEmpty()) {
            throw GradleException("This release is not ready:\n" + problems.joinToString("\n") { "- $it" })
        }
    }
}

// Every release variant (bundleRelease, assembleRelease) checks first.
tasks.matching { it.name == "preReleaseBuild" }.configureEach { dependsOn(checkReleaseInputs) }

dependencies {
    implementation(project(":app"))
    implementation(project(":core"))
    implementation("androidx.activity:activity-compose:1.13.0")
    // Lichess and Dropbox sign-ins, Analyse on Lichess (Custom Tabs).
    implementation("androidx.browser:browser:1.8.0")
    // The splash screen (Theme.Orbt.Starting) on every Android version.
    implementation("androidx.core:core-splashscreen:1.2.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    // Google Drive sign-in (Identity's AuthorizationClient, the drive.file scope).
    implementation("com.google.android.gms:play-services-auth:21.4.0")
    // Asking for a rating in the Play Store (In-App Review).
    implementation("com.google.android.play:review:2.0.2")
}
