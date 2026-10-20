plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.oldjin.webtv"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.oldjin.webtv"
        minSdk = 24
        targetSdk = 34
        // CI passes -PversionCode=<run number> so every build installs over the last.
        versionCode = (project.findProperty("versionCode") as String?)?.toInt() ?: 1
        versionName = "1.0.$versionCode"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}
