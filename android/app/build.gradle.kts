plugins { id("com.android.application"); id("org.jetbrains.kotlin.plugin.compose") }
android {
    namespace = "guide.guidelabs.codexdrop"
    compileSdk = 37
    defaultConfig { applicationId = "guide.guidelabs.codexdrop"; minSdk = 28; targetSdk = 37; versionCode = 1; versionName = "1.0" }
    buildFeatures { compose = true }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
}
dependencies { implementation(project(":core")) }
