plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("org.jetbrains.kotlin.plugin.serialization")
}

val releaseStore = System.getenv("METERKAT_KEYSTORE_PATH")
val signingValues = listOf("METERKAT_STORE_PASSWORD", "METERKAT_KEY_ALIAS", "METERKAT_KEY_PASSWORD")
require(releaseStore == null || signingValues.all { !System.getenv(it).isNullOrBlank() }) {
    "Release signing requires all METERKAT signing environment variables"
}

android {
    namespace = "com.sahil.meterkat.wear"
    compileSdk = 36
    defaultConfig {
        applicationId = "com.sahil.meterkat.wear"
        minSdk = 30
        targetSdk = 35
        versionCode = 2
        versionName = "2.3.0"
    }
    signingConfigs {
        if (releaseStore != null) {
            create("release") {
                storeFile = file(releaseStore)
                storePassword = System.getenv("METERKAT_STORE_PASSWORD")
                keyAlias = System.getenv("METERKAT_KEY_ALIAS")
                keyPassword = System.getenv("METERKAT_KEY_PASSWORD")
            }
        }
    }
    buildTypes {
        release {
            if (releaseStore != null) signingConfig = signingConfigs.getByName("release")
        }
    }
    buildFeatures { compose = true }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) } }

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2025.08.00")
    implementation(composeBom)
    implementation("androidx.activity:activity-compose:1.10.1")
    implementation("androidx.wear.compose:compose-material:1.4.1")
    implementation("androidx.wear.compose:compose-foundation:1.4.1")
    implementation("androidx.wear:wear:1.3.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.9.2")
    implementation("com.google.android.gms:play-services-wearable:18.2.0")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.9.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-play-services:1.10.2")
}
