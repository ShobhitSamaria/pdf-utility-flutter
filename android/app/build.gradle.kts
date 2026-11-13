import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing credentials live outside version control. The file is
// created by the project owner and is never read into the build log.
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseSigning = keystorePropertiesFile.exists()
val keystoreProperties = Properties()
if (hasReleaseSigning) {
    FileInputStream(keystorePropertiesFile).use { keystoreProperties.load(it) }
}

android {
    namespace = "com.shobhit.pdfutility.pdf_utility_flutter"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.shobhit.pdfutility.pdf_utility_flutter"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = keystoreProperties.getProperty("storeFile")?.let { file(it) }
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            // Production artifacts use the owner's upload key only. When
            // key.properties is absent the build fails below rather than
            // silently falling back to the debug certificate.
            signingConfig = signingConfigs.findByName("release")
            // NOTE: no proguardFiles() here on purpose. When shrinking is
            // enabled, Flutter's Gradle plugin already adds the default rules,
            // its own `flutter_proguard_rules.pro`, and
            // `android/app/proguard-rules.pro` if that file exists (see
            // FlutterPlugin.kt). Declaring them again would duplicate the
            // defaults for no benefit.
        }
    }
}

// Refuse to produce an unsigned or debug-signed production artifact. Debug
// builds and debug signing are untouched.
if (!hasReleaseSigning) {
    gradle.taskGraph.whenReady {
        val releaseArtifact = allTasks.any {
            it.name == "bundleRelease" ||
                it.name == "assembleRelease" ||
                it.name == "packageReleaseBundle"
        }
        if (releaseArtifact) {
            throw GradleException(
                "Release signing is not configured. Create android/key.properties " +
                    "with storePassword, keyPassword, keyAlias and storeFile."
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // ML Kit Translate model classes (RemoteModelManager, TranslateRemoteModel,
    // DownloadConditions) used by our own `pdf_utility/model_manager` channel in
    // MainActivity.kt. Same artifact and exact version the
    // google_mlkit_translation plugin already resolves at runtime — 17.0.3 is
    // the latest com.google.mlkit:translate release (08/07/2024), so there is
    // nothing newer to pin.
    implementation("com.google.mlkit:translate:17.0.3")

    // Bundled Devanagari (Hindi) script model for ML Kit Text Recognition.
    //
    // `google_mlkit_text_recognition` declares the non-Latin script models as
    // `compileOnly` (see its android/build.gradle), which means the plugin
    // compiles against them but does NOT package them. The app must supply
    // them itself, exactly like the Latin model that ships with
    // `com.google.mlkit:text-recognition`. Without this line the plugin's
    // `initialize(script = 2)` path cannot resolve
    // `DevanagariTextRecognizerOptions`, so Hindi recognition fails at runtime
    // instead of merely returning poor results.
    //
    // 16.0.1 is the current release of this artifact (verified against
    // https://dl.google.com/dl/android/maven2/com/google/mlkit/
    // text-recognition-devanagari/maven-metadata.xml) and it matches the exact
    // version the plugin's `compileOnly` coordinate pins, so there is no
    // version skew to manage. Bundled (not `play-services-mlkit-*`) on purpose:
    // the model then ships in the APK and Hindi OCR works offline on first run,
    // with no download step that can stall the way the translation models did.
    implementation("com.google.mlkit:text-recognition-devanagari:16.0.1")
}

flutter {
    source = "../.."
}
