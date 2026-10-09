# NewPipeExtractor (README + NewPipe app proguard-rules.pro, v0.29.1).
-keep class org.schabi.newpipe.extractor.timeago.patterns.** { *; }
-keep class org.mozilla.javascript.* { *; }
-keep class org.mozilla.javascript.** { *; }
-keep class org.mozilla.javascript.engine.** { *; }
-keep class org.mozilla.classfile.ClassFileWriter
-dontwarn org.mozilla.javascript.JavaToJSONConverters
-dontwarn org.mozilla.javascript.tools.**
-keep class javax.script.** { *; }
-dontwarn javax.script.**
-keep class jdk.dynalink.** { *; }
-dontwarn jdk.dynalink.**
-dontwarn java.beans.**

# protobuf-javalite (used by the extractor for YouTube requests) reads fields reflectively.
-keepclassmembers class * extends com.google.protobuf.GeneratedMessageLite {
    <fields>;
}

-dontwarn okhttp3.**
-dontwarn okio.**
-dontwarn org.jsoup.**
-dontwarn javax.annotation.**

# Methods called from JavaScript in the poToken WebView.
-keepclassmembers class com.heardy.ytstream.potoken.PoTokenWebView {
    @android.webkit.JavascriptInterface <methods>;
}
