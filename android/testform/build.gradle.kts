// A one-screen sign-in form used only to test AZET Pass autofill on an emulator (not shipped).
plugins { id("com.android.application") }
android {
    namespace = "io.azet.testform"
    compileSdk = 37
    defaultConfig { applicationId = "io.azet.testform"; minSdk = 29; targetSdk = 37; versionCode = 1; versionName = "1" }
}
