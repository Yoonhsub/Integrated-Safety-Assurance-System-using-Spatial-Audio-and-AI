import java.util.Base64
import java.io.File

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Flutter passes -Ptarget and comma-separated Base64 UTF-8 -Pdart-defines.
// Do not infer a normal application when an entry point cannot be identified.
fun isolationFailure(reason: String): Nothing =
    throw GradleException("[MOBI_BUILD_ISOLATION] $reason")
val explicitTarget = (project.findProperty("target") as? String)
    ?.takeIf { it.isNotBlank() } ?: isolationFailure("Explicit Flutter target required")
val sourceRoot = project.projectDir.resolve("../..").canonicalFile
val targetFile = File(explicitTarget).let {
    (if (it.isAbsolute) it else sourceRoot.resolve(explicitTarget)).canonicalFile
}
val mainTarget = sourceRoot.resolve("lib/main.dart").canonicalFile
val cameraTarget = sourceRoot.resolve("lib/local_vision_main.dart").canonicalFile
if (!targetFile.isFile || targetFile !in setOf(mainTarget, cameraTarget)) {
    isolationFailure("Unknown or outside-project Flutter target")
}
val defines = mutableMapOf<String, String>()
val isolationKeys = setOf("MOBI_OFFLINE_CAMERA")
val encodedDefines = (project.findProperty("dart-defines") as? String).orEmpty()
if (encodedDefines.isNotEmpty()) {
    encodedDefines.split(',').forEach { encoded ->
        val decoded = try {
            String(Base64.getDecoder().decode(encoded), Charsets.UTF_8)
        } catch (_: IllegalArgumentException) {
            isolationFailure("Malformed dart-defines encoding")
        }
        val separator = decoded.indexOf('=')
        if (separator <= 0) isolationFailure("Malformed dart-define assignment")
        val key = decoded.substring(0, separator)
        if (key in isolationKeys && defines.containsKey(key)) {
            isolationFailure("Duplicate isolation define")
        }
        defines[key] = decoded.substring(separator + 1)
    }
}
val offlineCamera = targetFile == cameraTarget
val presentIsolationKeys = defines.keys.intersect(isolationKeys)
when {
    offlineCamera && (presentIsolationKeys != setOf("MOBI_OFFLINE_CAMERA") ||
        defines["MOBI_OFFLINE_CAMERA"] != "true") ->
        isolationFailure("Camera entry requires exactly its true isolation define")
    targetFile == mainTarget && presentIsolationKeys.isNotEmpty() ->
        isolationFailure("Normal Passenger entry cannot use test isolation defines")
}
val testApplication = offlineCamera
if (testApplication && gradle.startParameter.taskNames.any {
        it.contains("profile", ignoreCase = true) || it.contains("release", ignoreCase = true)
    }) {
    isolationFailure("Test applications are debug-only; profile/release forbidden")
}
// Actual AGP variant selection is the final boundary, including aggregate/alias
// tasks. Non-debug test variants do not exist, rather than receiving a debug-only
// overlay accidentally. The ordinary Passenger variants remain unchanged.
androidComponents.beforeVariants(androidComponents.selector().all()) { variant ->
    if (testApplication && variant.buildType != "debug") variant.enable = false
}

android {
    namespace = "com.example.mobi_passenger_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.mobi_passenger_app"
        if (offlineCamera) applicationIdSuffix = ".offlinevision"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    if (offlineCamera) {
        // tools:node cannot be a manifest placeholder. Select a generated,
        // static debug overlay, leaving the ordinary manifests untouched.
        val offlineManifest = layout.buildDirectory
            .file("generated/offline-camera/AndroidManifest.xml").get().asFile
        offlineManifest.parentFile.mkdirs()
        offlineManifest.writeText("""
            <manifest xmlns:android="http://schemas.android.com/apk/res/android"
                xmlns:tools="http://schemas.android.com/tools">
                <uses-permission android:name="android.permission.INTERNET" tools:node="remove" />
                <application>
                    <provider android:name="com.google.firebase.provider.FirebaseInitProvider" tools:node="remove" />
                </application>
            </manifest>
        """.trimIndent())
        sourceSets.getByName("debug").manifest.srcFile(offlineManifest)
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
