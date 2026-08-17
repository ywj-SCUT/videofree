allprojects {
    repositories {
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/public") }
        google()
        mavenCentral()
    }

    configurations.configureEach {
        resolutionStrategy.force(
            "androidx.test:runner:1.3.0",
            "androidx.test:rules:1.2.0",
            "androidx.test.espresso:espresso-core:3.3.0",
        )
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

// Keep media_kit's downloaded native JARs outside Flutter's disposable build tree.
val persistentMediaKitBuildDir: Directory =
    rootProject.layout.projectDirectory
        .dir("../../.android-build-cache/media_kit_libs_android_video")

subprojects {
    val newSubprojectBuildDir: Directory = if (project.name == "media_kit_libs_android_video") {
        persistentMediaKitBuildDir
    } else {
        newBuildDir.dir(project.name)
    }
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
