/// Viewthrough SDK for Flutter and Dart.
///
/// Identity is the heart of it, not the events: `device_id` is made on the
/// first start and kept on the device (survives logout, not reinstall) —
/// that is the install. After login, `identify(userId)` adds the user id to
/// everything from then on. Give RevenueCat the SAME id
/// (`Purchases.logIn(userId)`), or Viewthrough cannot tie purchases to
/// installs.
///
/// Only the money events exist (`countEvents`). Anything else is rejected by
/// the server on purpose: Viewthrough is not a product-analytics tool.
/// Trials, purchases, cancellations and refunds come from the store via the
/// RevenueCat webhook; `trial_started` and `purchase` here mean "what the
/// app reported".
///
/// Sending: events go to a queue on the device (persisted through
/// [ViewthroughStorage]) and are sent in batches — after [Viewthrough.flushAt]
/// events or every [Viewthrough.flushInterval], whichever comes first. Offline
/// or server error: the queue stays, the SDK retries with backoff (1 s →
/// 5 min). A wrong key (HTTP 401) stops sending until the next start.
///
/// Pure Dart: `dart:io` for the network, no packages. Flutter apps pass a
/// [ViewthroughStorage] backed by shared_preferences (see README).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Reported to the server with every batch.
const String sdkName = 'viewthrough-flutter';
const String sdkVersion = '0.1.0';
const String defaultEndpoint = 'https://viewthrough.app/api/v1/events';

/// The events that count. Everything else is refused by `track`.
const List<String> countEvents = [
  'install',
  'app_open',
  'onboarding_started',
  'onboarding_completed',
  'paywall_shown',
  'checkout_started',
  'trial_started',
  'purchase',
];

/// Events that change the device instead of counting.
const List<String> controlEvents = ['identify', 'set_attribution', 'opt_out', 'opt_in'];

/// What `platform` may be.
const List<String> platforms = ['ios', 'android', 'web', 'unknown'];

/// The server takes at most this many events per request.
const int serverMaxBatch = 100;

/// Sends one batch; returns the HTTP status, or `null` on a network error.
typedef SendFn = Future<int?> Function(Uri url, Map<String, String> headers, String body);

/// Where the SDK keeps the device id and the offline queue.
///
/// Flutter: wrap shared_preferences (adapter in the README). Without a
/// storage the SDK still works, but a cold start forgets the device id —
/// every start would count as an install.
abstract class ViewthroughStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> remove(String key);
}

/// In-memory storage: survives nothing, but never throws. For tests and
/// for apps that have not wired a real storage yet.
class MemoryStorage implements ViewthroughStorage {
  final Map<String, String> _m = {};

  @override
  Future<String?> read(String key) async => _m[key];

