# The engine finds this class by name from the manifest meta-data and calls its
# @UsedByGodot methods by name over JNI, so R8 must not rename or strip either.
-keep class com.slacumcity.nativeplugin.SlacumNative { *; }
-keep class org.godotengine.godot.plugin.** { *; }
