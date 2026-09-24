# Flutter
-keep class io.flutter.** { *; }
-dontwarn io.flutter.embedding.**

# youtubedl-android (Jackson mapping + reflective process handling)
-keep class com.yausername.** { *; }
-keep class com.fasterxml.jackson.** { *; }
-dontwarn com.fasterxml.jackson.**
-keepclassmembers class * { @com.fasterxml.jackson.annotation.* *; }
# The bundled Python/ffmpeg/aria2c payloads are unpacked with commons-compress, which instantiates
# its zip extra-field classes reflectively: shrunk, that dies with "class ... is not a concrete class"
# and YoutubeDL.init fails (release builds only!).
-keep class org.apache.commons.compress.** { *; }
-keep class org.apache.commons.io.** { *; }
-keep class org.tukaani.xz.** { *; }
-dontwarn org.apache.commons.compress.**
-dontwarn org.tukaani.xz.**
-dontwarn com.github.luben.zstd.**
-dontwarn org.brotli.dec.**

# jaudiotagger looks up tag classes reflectively and references desktop-only APIs
-keep class org.jaudiotagger.** { *; }
-dontwarn org.jaudiotagger.**
-dontwarn java.awt.**
-dontwarn javax.imageio.**
-dontwarn javax.swing.**
-dontwarn java.beans.**

# audio_service
-keep class com.ryanheise.audioservice.** { *; }

# Our plugins are only referenced through method channels
-keep class dev.personal.musicplayer.** { *; }