  @override
  Future<void> write(String key, String value) async {
    _m[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    _m.remove(key);
  }
}

/// Backoff after a failed send: 1 s, 2 s, 4 s … capped at 5 min.
Duration backoffFor(int attempt) {
  final ms = min(300000, 1000 * pow(2, max(0, attempt - 1)).toInt());
  return Duration(milliseconds: ms);
}

/// What to do with an HTTP status.
enum SendOutcome { sent, drop, stop, retry }

/// 2xx sent · 400/413 (and other 4xx a retry won't fix) drop · 401/403 stop
/// until the next start · 429, 5xx, network retry with backoff.
SendOutcome outcomeFor(int? status) {
  if (status == null) return SendOutcome.retry;
  if (status == 202 || status == 200) return SendOutcome.sent;
  if (status == 401 || status == 403) return SendOutcome.stop;
  if (status == 429 || status >= 500) return SendOutcome.retry;
  if (status >= 400) return SendOutcome.drop;
  return SendOutcome.retry;
}

/// UUID v4 for device and event ids. They only have to be unique.
String uuidV4([Random? random]) {
  final r = random ?? _random;
  final bytes = List<int>.generate(16, (_) => r.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-${hex.substring(20)}';
}

final Random _random = _secureRandom();

Random _secureRandom() {
  try {
    return Random.secure();
  } catch (_) {
    return Random();
  }
}

final RegExp _keyRe = RegExp(r'^vts_[A-Za-z0-9_-]{43}$');
final RegExp _whitespace = RegExp(r'\s');

/// One event as it goes over the wire.
class QueuedEvent {
  QueuedEvent({required this.eventId, required this.event, required this.ts, this.userId, this.props});

  final String eventId;
  final String event;
  final String ts;
  final String? userId;
  final Map<String, Object>? props;

  Map<String, Object> toJson() => {
        'event_id': eventId,
        'event': event,
        'ts': ts,
        if (userId != null) 'user_id': userId!,
        if (props != null) 'props': props!,
      };

  static QueuedEvent? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['event_id'];
    final event = raw['event'];
    final ts = raw['ts'];
    if (id is! String || event is! String || ts is! String) return null;
    final userId = raw['user_id'];
    final props = raw['props'];
    return QueuedEvent(
      eventId: id,
      event: event,
      ts: ts,
      userId: userId is String ? userId : null,
      props: props is Map ? _cleanProps(props.cast<String, Object?>()) : null,
    );
  }
}

/// The client. One instance per app; create it once at startup.
class Viewthrough {
  /// [key] is the app's write key from Sources → SDK in Viewthrough
  /// (`vts_…`). A key that is not an SDK key disables the SDK with a
  /// warning — it never throws in production.
  ///
  /// [platform] is `ios`, `android`, `web` or `unknown`; detected from the
  /// OS when omitted. [storage] should be backed by
  /// shared_preferences in a Flutter app; the default [MemoryStorage]
  /// forgets the device id on every cold start.
  Viewthrough({
    required String key,
    String? platform,
    this.appVersion,
    this.osVersion,
    String? locale,
    ViewthroughStorage? storage,
    String endpoint = defaultEndpoint,
    int flushAt = 20,
    this.flushInterval = const Duration(seconds: 30),
    int maxQueue = 5000,
    this.trackAppOpen = true,
    this.debug = false,
    SendFn? send,
    DateTime Function()? now,
  })  : _key = key,
        platform = platform != null && platforms.contains(platform) ? platform : _detectPlatform(),
        locale = locale ?? _detectLocale(),
        endpoint = Uri.parse(endpoint),
        flushAt = max(1, flushAt),
        maxQueue = max(1, maxQueue),
        _send = send ?? _defaultSend,
        _now = now ?? DateTime.now,
        _storage = storage ?? MemoryStorage(),
        _keyNs = key.length >= 12 ? 'vt:${key.substring(4, 12)}' : 'vt:invalid' {
    if (!_keyRe.hasMatch(key)) {
      _disabled = true;
      _warn('`key` must be the app\'s SDK key (vts_…) from Sources → SDK; the SDK is disabled');
      _ready = Future<void>.value();
      return;
    }
    if (storage == null) {
      _warn('no storage given — every cold start will count as an install; pass a ViewthroughStorage');
    }
    _ready = _load();
  }

  final String _key;
  final String platform;
  final String? appVersion;
  final String? osVersion;
  final String? locale;
  final Uri endpoint;
  final int flushAt;
  final Duration flushInterval;
  final int maxQueue;
  final bool trackAppOpen;
  final bool debug;
  final SendFn _send;
  final DateTime Function() _now;
  final ViewthroughStorage _storage;
  final String _keyNs;

  late final Future<void> _ready;
  bool _disabled = false;
  _Persisted? _state;
  List<QueuedEvent> _queue = [];
  int _attempt = 0;
  bool _stopped = false;
  Future<void>? _flushing;
  Timer? _timer;
  DateTime? _timerDueAt;
  DateTime? _nextAllowedAt;

  /// Completes once device id and queue are loaded. Awaiting it is optional.
  Future<void> get ready => _ready;

  /// The install's id — random, made on the first start, kept on the device.
  Future<String> get deviceId async {
    await _ready;
    return _state?.deviceId ?? '';
  }

  Future<bool> get isOptedOut async {
    await _ready;
    return _state?.optedOut ?? false;
  }

  // ---------------------------------------------------------------- events

  /// Record one of the money events ([countEvents]). Unknown names warn and are ignored.
  void track(String event, [Map<String, Object?>? props]) {
    if (!countEvents.contains(event)) {
      _warn('track: "$event" is not a Viewthrough event; use one of ${countEvents.join(', ')}');
      return;
    }
    _enqueue(event, props);
  }

  void onboardingStarted([Map<String, Object?>? props]) => track('onboarding_started', props);

