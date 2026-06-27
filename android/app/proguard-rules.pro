# Keep raw resources (ringtone) from being stripped
-keep class **.R$raw { *; }

# Flutter local notifications
-keep class com.dexterous.** { *; }

# Firebase Messaging
-keep class com.google.firebase.messaging.** { *; }

# Flutter
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# Prevent stripping of FCM background handler entry point
-keepclassmembers class * {
    @com.google.firebase.messaging.** *;
}

# Play Core (used by Flutter deferred components) — ignore missing classes
-dontwarn com.google.android.play.core.splitcompat.SplitCompatApplication
-dontwarn com.google.android.play.core.splitinstall.**
-dontwarn com.google.android.play.core.tasks.**
