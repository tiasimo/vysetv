import java.util.UUID

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ── Plezy player: mpv-android AAR, FFmpeg headers, libdovi ──
// Copied from Plezy's android/app/build.gradle.kts (edde746/plezy). Pins live in
// ../../mpv-build.lock.json and gradle/verification-metadata.xml.
apply(from = rootProject.file("gradle/native-artifacts.gradle.kts"))

@Suppress("UNCHECKED_CAST")
val verifySha256 = extra["verifySha256"] as (File, String, String) -> Unit

@Suppress("UNCHECKED_CAST")
val promoteDirectory = extra["promoteDirectory"] as (File, File) -> Unit

// mpv-build's mpv-android library (libmpv, FFmpeg, libc++ and the JNI glue
// with its Kotlin API, package com.edde746.mpv, one AAR), pinned in the
// repo-root mpv-build.lock.json: its key is the version, its sha256 the one
// Gradle's dependency verification checks (gradle/verification-metadata.xml,
// which scripts/set_native_revision.sh writes with the lock). Gradle fetches it
// from the GitHub release through an Ivy repository: no metadata, no
// authentication. The repository is this project's, not settings': every
// project here declares its own (root allprojects, the Flutter plugin), and
// Gradle then ignores the settings' repositories.
val mpvLockFile = rootProject.file("../mpv-build.lock.json")
val mpvAndroid = run {
  @Suppress("UNCHECKED_CAST")
  val lock = groovy.json.JsonSlurper().parse(mpvLockFile) as Map<String, Any?>
  @Suppress("UNCHECKED_CAST")
  ((lock["artifacts"] as? Map<String, Any?>)?.get("android") as? Map<String, Any?>)
    ?: throw GradleException("$mpvLockFile has no android group; run scripts/set_native_revision.sh")
}

@Suppress("UNCHECKED_CAST")
val mpvAar = mpvAndroid["aar"] as? Map<String, String>
  ?: throw GradleException("$mpvLockFile artifacts.android has no aar; run scripts/set_native_revision.sh")
val mpvVerificationFile = rootProject.file("gradle/verification-metadata.xml")
if (!mpvVerificationFile.readText().contains("<sha256 value=\"${mpvAar.getValue("checksum")}\"")) {
  throw GradleException(
    "$mpvVerificationFile doesn't check mpv-android against $mpvLockFile's sha256; run scripts/set_native_revision.sh"
  )
}
repositories {
  exclusiveContent {
    forRepository {
      ivy {
        name = "mpv-build"
        url = uri(mpvAndroid.getValue("assetBase") as String)
        patternLayout { artifact("[artifact]-[revision].[ext]") }
        metadataSources { artifact() }
      }
    }
    filter { includeModule("edde746", "mpv-android") }
  }
}
val mpvAarDependency = "edde746:mpv-android:${mpvAar.getValue("key")}@aar"

// The AAR's native libraries this build reads itself: the FFmpeg libraries the
// Media3 adapter links (CMake then packages those same bytes), and the libc++
// runtime libmpv was linked against, packaged at PROJECT scope below so it
// deterministically wins the merge over any older copy.
val mpvAarNatives = configurations.create("mpvAarNatives") {
  isCanBeConsumed = false
}
val mpvNativeDir = layout.buildDirectory.dir("mpv-android").get().asFile
val mpvFfmpegJniDir = File(mpvNativeDir, "ffmpeg/jni")
val mpvLibcxxJniDir = File(mpvNativeDir, "libcxx/jni")
val mpvAbis = listOf("arm64-v8a", "armeabi-v7a", "x86", "x86_64")
val extractMpvNatives = tasks.register<Sync>("extractMpvNatives") {
  from(provider { zipTree(mpvAarNatives.singleFile) }) {
    include("jni/*/libavcodec.so", "jni/*/libavutil.so", "jni/*/libswresample.so")
    into("ffmpeg")
  }
  from(provider { zipTree(mpvAarNatives.singleFile) }) {
    include("jni/*/libc++_shared.so")
    into("libcxx")
  }
  into(mpvNativeDir)
  includeEmptyDirs = false
  doLast {
    val missing = mpvAbis.map { abi -> File(mpvLibcxxJniDir, "$abi/libc++_shared.so") }.filterNot(File::isFile)
    if (missing.isNotEmpty()) {
      throw GradleException("$mpvAarDependency carries no libc++ runtime for: ${missing.joinToString { it.parentFile.name }}")
    }
  }
}