  void onboardingCompleted([Map<String, Object?>? props]) => track('onboarding_completed', props);

  /// e.g. `surface: 'onboarding' | 'settings' | 'feature_gate'`.
  void paywallShown({String? surface, Map<String, Object?>? props}) =>
      track('paywall_shown', {...?props, if (surface != null) 'surface': surface});

  void checkoutStarted({String? productId, String? plan, Map<String, Object?>? props}) => track(
      'checkout_started', {...?props, if (productId != null) 'product_id': productId, if (plan != null) 'plan': plan});

  /// What the app saw. The store's view comes from RevenueCat.
  void trialStarted({String? productId, Map<String, Object?>? props}) =>
      track('trial_started', {...?props, if (productId != null) 'product_id': productId});

  void purchase({String? productId, String? plan, Map<String, Object?>? props}) =>
      track('purchase', {...?props, if (productId != null) 'product_id': productId, if (plan != null) 'plan': plan});

  /// Call on foreground if you want app opens beyond cold starts.
  void appOpened() => track('app_open');

  // -------------------------------------------------------------- identity

  /// After login. Use the same id for RevenueCat (`Purchases.logIn`).
  void identify(String userId) {
    final id = userId.trim();
    if (id.isEmpty || _whitespace.hasMatch(id) || id.length > 128) {
      _warn('identify: user id must be a non-empty string without whitespace (max 128)');
      return;
    }
    _after(() {
      final s = _state;
      if (s == null || s.userId == id) return;
      s.userId = id;
      unawaited(_persistState());
      _enqueueNow('identify', null, id, _now());
    });
  }

  /// Where this install came from: the onboarding question
  /// ([acquisitionSource]) and/or the tracking-link campaign
  /// ([installUtmCampaign] from the Play Install Referrer or a deep link).
  /// Stored on the device, not counted as an event.
  void setAttribution({String? acquisitionSource, String? installUtmCampaign, Map<String, Object?> extra = const {}}) {
    final clean = _cleanProps({
      ...extra,
      if (acquisitionSource != null) 'acquisition_source': acquisitionSource,
      if (installUtmCampaign != null) 'install_utm_campaign': installUtmCampaign,
    }, dropEmptyStrings: true, warn: _warn);
    if (clean == null) return;
    _enqueue('set_attribution', clean);
  }

  /// On logout: forget the user id. The device id stays — it is still the same install.
  void reset() {
    _after(() {
      final s = _state;
      if (s == null) return;
      s.userId = null;
      unawaited(_persistState());
    });
  }

  /// Stop collecting and tell the server to drop this device from every count.
  void optOut() {
    _after(() async {
      final s = _state;
      if (s == null || s.optedOut) return;
      _enqueueNow('opt_out', null, null, _now());
      s.optedOut = true;
      await _persistState();
      await flush();
    });
  }

  void optIn() {
    _after(() {
      final s = _state;
      if (s == null || !s.optedOut) return;
      s.optedOut = false;
      unawaited(_persistState());
      _enqueueNow('opt_in', null, null, _now());
    });
  }

  // --------------------------------------------------------------- sending

  /// Send everything queued now. Safe to call often; concurrent calls share one send.
  Future<void> flush() async {
    await _ready;
    if (_disabled) return;
    final running = _flushing;
    if (running != null) return running;
    final f = _drain().whenComplete(() => _flushing = null);
    _flushing = f;
    return f;
  }

  /// Stop timers (tests, hot reload). Queued events stay on disk.
  void close() {
    _timer?.cancel();
    _timer = null;
    _timerDueAt = null;
  }

  // -------------------------------------------------------------- internal

  void _after(FutureOr<void> Function() fn) {
    if (_disabled) return;
    unawaited(_ready.then((_) => fn()));
  }

  Future<void> _load() async {
    final rawState = await _read('$_keyNs:state');
    final rawQueue = await _read('$_keyNs:queue');
    _Persisted? state;
    if (rawState != null) {
      try {
        final v = jsonDecode(rawState);
        if (v is Map && v['device_id'] is String && (v['device_id'] as String).length >= 8) {
          state = _Persisted(
            deviceId: v['device_id'] as String,
            userId: v['user_id'] is String ? v['user_id'] as String : null,
            optedOut: v['opted_out'] == true,
            installedAt: v['installed_at'] is String ? v['installed_at'] as String : null,
          );
        }
      } catch (_) {
        state = null;
      }
    }
    _queue = _parseQueue(rawQueue);
    final now = _now();
    if (state == null) {
      // First start on this device: that is the install.
      state = _Persisted(deviceId: uuidV4(), installedAt: _iso(now));
      _state = state;
      await _persistState();
      _enqueueNow('install', null, null, now);
    } else {
      _state = state;
    }
    if (trackAppOpen && !state.optedOut) _enqueueNow('app_open', null, null, now);
    _schedule(Duration.zero);
  }

