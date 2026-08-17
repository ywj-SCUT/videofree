# Android build cache

The Android release build keeps `media_kit` native JARs in
`.android-build-cache/media_kit_libs_android_video` instead of Flutter's
disposable `mobile/build` directory. Do not remove that directory during
normal cleanup; it prevents the four ABI libraries from being downloaded
again.

Use the tracked wrapper from the repository root:

```powershell
.\scripts\build-android-release.ps1
```

It reuses the ASCII `PUB_CACHE`, applies the local `127.0.0.1:7890` proxy
when it is listening, and uses `--no-pub` unless `-ResolveDependencies` is
provided. For a quick AVD-only build, pass `-TargetPlatform android-x64`.
The final release APK must be built without `-TargetPlatform` so all Android
ABIs are included.

The wrapper also pins `GRADLE_USER_HOME` to the existing
`C:\Users\杨万杰\.gradle` cache, including when Codex runs as `SYSTEM`.
Override it with `VIDEOGET_GRADLE_USER_HOME` only when intentionally moving
the persistent Gradle cache. Do not delete either persistent cache during
release cleanup.
