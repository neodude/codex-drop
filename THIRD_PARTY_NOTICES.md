# Third-party components

The repository's MIT license covers original Codex Drop source and artwork.
It does not replace dependency licenses or grant third-party trademark rights.

## Included in this repository

The Gradle Wrapper scripts and `android/gradle/wrapper/gradle-wrapper.jar`
come from Gradle and are licensed under Apache License 2.0. Original notices
remain in the scripts, and the JAR includes its license at `META-INF/LICENSE`.
An unchanged copy is provided in [third_party/gradle-wrapper-LICENSE.txt](third_party/gradle-wrapper-LICENSE.txt).
See [Gradle's license](https://github.com/gradle/gradle/blob/master/LICENSE).

## Dependencies obtained when building

The Android build downloads dependencies rather than vendoring their source:
AndroidX and Compose, Kotlin/coroutines, Moshi, OkHttp/Okio, Google Play services
Code Scanner, and test tooling. Most listed open-source libraries use Apache
License 2.0; each resolved component's own license and notices govern it.
Google Play services also has SDK-specific terms. The project MIT license does
not relicense those SDKs, the Android SDK, Xcode, or platform frameworks.

The declarations are in `android/app/build.gradle.kts`,
`android/core/build.gradle.kts`, and the root Gradle settings. Before distributing
compiled applications, inventory the exact resolved runtime dependencies and
include their required notices; a source-only release is not an attribution
review of every future binary distribution.

- [AndroidX licenses](https://android.googlesource.com/platform/frameworks/support/+/androidx-main/LICENSE.txt)
- [Kotlin license](https://github.com/JetBrains/kotlin/blob/master/license/LICENSE.txt)
- [Kotlin coroutines license](https://github.com/Kotlin/kotlinx.coroutines/blob/master/LICENSE.txt)
- [Moshi license](https://github.com/square/moshi/blob/master/LICENSE.txt)
- [OkHttp license](https://github.com/square/okhttp/blob/master/LICENSE.txt)
- [Google Play services terms](https://developers.google.com/android/guides/terms)

## Product names and artwork

Codex and OpenAI identify the integration target. No affiliation or endorsement
is claimed. Current project artwork is documented in [assets/README.md](assets/README.md).