  void _enqueue(String event, Map<String, Object?>? props) {
    _after(() {
      final s = _state;
      if (s != null && s.optedOut && event != 'opt_in' && event != 'opt_out') return;
      _enqueueNow(event, props, null, _now());
    });
  }

  void _enqueueNow(String event, Map<String, Object?>? props, String? userId, DateTime at) {
    final q = QueuedEvent(
      eventId: uuidV4(),
      event: event,
      ts: _iso(at),
      userId: userId ?? _state?.userId,
      props: _cleanProps(props, warn: _warn),
    );
    _queue.add(q);
    final dropped = _queue.length - maxQueue;
    if (dropped > 0) {
      _queue = _queue.sublist(dropped);
      _warn('queue full ($maxQueue), dropped $dropped oldest event(s)');
    }
    unawaited(_persistQueue());
    _debug('queued $event (${_queue.length} waiting)');
    if (_queue.length >= flushAt) {
      _schedule(Duration.zero);
    } else {
      _schedule(flushInterval);
    }
  }

  void _schedule(Duration inDelay) {
    if (_stopped || _queue.isEmpty) return;
    final now = _now();
    var delay = inDelay;
    final allowed = _nextAllowedAt;
    if (allowed != null && allowed.difference(now) > delay) delay = allowed.difference(now);
    if (delay.isNegative) delay = Duration.zero;
    final due = _timerDueAt;
    if (_timer != null && due != null) {
      // An earlier timer wins; a shorter one replaces it.
      if (delay >= due.difference(now)) return;
      _timer!.cancel();
    }
    _timerDueAt = now.add(delay);
    _timer = Timer(delay, () {
      _timer = null;
      _timerDueAt = null;
      unawaited(flush());
    });
  }

  Future<void> _drain() async {
    while (_queue.isNotEmpty && !_stopped) {
      final allowed = _nextAllowedAt;
      final now = _now();
      if (allowed != null && now.isBefore(allowed)) {
        _schedule(allowed.difference(now));
        return;
      }
      final batch = _queue.take(min(serverMaxBatch, max(flushAt, serverMaxBatch))).toList();
      final status = await _sendBatch(batch);
      switch (outcomeFor(status)) {
        case SendOutcome.sent:
          _removeSent(batch);
          _attempt = 0;
          await _persistQueue();
          _debug('sent ${batch.length} event(s)');
          continue;
        case SendOutcome.drop:
          _removeSent(batch);
          await _persistQueue();
          _warn('server rejected ${batch.length} event(s) with HTTP $status; dropped');
          continue;
        case SendOutcome.stop:
          _stopped = true;
          _warn('HTTP $status: the SDK key is unknown or revoked — events stay queued until the next start');
          return;
        case SendOutcome.retry:
          _attempt += 1;
          final wait = backoffFor(_attempt);
          _nextAllowedAt = _now().add(wait);
          _debug('send failed (${status ?? 'network'}), retry in ${wait.inSeconds} s');
          _schedule(wait);
          return;
      }
    }
  }

  void _removeSent(List<QueuedEvent> sent) {
    final ids = sent.map((e) => e.eventId).toSet();
    _queue = _queue.where((e) => !ids.contains(e.eventId)).toList();
  }

  Future<int?> _sendBatch(List<QueuedEvent> batch) async {
    final s = _state!;
    final body = jsonEncode({
      'device_id': s.deviceId,
      if (s.userId != null) 'user_id': s.userId,
      'platform': platform,
      if (appVersion != null) 'app_version': appVersion,
      if (osVersion != null) 'os_version': osVersion,
      if (locale != null) 'locale': locale,
      'sdk': {'name': sdkName, 'version': sdkVersion},
      'sent_at': _iso(_now()),
      'events': batch.map((e) => e.toJson()).toList(),
    });
    try {
      return await _send(endpoint, {'Content-Type': 'application/json', 'Authorization': 'Bearer $_key'}, body);
    } catch (_) {
      return null;
    }
  }

