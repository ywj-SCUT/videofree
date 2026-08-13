plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val generatedPluginRegistrant = layout.projectDirectory.file(
    "src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java",
)

val integrationTestRegistration = Regex(
    """(?ms)\s*try \{\s*flutterEngine\.getPlugins\(\)\.add\(new dev\.flutter\.plugins\.integration_test\.IntegrationTestPlugin\(\)\);\s*}\s*catch \(Exception e\) \{\s*Log\.e\(TAG, "Error registering plugin integration_test, dev\.flutter\.plugins\.integration_test\.IntegrationTestPlugin", e\);\s*}""",
)

// Flutter omits dev plugins from the Release dependency graph, but `pub get`
// can leave integration_test in the generated Java registrant after device tests.
val prepareReleasePluginRegistrant by tasks.registering {
    inputs.file(generatedPluginRegistrant)

    doLast {
        val registrant = generatedPluginRegistrant.asFile
        if (!registrant.exists()) {
            return@doLast
        }

        val source = registrant.readText()
        val sanitized = source.replace(integrationTestRegistration, "")
        check(!sanitized.contains("IntegrationTestPlugin")) {
            "Could not remove integration_test from GeneratedPluginRegistrant for Release."
        }
        if (sanitized != source) {
            registrant.writeText(sanitized)
        }
    }
}

tasks.configureEach {
    if (name == "compileReleaseJavaWithJavac") {
        dependsOn(prepareReleasePluginRegistrant)
    }
}

android {
    namespace = "com.videoget.videoget_mobile"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.videoget.mobile"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