val media3Version = "1.11.0"
val mpvFfmpegVersion = "8.0.1"
val mpvFfmpegSourceSha256 = "679aa13a19415d5ddab91e580084e3ab20c963c8240001e5cbb955a97bdd81b1"
val mpvFfmpegSourceUrl = "https://github.com/FFmpeg/FFmpeg/archive/refs/tags/n$mpvFfmpegVersion.tar.gz"
val mpvFfmpegDevelopmentDir = layout.buildDirectory.dir("libmpv-ffmpeg-development").get().asFile

// Build the Media3 JNI adapter against the same shared FFmpeg libraries that
// libmpv packages. Headers are pinned to libmpv's FFmpeg version and remain
// build-only; the APK contains one FFmpeg implementation for both players.
// The AAR carries no headers, so they come from the FFmpeg tag mpv-build
// builds (versions.json `ffmpeg`), served by GitHub like the AAR: downloads
// from ffmpeg.org's release server failed CI runs. The Media3 adapter uses
// none of the declarations mpv-build's patches change (libavcodec/mediacodec.h,
// libavcodec/jni.h).
val prepareMpvFfmpegDevelopment = tasks.register("prepareMpvFfmpegDevelopment") {
  dependsOn(extractMpvNatives)
  val manifest = File(mpvFfmpegDevelopmentDir, ".manifest")
  val libraries = listOf("avcodec", "avutil", "swresample")
  inputs.dir(mpvFfmpegJniDir)
  inputs.property("ffmpegVersion", mpvFfmpegVersion)
  inputs.property("sourceUrl", mpvFfmpegSourceUrl)
  inputs.property("sourceSha256", mpvFfmpegSourceSha256)
  outputs.files(
    mpvAbis.flatMap { abi ->
      libraries.map { library -> File(mpvFfmpegDevelopmentDir, "native/$abi/lib$library.so") }
    }
  )
  outputs.files(
    File(mpvFfmpegDevelopmentDir, "include/libavcodec/avcodec.h"),
    File(mpvFfmpegDevelopmentDir, "include/libavutil/avconfig.h"),
    File(mpvFfmpegDevelopmentDir, "include/libswresample/swresample.h"),
    manifest
  )
  doLast {
    val staging = File(
      mpvFfmpegDevelopmentDir.parentFile,
      "${mpvFfmpegDevelopmentDir.name}.staging-${UUID.randomUUID()}"
    )
    try {
      val sourceArchive = File(staging, "ffmpeg-$mpvFfmpegVersion.tar.gz")
      val includeDir = File(staging, "include")
      val nativeDir = File(staging, "native")
      staging.mkdirs()
      try {
        providers.exec {
          commandLine("curl", "-sfL", mpvFfmpegSourceUrl, "-o", sourceArchive.absolutePath)
        }.result.get().assertNormalExitValue()
      } catch (error: Exception) {
        throw GradleException("Failed to download FFmpeg $mpvFfmpegVersion headers", error)
      }
      verifySha256(sourceArchive, mpvFfmpegSourceSha256, "FFmpeg $mpvFfmpegVersion source")

      val extractedSource = File(staging, "source").apply { mkdirs() }
      try {
        providers.exec {
          commandLine(
            "tar",
            "-xzf",
            sourceArchive.absolutePath,
            "--strip-components=1",
            "-C",
            extractedSource.absolutePath
          )
        }.result.get().assertNormalExitValue()
      } catch (error: Exception) {
        throw GradleException("Failed to extract FFmpeg $mpvFfmpegVersion headers", error)
      }
      listOf("libavcodec", "libavutil", "libswresample").forEach { library ->
        project.copy {
          from(File(extractedSource, library)) {
            include("*.h")
          }
          into(File(includeDir, library))
        }
      }
      File(includeDir, "libavutil/avconfig.h").writeText(
        """
        |/* Generated for Plezy's little-endian Android ABIs. */
        |#ifndef AVUTIL_AVCONFIG_H
        |#define AVUTIL_AVCONFIG_H
        |#define AV_HAVE_BIGENDIAN 0
        |#define AV_HAVE_FAST_UNALIGNED 0
        |#endif /* AVUTIL_AVCONFIG_H */
        |
        """.trimMargin()
      )

      project.copy {
        from(mpvFfmpegJniDir) {
          include(libraries.map { library -> "*/lib$library.so" })
        }
        includeEmptyDirs = false
        into(nativeDir)
      }

      val missing = mpvAbis.flatMap { abi ->
        libraries.map { library -> File(nativeDir, "$abi/lib$library.so") }
      }.filterNot(File::isFile)
      if (missing.isNotEmpty()) {
        throw GradleException(
          "$mpvAarDependency is missing FFmpeg libraries: ${missing.joinToString { it.relativeTo(staging).path }}"
        )
      }
      File(staging, ".manifest").writeText(
        "ffmpeg=$mpvFfmpegVersion\nsourceSha256=$mpvFfmpegSourceSha256\n"
      )
      sourceArchive.delete()
      extractedSource.deleteRecursively()
      promoteDirectory(staging, mpvFfmpegDevelopmentDir)
    } finally {
      staging.deleteRecursively()
    }
  }
}

