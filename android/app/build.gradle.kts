import java.util.Properties

plugins { id("com.android.application"); id("org.jetbrains.kotlin.plugin.compose") }
// Keep signing credentials in ignored local.properties or environment variables.
// An unconfigured release is unsigned; explicit incomplete configuration is an error.
val localSigningProperties = Properties().apply {
    val propertiesFile = rootProject.file("local.properties")
    if (propertiesFile.isFile) propertiesFile.inputStream().use { load(it) }
}
fun releaseSigningValue(property: String, environment: String): String? =
    providers.environmentVariable(environment).orNull ?: localSigningProperties.getProperty(property)
val releaseStoreFile = releaseSigningValue("codexDrop.storeFile", "CODEX_DROP_ANDROID_STORE_FILE")
val releaseStorePassword = releaseSigningValue("codexDrop.storePassword", "CODEX_DROP_ANDROID_STORE_PASSWORD")
val releaseKeyAlias = releaseSigningValue("codexDrop.keyAlias", "CODEX_DROP_ANDROID_KEY_ALIAS")
val releaseKeyPassword = releaseSigningValue("codexDrop.keyPassword", "CODEX_DROP_ANDROID_KEY_PASSWORD")
val releaseSigningValues = listOf(releaseStoreFile, releaseStorePassword, releaseKeyAlias, releaseKeyPassword)
val hasReleaseSigning = releaseSigningValues.any { it != null }
require(!hasReleaseSigning || releaseSigningValues.all { !it.isNullOrBlank() }) {
    "Incomplete Android release signing: configure all four codexDrop signing properties or CODEX_DROP_ANDROID signing environment variables."
}

android {
    namespace = "guide.guidelabs.codexdrop"
    compileSdk = 37
    defaultConfig { applicationId = "guide.guidelabs.codexdrop"; minSdk = 28; targetSdk = 37; versionCode = 5; versionName = "1.0"; testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner" }
    if (hasReleaseSigning) {
        val persistentRelease = signingConfigs.create("persistentRelease") {
            // Relative paths resolve from android/, alongside local.properties.
            storeFile = rootProject.file(requireNotNull(releaseStoreFile))
            storePassword = releaseStorePassword
            keyAlias = releaseKeyAlias
            keyPassword = releaseKeyPassword
        }
        buildTypes.getByName("release").signingConfig = persistentRelease
    }
    buildFeatures { compose = true }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
}
dependencies {
    implementation(project(":core"))
    implementation(platform("androidx.compose:compose-bom:2026.09.00"))
    implementation("androidx.activity:activity-compose:1.11.0")
    // Code Scanner otherwise brings an obsolete Fragment release.
    implementation("androidx.fragment:fragment:1.8.9")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-core")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.10.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.10.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-play-services:1.10.2")
    implementation("com.google.android.gms:play-services-code-scanner:16.1.0")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.10.2")
    androidTestImplementation(platform("androidx.compose:compose-bom:2026.09.00"))
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    // API 37 removed the hidden InputManager method used by Espresso 3.5.
    androidTestImplementation("androidx.test.espresso:espresso-core:3.7.0")
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test:core-ktx:1.7.0")
}
