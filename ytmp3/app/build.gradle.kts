plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.example.ytmp3"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.example.ytmp3"
        minSdk = 29
        targetSdk = 34
        versionCode = 1
        versionName = "1.0"
        ndk {
            abiFilters += listOf("arm64-v8a", "armeabi-v7a")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }

    packaging {
        // youtubedl-android unpacks python/ffmpeg from native libs at runtime
        jniLibs.useLegacyPackaging = true
    }
}

dependencies {
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("com.google.android.material:material:1.12.0")
    implementation("io.github.junkfood02.youtubedl-android:library:0.17.2")
    implementation("io.github.junkfood02.youtubedl-android:ffmpeg:0.17.2")
}