val doviVersion = "2.3.1"
val doviDir = layout.buildDirectory.dir("libdovi").get().asFile
val doviArtifacts = mapOf(
  "arm64-v8a" to Pair(
    "aarch64-linux-android",
    "9d2983fc86f2f9e6da54c3c84ba8ea3a528690619f312ff4620198071b84e9ae"
  ),
  "armeabi-v7a" to Pair(
    "armv7-linux-androideabi",
    "ed6fec8bf744e41c661b97f5fc4bf1197ebe9b09a140cbde369728e790ee3a68"
  ),
  "x86" to Pair(
    "i686-linux-android",
    "50f0a5606e617dff8976b9e7930a23272f4804882a35a6f0f2b2f2d3f8ed7135"
  ),
  "x86_64" to Pair(
    "x86_64-linux-android",
    "eba59678f89b792f5c6f802962e237542fe8328f6aa03a0a90ee77353dac3194"
  )
)
val doviBaseUrl = "https://github.com/edde746/libdovi-builds/releases/download/v$doviVersion"

val downloadLibdovi = tasks.register("downloadLibdovi") {
  val manifest = File(doviDir, ".manifest")
  inputs.property("version", doviVersion)
  inputs.property("baseUrl", doviBaseUrl)
  doviArtifacts.forEach { (abi, artifact) ->
    inputs.property("$abi.triple", artifact.first)
    inputs.property("$abi.sha256", artifact.second)
    inputs.property("$abi.sourceUrl", "$doviBaseUrl/libdovi-${artifact.first}.tar.gz")
  }
  outputs.files(doviArtifacts.keys.map { abi -> File(doviDir, "$abi/lib/libdovi.a") } + manifest)
  doLast {
    doviDir.parentFile.mkdirs()
    val staging = File(doviDir.parentFile, "${doviDir.name}.staging-${UUID.randomUUID()}")
    try {
      staging.mkdirs()
      val downloads = File(staging, ".downloads").apply { mkdirs() }
      doviArtifacts.forEach { (abi, artifact) ->
        val (triple, expectedSha256) = artifact
        val archiveName = "libdovi-$triple.tar.gz"
        val archive = File(downloads, archiveName)
        val sourceUrl = "$doviBaseUrl/$archiveName"
        try {
          providers.exec {
            commandLine("curl", "-sfL", sourceUrl, "-o", archive.absolutePath)
          }.result.get().assertNormalExitValue()
        } catch (error: Exception) {
          throw GradleException("Failed to download $archiveName v$doviVersion", error)
        }
        verifySha256(archive, expectedSha256, "$archiveName v$doviVersion")

        val outDir = File(staging, "$abi/lib").apply { mkdirs() }
        try {
          providers.exec {
            commandLine("tar", "-xzf", archive.absolutePath, "-C", outDir.absolutePath)
          }.result.get().assertNormalExitValue()
        } catch (error: Exception) {
          throw GradleException("Failed to extract $archiveName", error)
        }
        if (!File(outDir, "libdovi.a").isFile) {
          throw GradleException("$archiveName did not contain the expected libdovi.a")
        }
      }
      if (!downloads.deleteRecursively()) {
        throw GradleException("Failed to clean staged libdovi archives")
      }
      val manifestText = buildString {
        append("version=$doviVersion\n")
        doviArtifacts.forEach { (abi, artifact) ->
          append("$abi=${artifact.first},${artifact.second}\n")
        }
      }
      File(staging, ".manifest").writeText(manifestText)
      promoteDirectory(staging, doviDir)
    } finally {
      staging.deleteRecursively()
    }
  }
}
// ── end Plezy player ──

