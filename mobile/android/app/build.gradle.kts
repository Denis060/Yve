import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing config is opt-in. Drop a `android/key.properties` file
// (see android/key.properties.template) and the release build will sign
// with your upload keystore; otherwise it falls through to debug signing
// so `flutter run --release` and sideloaded APKs/AABs keep working in dev.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "io.getyve.yve"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications uses java.time APIs that don't
        // exist on older Android runtimes; desugaring backports them.
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "io.getyve.yve"
        // supabase_flutter + flutter_local_notifications + speech_to_text
        // each need API 23+; keep the floor explicit so a future plugin
        // change can't quietly push us below what we've tested.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                // rootProject.file() resolves from android/ (where
                // key.properties lives), not android/app/. So the path
                // in key.properties is "yve-upload-keystore.jks" and
                // the keystore lives at android/yve-upload-keystore.jks
                // next to its config — both gitignored.
                storeFile = rootProject.file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                // Debug keys are fine for sideload-to-my-phone testing,
                // but the Play Store will reject an AAB signed this way.
                signingConfigs.getByName("debug")
            }
            // R8 keep rules. Without these, release-mode minification
            // strips reflection metadata that flutter_local_notifications
            // (Gson) and the Supabase Kotlin client (kotlinx.serialization)
            // need at runtime — captured in Sentry as "Missing type
            // parameter" on first install (2026-05-18).
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Required by isCoreLibraryDesugaringEnabled above.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")

    // image_cropper's UCropActivity extends AppCompatActivity, so we need
    // AppCompat themes available even though Flutter activities don't use
    // them. Without this the cropper crashes the app on launch with
    // "You need to use a Theme.AppCompat theme (or descendant)".
    implementation("androidx.appcompat:appcompat:1.7.0")
}
