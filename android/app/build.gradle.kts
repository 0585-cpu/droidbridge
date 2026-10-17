plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "io.droidbridge"
    compileSdk = 36
    ndkVersion = "27.1.12297006"
    externalNativeBuild { cmake { path = file("src/main/cpp/CMakeLists.txt"); version = "3.22.1" } }

    defaultConfig {
        applicationId = "io.droidbridge.android"
        minSdk = 26
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0-b1"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
        create("profileable") {
            initWith(getByName("release"))
            isDebuggable = false
            isJniDebuggable = false
            // Local measurement builds update the existing app without losing its pairing.
            signingConfig = signingConfigs.getByName("debug")
            versionNameSuffix = "-profileable"
            matchingFallbacks += listOf("release")
        }
    }

    // Select profileable only for its device checks; normal debug tests stay unchanged.
    testBuildType = providers.gradleProperty("droidbridgeTestBuildType").getOrElse("debug")

    buildFeatures {
        compose = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    testOptions {
        unitTests.isIncludeAndroidResources = true
        // JDK17's NIO adaptor on macOS drops connected empty datagrams; use the plain
        // implementation for framework-free loopback tests. Android's empty-send workaround
        // is checked separately by the on-device UDP tests.
        unitTests.all { it.jvmArgs("-Djdk.net.usePlainDatagramSocketImpl=true"); it.systemProperty("droidbridge.protocolVectors", rootProject.file("../protocol/test-vectors").absolutePath) }
    }
}

java {
    toolchain {
        languageVersion.set(JavaLanguageVersion.of(17))
    }
}

dependencies {
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.material3)
    implementation(libs.compose.ui.tooling.preview)
    implementation(libs.activity.compose)
    implementation(libs.lifecycle.viewmodel.compose)
    implementation(libs.lifecycle.runtime.compose)
    implementation(libs.lifecycle.runtime.compose.android)
    implementation(libs.coroutines.android)

    testImplementation(libs.junit4)
    testImplementation(libs.kotlin.test)
    testImplementation(libs.coroutines.test)
    testImplementation(libs.robolectric)
    testImplementation(libs.androidx.test.core)

    androidTestImplementation(libs.junit4)
    androidTestImplementation(libs.kotlin.test)
    androidTestImplementation(libs.coroutines.android)
    androidTestImplementation(libs.androidx.test.core)
    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.espresso.core)
}
