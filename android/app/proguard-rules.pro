# Conscrypt / sun-security 在编译期引用的平台相关类，运行时才存在。
-dontwarn com.android.org.conscrypt.**
-dontwarn org.apache.harmony.xnet.provider.jsse.**
-dontwarn org.conscrypt.**

# Shizuku：通过反射调用私有的 Shizuku.newProcess，需保留类与方法名。
-keep class rikka.shizuku.** { *; }
-keep class moe.shizuku.** { *; }

# libadb：ADB 连接与配对。
-keep class io.github.muntashirakon.adb.** { *; }

# sun-security-android：生成自签名证书。
-keep class android.sun.security.** { *; }

# Conscrypt（自定义 TLS 提供者）。
-keep class org.conscrypt.** { *; }
