pluginManagement {
  repositories {
    google()
    maven { url = uri("https://storage.googleapis.com/maven-central/maven2") }
    mavenCentral()
    gradlePluginPortal()
  }
}
dependencyResolutionManagement {
  repositories {
    google()
    // Prefer Google's Maven Central mirror to avoid transient 429s from the
    // shared Maven Central egress used by GitHub-hosted runners.
    maven { url = uri("https://storage.googleapis.com/maven-central/maven2") }
    mavenCentral()
  }
}
rootProject.name = "romm-isolation-tests"
