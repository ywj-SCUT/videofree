# Project execution constraints

## Android installation target

- Install, launch, and verify Android builds on the phone's main user (`user 0`) by default.
- Use `adb install -r --user 0 <APK>` for an in-place update that preserves app data.
- Do not install to another Android user/profile unless the user explicitly requests it.
- Do not uninstall the existing package or clear its data as part of an update.

## Android release signing

- Every `com.videoget.mobile` release must follow `.signing/README.md`.
- The certificate SHA-256 must remain `f9a529fd73bb2193a805e6b2d09d39cf4f006d998aaa3e7b85f6a841391b5e1a`.
- Run `npm run verify:android-signature` before installing or publishing an APK.
