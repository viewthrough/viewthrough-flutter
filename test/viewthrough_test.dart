import 'dart:convert';

import 'package:test/test.dart';
import 'package:viewthrough/viewthrough.dart';

final String key = 'vts_${'a' * 43}';

class Sent {
  Sent(this.headers, this.body);
  final Map<String, String> headers;
  final Map<String, Object?> body;

  List<Map<String, Object?>> get events => (body['events'] as List).cast<Map<String, Object?>>();
  List<String> get names => events.map((e) => e['event'] as String).toList();
}

/// Records every request and answers with the given statuses (the last one repeats).
class FakeServer {
  FakeServer([List<int>? statuses]) : _statuses = [...(statuses ?? [202])];
  final List<int> _statuses;
  final List<Sent> calls = [];

  Future<int?> send(Uri url, Map<String, String> headers, String body) async {
    calls.add(Sent(headers, (jsonDecode(body) as Map).cast<String, Object?>()));
    return _statuses.length > 1 ? _statuses.removeAt(0) : _statuses.first;
  }

  List<String> get allNames => calls.expand((c) => c.names).toList();
}

/// Let `ready.then(...)` callbacks and storage writes run.
Future<void> pump([int turns = 4]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Viewthrough make(FakeServer server, {ViewthroughStorage? storage, bool trackAppOpen = false, int flushAt = 20, Duration? flushInterval}) =>
    Viewthrough(
      key: key,
      platform: 'ios',
      appVersion: '1.0.0',
      storage: storage ?? MemoryStorage(),
      send: server.send,
      trackAppOpen: trackAppOpen,
      flushAt: flushAt,
      flushInterval: flushInterval ?? const Duration(hours: 1),
    );

void main() {
  group('Viewthrough client', () {
    test('first start: makes a device id, queues install and app_open, sends with the key', () async {
      final server = FakeServer();
      final vt = make(server, trackAppOpen: true);
      await vt.ready;
      await vt.flush();
      expect(server.calls, hasLength(1));
      final sent = server.calls.single;
      expect(sent.headers['Authorization'], 'Bearer $key');
      expect(sent.headers['Content-Type'], 'application/json');
      expect(sent.body['platform'], 'ios');
      expect(sent.body['app_version'], '1.0.0');
      expect(sent.body['sdk'], {'name': sdkName, 'version': sdkVersion});
      expect(sent.body['sent_at'], isA<String>());
      expect(sent.names, ['install', 'app_open']);
      expect(sent.body['device_id'], matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
      expect(await vt.deviceId, sent.body['device_id']);
      for (final e in sent.events) {
        expect(e['event_id'], matches(RegExp(r'^[0-9a-f-]{36}$')));
        expect(DateTime.parse(e['ts'] as String).isUtc, isTrue);
      }
      vt.close();
    });

    test('second start on the same device: no install, same device id', () async {
      final storage = MemoryStorage();
      final a = make(FakeServer(), storage: storage, trackAppOpen: true);
      await a.ready;
      await a.flush();
      final id = await a.deviceId;
      a.close();

      final server = FakeServer();
      final b = make(server, storage: storage, trackAppOpen: true);
      await b.ready;
      await b.flush();
      expect(await b.deviceId, id);
      expect(server.calls.single.names, ['app_open']);
      b.close();
    });

    test('identify adds the user id to everything after it; same id twice sends nothing; reset forgets it', () async {
      final server = FakeServer();
      final vt = make(server);
      await vt.ready;
      vt.identify('user_42');
      await pump();
      vt.identify('user_42');
      await pump();
      vt.paywallShown(surface: 'onboarding');
      await pump();
      await vt.flush();
      // The install may have gone out on its own (timer after start); look
      // across all requests.
      final events = server.calls.expand((c) => c.events).toList();
      expect(events.map((e) => e['event']).toList(), ['install', 'identify', 'paywall_shown']);
      expect(events[1]['user_id'], 'user_42');
      expect(events[2]['user_id'], 'user_42');
      expect(events[2]['props'], {'surface': 'onboarding'});
      expect(server.calls.last.body['user_id'], 'user_42');

      final before = server.calls.length;
      vt.reset();
      await pump();
      vt.checkoutStarted(productId: 'pro_yearly', plan: 'yearly');
      await pump();
      await vt.flush();
      expect(server.calls, hasLength(before + 1));
      final later = server.calls.last;
      expect(later.names, ['checkout_started']);
      expect(later.events.single.containsKey('user_id'), isFalse);
      expect(later.body.containsKey('user_id'), isFalse);
      expect(later.events.single['props'], {'product_id': 'pro_yearly', 'plan': 'yearly'});
      vt.close();
    });

    test('identify rejects empty ids and ids with whitespace', () async {
      final server = FakeServer();
      final vt = make(server);
      await vt.ready;
      vt.identify('  ');
      vt.identify('user 42');
      await pump();
      await vt.flush();
      expect(server.calls.single.names, ['install']);
      vt.close();
    });

    test('keeps the queue on 5xx and retries after backoff', () async {
      final server = FakeServer([503, 202]);
      final vt = make(server);
      await vt.ready;
      await vt.flush();
      expect(server.calls, hasLength(1));
      // Backoff 1 s, then the timer resends the same events.
      await Future<void>.delayed(const Duration(milliseconds: 1300));
      expect(server.calls, hasLength(2));
      expect(server.calls[1].events, server.calls[0].events);
      vt.close();
    });

    test('drops the batch on 400 and does not retry', () async {
      final server = FakeServer([400]);
      final storage = MemoryStorage();
      final vt = make(server, storage: storage);
      await vt.ready;
      await vt.flush();
      await vt.flush();
      expect(server.calls, hasLength(1));
      expect(await storage.read('vt:aaaaaaaa:queue'), isNull);
      vt.close();
    });

    test('stops on 401 but keeps the events persisted', () async {
      final storage = MemoryStorage();
      final server = FakeServer([401]);
      final vt = make(server, storage: storage);
      await vt.ready;
      await vt.flush();
      await vt.flush();
      expect(server.calls, hasLength(1));
      final raw = await storage.read('vt:aaaaaaaa:queue');
      expect(jsonDecode(raw!), hasLength(1));
      vt.close();
    });

    test('sends when flushAt is reached without waiting for the timer', () async {
      final server = FakeServer();
      final vt = make(server, flushAt: 3);
      await vt.ready; // install queued (1)
      vt.onboardingStarted(); // 2
      vt.onboardingCompleted(); // 3 → flush
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(server.calls, hasLength(1));
      expect(server.calls.single.names, ['install', 'onboarding_started', 'onboarding_completed']);
      vt.close();
    });

    test('sends after flushInterval while something is queued', () async {
      final server = FakeServer();
      final vt = make(server, flushInterval: const Duration(milliseconds: 40));
      await vt.ready;
      await Future<void>.delayed(const Duration(milliseconds: 10)); // install goes out right after start
      expect(server.calls, hasLength(1));
      vt.paywallShown();
      await pump();
      expect(server.calls, hasLength(1)); // below flushAt: waits for the interval
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(server.calls, hasLength(2));
      expect(server.calls.last.names, ['paywall_shown']);
      vt.close();
    });

    test('opt-out: sends opt_out, then nothing; opt-in resumes', () async {
      final server = FakeServer();
      final vt = make(server);
      await vt.ready;
      vt.optOut();
      await pump(8);
      await vt.flush();
      vt.paywallShown();
      await pump();
      await vt.flush();
      expect(server.allNames, ['install', 'opt_out']);
      expect(await vt.isOptedOut, isTrue);
      vt.optIn();
      await pump();
      vt.paywallShown();
      await pump();
      await vt.flush();
      expect(server.calls.last.names, ['opt_in', 'paywall_shown']);
      expect(await vt.isOptedOut, isFalse);
      vt.close();
    });

    test('opt-out survives a restart: no app_open on the next start', () async {
      final storage = MemoryStorage();
      final a = make(FakeServer(), storage: storage);
      await a.ready;
      a.optOut();
      await pump(8);
      await a.flush();
      a.close();
      final server = FakeServer();
      final b = make(server, storage: storage, trackAppOpen: true);
      await b.ready;
      await b.flush();
      expect(server.calls, isEmpty);
      expect(await b.isOptedOut, isTrue);
      b.close();
    });

    test('setAttribution queues a control event with clean props', () async {
      final server = FakeServer();
      final vt = make(server);
      await vt.ready;
      vt.setAttribution(acquisitionSource: 'tiktok', installUtmCampaign: 'training', extra: {'empty': '', 'nothing': null});
      vt.setAttribution(extra: {'empty': ''});
      await pump();
      await vt.flush();
      final ev = server.calls.single.events.where((e) => e['event'] == 'set_attribution').toList();
      expect(ev, hasLength(1));
      expect(ev.single['props'], {'acquisition_source': 'tiktok', 'install_utm_campaign': 'training'});
      vt.close();
    });

    test('cleans props: cuts strings to 256, keeps numbers and booleans, drops the rest', () async {
      final server = FakeServer();
      final vt = make(server);
      await vt.ready;
      vt.track('purchase', {
        'long': 'x' * 300,
        'n': 3,
        'f': 1.5,
        'b': true,
        'nothing': null,
        'nested': {'a': 1},
        'inf': double.infinity,
      });
      await pump();
      await vt.flush();
      final props = server.calls.single.events[1]['props'] as Map;
      expect((props['long'] as String).length, 256);
      expect(props['n'], 3);
      expect(props['f'], 1.5);
      expect(props['b'], true);
      expect(props.containsKey('nothing'), isFalse);
      expect(props.containsKey('nested'), isFalse);
      expect(props.containsKey('inf'), isFalse);
      vt.close();
    });

    test('drops prop keys the server would refuse, keeps the rest', () async {
      final server = FakeServer();
      final vt = make(server);
      await vt.ready;
      vt.track('paywall_shown', {'ok_key': 'a', 'bad key': 'b', 'x' * 65: 'c'});
      vt.setAttribution(acquisitionSource: 'tiktok', extra: {'bad-key': 'd'});
      await pump();
      await vt.flush();
      final events = server.calls.expand((c) => c.events).toList();
      expect(events.map((e) => e['event']).toList(), ['install', 'paywall_shown', 'set_attribution']);
      expect(events[1]['props'], {'ok_key': 'a'});
      expect(events[2]['props'], {'acquisition_source': 'tiktok'});
      vt.close();
    });

    test('unknown events warn and are ignored', () async {
      final server = FakeServer();
      final vt = make(server);
      await vt.ready;
      vt.track('screen_view');
      vt.track('identify');
      await pump();
      await vt.flush();
      expect(server.calls.single.names, ['install']);
      vt.close();
    });

    test('the queue survives a restart and is sent then', () async {
      final storage = MemoryStorage();
      final a = make(FakeServer([503]), storage: storage);
      await a.ready;
      a.paywallShown();
      await pump();
      await a.flush();
      a.close();
      final server = FakeServer();
      final b = make(server, storage: storage);
      await b.ready;
      await b.flush();
      expect(server.calls.single.names, ['install', 'paywall_shown']);
      b.close();
    });

    test('drops the oldest beyond maxQueue', () async {
      final server = FakeServer([503]);
      final vt = Viewthrough(key: key, storage: MemoryStorage(), send: server.send, trackAppOpen: false, maxQueue: 3, flushAt: 100, flushInterval: const Duration(hours: 1));
      await vt.ready; // install
      vt.onboardingStarted();
      vt.onboardingCompleted();
      vt.paywallShown();
      await pump();
      await vt.flush();
      expect(server.calls.single.names, ['onboarding_started', 'onboarding_completed', 'paywall_shown']);
      vt.close();
    });

    test('a key that is not an SDK key disables the SDK without throwing', () async {
      final server = FakeServer();
      final vt = Viewthrough(key: 'vt_nope', storage: MemoryStorage(), send: server.send);
      await vt.ready;
      vt.paywallShown();
      vt.identify('user_1');
      await pump();
      await vt.flush();
      expect(server.calls, isEmpty);
      expect(await vt.deviceId, '');
      vt.close();
    });

    test('a storage that throws never breaks the app', () async {
      final server = FakeServer();
      final vt = Viewthrough(key: key, storage: _BrokenStorage(), send: server.send);
      await vt.ready;
      await vt.flush();
      expect(server.calls.single.names, ['install', 'app_open']);
      vt.close();
    });

    test('a send that throws counts as a network error and is retried', () async {
      var calls = 0;
      final vt = Viewthrough(
        key: key,
        storage: MemoryStorage(),
        trackAppOpen: false,
        flushInterval: const Duration(hours: 1),
        send: (url, headers, body) async {
          calls++;
          if (calls == 1) throw StateError('offline');
          return 202;
        },
      );
      await vt.ready;
      await vt.flush();
      expect(calls, 1);
      await Future<void>.delayed(const Duration(milliseconds: 1300));
      expect(calls, 2);
      vt.close();
    });
  });

  group('pure helpers', () {
    test('backoff grows exponentially, capped at five minutes', () {
      expect(backoffFor(1), const Duration(seconds: 1));
      expect(backoffFor(3), const Duration(seconds: 4));
      expect(backoffFor(20), const Duration(minutes: 5));
    });

    test('maps statuses to outcomes', () {
      expect(outcomeFor(202), SendOutcome.sent);
      expect(outcomeFor(200), SendOutcome.sent);
      expect(outcomeFor(400), SendOutcome.drop);
      expect(outcomeFor(413), SendOutcome.drop);
      expect(outcomeFor(401), SendOutcome.stop);
      expect(outcomeFor(403), SendOutcome.stop);
      expect(outcomeFor(429), SendOutcome.retry);
      expect(outcomeFor(503), SendOutcome.retry);
      expect(outcomeFor(null), SendOutcome.retry);
    });

    test('uuidV4 has the right shape and is unique', () {
      final ids = {for (var i = 0; i < 200; i++) uuidV4()};
      expect(ids, hasLength(200));
      for (final id in ids) {
        expect(id, matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
      }
    });

    test('persisted queue is parsed defensively', () {
      expect(QueuedEvent.fromJson({'broken': true}), isNull);
      final ok = QueuedEvent.fromJson({'event_id': 'x', 'event': 'app_open', 'ts': '2026-11-04T10:00:00.000Z'});
      expect(ok?.event, 'app_open');
    });
  });
}

class _BrokenStorage implements ViewthroughStorage {
  @override
  Future<String?> read(String key) => throw StateError('disk');
  @override
  Future<void> write(String key, String value) => throw StateError('disk');
  @override
  Future<void> remove(String key) => throw StateError('disk');
}