  Future<String?> _read(String key) async {
    try {
      return await _storage.read(key);
    } catch (e) {
      _warn('storage.read failed: $e');
      return null;
    }
  }

  Future<void> _persistState() async {
    final s = _state;
    if (s == null) return;
    try {
      await _storage.write('$_keyNs:state', jsonEncode(s.toJson()));
    } catch (e) {
      _warn('storage.write failed: $e');
    }
  }

  Future<void> _persistQueue() async {
    try {
      if (_queue.isEmpty) {
        await _storage.remove('$_keyNs:queue');
      } else {
        await _storage.write('$_keyNs:queue', jsonEncode(_queue.map((e) => e.toJson()).toList()));
      }
    } catch (e) {
      _warn('storage.write failed: $e');
    }
  }

  void _warn(String msg) => print('[viewthrough] $msg');

  void _debug(String msg) {
    if (debug) print('[viewthrough] $msg');
  }
}

class _Persisted {
  _Persisted({required this.deviceId, this.userId, this.optedOut = false, this.installedAt});

  final String deviceId;
  String? userId;
  bool optedOut;
  final String? installedAt;

  Map<String, Object> toJson() => {
        'device_id': deviceId,
        if (userId != null) 'user_id': userId!,
        if (optedOut) 'opted_out': true,
        if (installedAt != null) 'installed_at': installedAt!,
      };
}

List<QueuedEvent> _parseQueue(String? raw) {
  if (raw == null || raw.isEmpty) return [];
  try {
    final v = jsonDecode(raw);
    if (v is! List) return [];
    return v.map(QueuedEvent.fromJson).whereType<QueuedEvent>().toList();
  } catch (_) {
    return [];
  }
}

/// What the server accepts as a prop key. A bad key would make it reject
/// the WHOLE batch (HTTP 400) — install included — so the key is dropped
/// here instead.
final RegExp _propKeyRe = RegExp(r'^[A-Za-z0-9_]{1,64}$');

/// Props are flat: strings (cut to 256), finite numbers and booleans. Null
/// and anything else is dropped, as is a key the server would refuse (with
/// a warning); an empty result is `null`.
Map<String, Object>? _cleanProps(Map<String, Object?>? props,
    {bool dropEmptyStrings = false, void Function(String msg)? warn}) {
  if (props == null) return null;
  final out = <String, Object>{};
  props.forEach((k, v) {
    if (!_propKeyRe.hasMatch(k)) {
      final shown = k.length > 40 ? '${k.substring(0, 40)}…' : k;
      warn?.call('prop key "$shown" ignored: letters, digits, _ only (max 64)');
      return;
    }
    if (v == null) return;
    if (v is String) {
      if (dropEmptyStrings && v.isEmpty) return;
      out[k] = v.length > 256 ? v.substring(0, 256) : v;
    } else if (v is num) {
      if (v.isFinite) out[k] = v;
    } else if (v is bool) {
      out[k] = v;
    }
  });
  return out.isEmpty ? null : out;
}

String _iso(DateTime at) => at.toUtc().toIso8601String();

/// ios | android from the OS; anything else (desktop, tests) is `unknown`.
String _detectPlatform() {
  try {
    if (Platform.isIOS) return 'ios';
    if (Platform.isAndroid) return 'android';
  } catch (_) {
    // not available on this runtime
  }
  return 'unknown';
}

/// `de_DE` from the OS becomes `de-DE`, as the server expects.
String? _detectLocale() {
  try {
    final name = Platform.localeName;
    final cleaned = name.split('.').first.replaceAll('_', '-');
    return cleaned.isEmpty ? null : cleaned;
  } catch (_) {
    return null;
  }
}

/// Default network: one request per batch, 15 s timeout, `null` on any error.
Future<int?> _defaultSend(Uri url, Map<String, String> headers, String body) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final req = await client.postUrl(url).timeout(const Duration(seconds: 15));
    headers.forEach((k, v) => req.headers.set(k, v));
    req.write(body);
    final res = await req.close().timeout(const Duration(seconds: 15));
    await res.drain<void>();
    return res.statusCode;
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}
