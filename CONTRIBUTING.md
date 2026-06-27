# Contributing

Thanks for taking a look at Doit.

Before opening a pull request:

1. Read [`README.md`](README.md) for the supported deployment modes.
2. Read [`docs/security-model.md`](docs/security-model.md) before changing auth,
   admin tooling, runner credentials, storage, or user data flows.
3. Read [`docs/task-realtime.md`](docs/task-realtime.md) before changing the iOS
   task list, detail view, `TodoRealtimeHub`, or `TodoStore`.

## Local Configuration

Use local `.env` files and placeholder examples. Do not commit real secrets,
private keys, production project refs, waitlist exports, or generated local
artifacts.

## iOS Verification

After changing iOS task list/detail/realtime behavior, run:

```bash
cd ios/doit
xcodebuild -project doit.xcodeproj -scheme doit \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -configuration Debug build \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO
```

## Backend Verification

For runner changes, run the relevant Python tests from `runner/` and manually
verify that task state still flows through Supabase Realtime into the app.
