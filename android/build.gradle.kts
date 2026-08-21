allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

// 1. Configure namespace early (when plugins are applied)
subprojects {
    plugins.withId("com.android.library") {
        val android = extensions.findByType<com.android.build.gradle.BaseExtension>()
        if (android != null && android.namespace == null) {
            val manifestFile = project.file("src/main/AndroidManifest.xml")
            var pkg: String? = null
            if (manifestFile.exists()) {
                val content = manifestFile.readText()
                val match = Regex("""package=["']([^"']+)["']""").find(content)
                pkg = match?.groupValues?.get(1)
            }
            android.namespace = pkg ?: "com.example.${project.name.replace('-', '_').replace('.', '_')}"
        }
    }
    plugins.withId("com.android.application") {
        val android = extensions.findByType<com.android.build.gradle.BaseExtension>()
        if (android != null && android.namespace == null) {
            val manifestFile = project.file("src/main/AndroidManifest.xml")
            var pkg: String? = null
            if (manifestFile.exists()) {
                val content = manifestFile.readText()
                val match = Regex("""package=["']([^"']+)["']""").find(content)
                pkg = match?.groupValues?.get(1)
            }
            android.namespace = pkg ?: "com.example.${project.name.replace('-', '_').replace('.', '_')}"
        }
    }
}

// 2. Configure compileSdkVersion during afterEvaluate (registered BEFORE subproject evaluation starts)
subprojects {
    afterEvaluate {
        val android = extensions.findByType<com.android.build.gradle.BaseExtension>()
        if (android != null) {
            android.compileSdkVersion(36)
        }
    }
}

// 3. Make sure subprojects evaluation depends on :app (this triggers the evaluation of all subprojects)
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
