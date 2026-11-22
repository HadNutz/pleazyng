pluginManagement {
  repositories {
    google()
    maven { url = uri("https://storage.googleapis.com/maven-central/maven2") }
    mavenCentral()
    gradlePluginPortal()
  }
}
dependencyResolutionManagement { repositories { google(); mavenCentral() } }
rootProject.name = "romm-isolation-tests"
