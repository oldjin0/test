plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.oldjin.meetnote"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.oldjin.meetnote"
        minSdk = 29
        targetSdk = 34
        // CI(GitHub Actions)가 빌드마다 번호를 올린다. 앱 내 업데이트 비교에 사용.
        val build = System.getenv("GITHUB_RUN_NUMBER")?.toIntOrNull() ?: 1
        versionCode = build
        versionName = "1.0.$build"
        // 기기 내 인식(sherpa-onnx) 네이티브 라이브러리는 휴대폰용 ABI만 포함
        ndk { abiFilters += listOf("arm64-v8a", "armeabi-v7a") }
        buildConfigField("String", "GIT_SHA", "\"${System.getenv("GITHUB_SHA")?.take(7) ?: "dev"}\"")
    }

    // 업데이트 설치가 가능하도록 항상 같은 키로 서명한다.
    signingConfigs {
        create("meetnote") {
            storeFile = rootProject.file("meetnote.keystore")
            storePassword = "meetnote"
            keyAlias = "meetnote"
            keyPassword = "meetnote"
        }
    }
    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("meetnote")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    packaging {
        jniLibs {
            useLegacyPackaging = true
            pickFirsts += "**/libc++_shared.so"
        }
    }
    lint {
        checkReleaseBuilds = false
        abortOnError = false
    }
    buildFeatures {
        compose = true
        buildConfig = true
    }
}

dependencies {
    implementation(platform("androidx.compose:compose-bom:2024.09.00"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-core")
    implementation("androidx.activity:activity-compose:1.9.2")
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")
    implementation("androidx.media3:media3-exoplayer:1.4.1")
    implementation("org.apache.commons:commons-compress:1.27.1") // 기기 내 인식 모델(.tar.bz2) 풀기
}
