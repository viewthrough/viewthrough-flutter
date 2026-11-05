# Viewthrough SDK for Flutter

Installs, onboarding, paywall and checkout events from your Flutter app —
batched, offline-safe, no dependencies. Pure Dart: works on iOS and Android
(Flutter web uses the [JavaScript SDK](https://www.npmjs.com/package/@viewthrough/sdk)).

## Install

Pick one:

- **One file.** Download
  [`viewthrough.dart`](https://viewthrough.app/sdk/viewthrough.dart) into
  `lib/` and `import 'viewthrough.dart';`. Nothing else to add.
- **Git dependency** in `pubspec.yaml`:
  ```yaml
  dependencies:
    viewthrough:
      git:
        url: https://github.com/jonathannoelschaefer-code/ugc-lift.git
        path: packages/sdk-flutter
  ```
  then `import 'package:viewthrough/viewthrough.dart';`.
- pub.dev follows.

## Setup

Create the client once at startup, with a storage so the device id survives
restarts. The key is the app's write key from **Sources → SDK** in
Viewthrough (`vts_…`); it can only send events, never read.

```dart
import 'dart:io' show Platform;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:viewthrough/viewthrough.dart';

late final Viewthrough vt;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  vt = Viewthrough(
    key: 'vts_…',
    platform: Platform.isIOS ? 'ios' : 'android',  // detected when omitted
    appVersion: '2.4.1',                       // e.g. from package_info_plus
    storage: SharedPreferencesStorage(prefs),  // adapter below
  );
  runApp(const MyApp());
}

/// The SDK only needs read/write/remove; wrap whatever you already use.
class SharedPreferencesStorage implements ViewthroughStorage {
  SharedPreferencesStorage(this.prefs);
  final SharedPreferences prefs;
  @override Future<String?> read(String key) async => prefs.getString(key);
  @override Future<void> write(String key, String value) => prefs.setString(key, value);
  @override Future<void> remove(String key) => prefs.remove(key);
}
```

That alone reports the install (first start on this device) and every cold
start (`app_open`). Then, where it happens in your app:

```dart
vt.onboardingStarted();
vt.onboardingCompleted();
vt.paywallShown(surface: 'onboarding');
vt.checkoutStarted(productId: 'pro_yearly', plan: 'yearly');
vt.trialStarted(productId: 'pro_yearly');     // what the app saw
vt.purchase(productId: 'pro_yearly');         // the store's truth comes from RevenueCat
```

### Identity — the one rule

Viewthrough ties purchases to installs through the user id. After login, give
the **same id** to Viewthrough and RevenueCat:

```dart
// after login
vt.identify(user.id);
await Purchases.logIn(user.id);

// on logout
vt.reset();
```

No login in your app? Use the device id for both:

```dart
await Purchases.logIn(await vt.deviceId);
```

### Lifecycle

Flush when the app goes to the background so nothing waits for the next
start; report foreground opens if you want them beyond cold starts:

```dart
class _LifecycleFlush extends WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) vt.flush();
    if (state == AppLifecycleState.resumed) vt.appOpened(); // optional
  }
}
// in initState: WidgetsBinding.instance.addObserver(_LifecycleFlush());
```

### Where the install came from

```dart
// the "How did you hear about us?" answer
vt.setAttribution(acquisitionSource: 'tiktok');

// Android: Play Install Referrer / deep link of a Viewthrough tracking link
vt.setAttribution(installUtmCampaign: referrer.utmCampaign);
```

Both are stored on the device, not counted as events. `acquisition_source`
becomes the self-reported channel; `install_utm_campaign` ties the install to
a tracking link (`go.yourapp.com/<campaign>`).

### Privacy

- `vt.optOut()` stops collection and removes the device from every count;
  `vt.optIn()` resumes. `await vt.isOptedOut` tells you which.
- No IP is stored. The country is derived on the server from the request
  and the request is then forgotten.
- No IDFA, no ATT prompt, no fingerprinting. `device_id` is a random UUID.

### Events

Only the money events exist. Anything else is rejected by the server — on
purpose: Viewthrough is not a product-analytics tool, and a limit on
events is not something you want to hit.

| Method | Event | Meaning |
|---|---|---|
| automatic | `install` | first start on this device |
| automatic / `appOpened()` | `app_open` | cold start (and foreground, if you call it) |
| `onboardingStarted()` | `onboarding_started` | |
| `onboardingCompleted()` | `onboarding_completed` | |
| `paywallShown(surface:)` | `paywall_shown` | |
| `checkoutStarted(productId:, plan:)` | `checkout_started` | |
| `trialStarted(productId:)` | `trial_started` | what the app saw — the store's truth comes from RevenueCat |
| `purchase(productId:, plan:)` | `purchase` | same |

`vt.track(name, props)` takes the same names; anything else is ignored with
a warning. Props are flat: strings (cut to 256 characters), numbers,
booleans. Keys are letters, digits and `_` (max 64); any other key is
dropped with a warning, because the server would otherwise refuse the whole
batch.

### How sending works

- Events go to a queue on the device and are sent in batches: after 20
  events or every 30 seconds, whichever comes first; `await vt.flush()`
  sends now.
- Offline or server error: the queue stays, the SDK retries with backoff
  (1 s → 5 min). Nothing is dropped except when the queue exceeds 5,000
  events (then the oldest go) or when the server rejects a batch as
  malformed (HTTP 400).
- Every event has a UUID; a batch sent twice counts once.
- A wrong key (HTTP 401) stops sending until the next start; the queue is kept.
- A key that is not an SDK key disables the SDK with a warning instead of
  throwing — a typo must not crash the app.

Constructor options: `endpoint`, `flushAt`, `flushInterval`, `maxQueue`,
`trackAppOpen`, `debug`, `osVersion`, `locale` (defaults to the OS locale),
`send` (inject your own HTTP client, e.g. for tests), `now`.

## HTTP API (any platform)

The SDK is a thin client over one endpoint; see the
[JavaScript SDK README](https://www.npmjs.com/package/@viewthrough/sdk#http-api-any-platform)
for the request format.

## Develop

```sh
dart pub get && dart analyze && dart test
```