android {
    namespace = "com.vyse.vyse_tv"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // flutter_local_notifications needs the newer Java APIs on older Android versions
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Plezy player native code (Dolby Vision bridge + Media3 FFmpeg audio adapter)
        externalNativeBuild {
            cmake {
                arguments += listOf(
                    "-DDOVI_ENABLE_LIBDOVI=ON",
                    "-DDOVI_LIBDOVI_PREBUILT_ROOT=${doviDir.absolutePath}",
                    "-DMPV_FFMPEG_ROOT=${mpvFfmpegDevelopmentDir.absolutePath}"
                )
            }
        }
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.tiasimo.lorewatch"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // Plezy's mpv-android AAR needs API 25 or newer
        minSdk = 25
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // the torrent engine runs as a program from the app's native-library folder, so those files
    // must be unpacked on install (not read from inside the APK)
    packaging {
        jniLibs {
            useLegacyPackaging = true
            // Plezy player: the mpv-android AAR's libc++ wins (see sourceSets below)
            pickFirsts.add("lib/*/libc++_shared.so")
        }
    }

    sourceSets {
        getByName("main") {
            // Plezy player: project-scope jniLibs merge ahead of AARs, so the libc++
            // libmpv was linked against always ships.
            jniLibs.srcDir(mpvLibcxxJniDir)
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1" // installed CMake (Plezy pins 4.1.2); CMakeLists needs >= 3.22.1
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
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

// Plezy player task wiring
tasks.matching { it.name.contains("CMake") || it.name.contains("externalNative") }.configureEach {
  dependsOn(downloadLibdovi, prepareMpvFfmpegDevelopment)
}

tasks.matching { it.name.startsWith("pre") && it.name.endsWith("Build") }.configureEach {
  dependsOn(prepareMpvFfmpegDevelopment)
}
// Gradle snapshots jniLibs source dirs before task execution; this keeps the
// extracted libc++ directory present during input discovery.
tasks.matching { it.name.startsWith("merge") && it.name.endsWith("JniLibFolders") }.configureEach {
  dependsOn(extractMpvNatives)
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")

    // ── Plezy player ──
    // mpv-build's mpv-android: libmpv, FFmpeg and the JNI glue (com.edde746.mpv)
    implementation(mpvAarDependency)
    mpvAarNatives(mpvAarDependency)
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.11.0")
    // Media3 ExoPlayer (Plezy's opt-in fallback backend; the mpv core uses a few of its helpers)
    implementation("androidx.media3:media3-decoder:$media3Version")
    implementation("androidx.media3:media3-exoplayer:$media3Version")
    implementation("androidx.media3:media3-exoplayer-hls:$media3Version")
    implementation("androidx.media3:media3-ui:$media3Version")
    implementation("androidx.media3:media3-common:$media3Version")
    implementation("androidx.media3:media3-datasource-cronet:$media3Version")
    implementation("org.chromium.net:cronet-embedded:143.7445.0")
    implementation(project(":libass"))
}
