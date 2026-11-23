# UniFFI bindings call into JNA by reflection and name; keep them and JNA whole.
-keep class com.bitwarden.** { *; }
-keep class uniffi.** { *; }
-keep class com.sun.jna.** { *; }
-keepclassmembers class * extends com.sun.jna.** { public *; }
-dontwarn java.awt.**
-dontwarn com.sun.jna.**
