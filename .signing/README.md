# Android release signing invariant

All `com.videoget.mobile` release APKs must use the existing certificate below:

```text
SHA-256: f9a529fd73bb2193a805e6b2d09d39cf4f006d998aaa3e7b85f6a841391b5e1a
```

The private key is stored locally at `.signing/videoget-release.keystore` and is intentionally ignored by Git. Its expected file SHA-256 is:

```text
aac11e13e92fded53d28728314311eed00fbfb118bb4d302700618acd8f5628f
```

Local backup: `D:\Android\User\debug.keystore`.

Rules:

1. Never generate or substitute a keystore for a release build.
2. Never change the certificate fingerprint or `fixedRelease` signing configuration to make a build pass.
3. If the local key is missing, restore the exact backup and verify both hashes before building.
4. Run `npm run verify:android-signature` for every release APK before installation or upload.
5. A release is invalid if the signing verifier does not print the expected certificate.
