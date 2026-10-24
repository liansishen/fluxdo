import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/category.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/providers/category_provider.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/message_bus/message_bus_service_provider.dart';
import 'package:fluxdo/providers/message_bus/pm_tracking_providers.dart';
import 'package:fluxdo/providers/message_bus/session_channel_providers.dart';
import 'package:fluxdo/providers/message_bus/topic_tracking_providers.dart';
import 'package:fluxdo/services/message_bus_service.dart';
import 'package:fluxdo/services/preloaded_data_service.dart';

class _CurrentUser extends CurrentUserNotifier {
  @override
  Future<User?> build() async => null;

  void login(int? id) {
    state = AsyncData(
      id == null ? null : User(id: id, username: 'user$id', trustLevel: 1),
    );
  }
}

class _NoMessageBusInit extends MessageBusInitNotifier {
  @override
  void build() {}
}

class _Bus extends Fake implements MessageBusService {
  final callbacks = <String, List<MessageBusCallback>>{};

  @override
  void subscribe(
    String channel,
    MessageBusCallback callback, {
    int lastMessageId = -1,
  }) {
    callbacks.putIfAbsent(channel, () => []).add(callback);
  }

  @override
  void unsubscribe(String channel, [MessageBusCallback? callback]) {
    callbacks[channel]?.remove(callback);
    if (callbacks[channel]?.isEmpty ?? false) callbacks.remove(channel);
  }

  void emit(String channel, dynamic data) {
    final message = MessageBusMessage(
      channel: channel,
      messageId: 1,
      data: data,
    );
    for (final callback in List<MessageBusCallback>.of(
      callbacks[channel] ?? [],
    )) {
      callback(message);
    }
  }

  @override
  void dispose() => callbacks.clear();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ProviderContainer container;
  late _Bus bus;
  var categoryLoads = 0;

  setUp(() async {
    categoryLoads = 0;
    bus = _Bus();
    PreloadedDataService().debugSeed(
      currentUser: {
        'groups': [
          {'id': 7, 'has_messages': true},
          {'id': 8, 'has_messages': false},
        ],
      },
    );
    container = ProviderContainer(
      overrides: [
        currentUserProvider.overrideWith(_CurrentUser.new),
        messageBusInitProvider.overrideWith(_NoMessageBusInit.new),
        messageBusServiceProvider.overrideWith((ref) => bus),
        categoriesProvider.overrideWith((ref) async {
          categoryLoads++;
          return <Category>[];
        }),
      ],
    );
    await container.read(currentUserProvider.future);
    container.listen(pmTrackingProvider, (_, _) {});
    container.listen(doNotDisturbProvider, (_, _) {});
    container.listen(categoryChangesProvider, (_, _) {});
  });

  tearDown(() {
    container.dispose();
    PreloadedDataService().debugSeed();
  });

  Future<void> login(int? id) async {
    (container.read(currentUserProvider.notifier) as _CurrentUser).login(id);
    await container.pump();
  }

  test('游客不订阅，登录只订有私信群组，退出清理所有新频道', () async {
    expect(bus.callbacks, isEmpty);
    await login(42);
    expect(
      bus.callbacks.keys,
      unorderedEquals([
        '/private-message-topic-tracking-state/user/42',
        '/private-message-topic-tracking-state/group/7',
        '/do-not-disturb/42',
        '/categories',
      ]),
    );
    await login(null);
    expect(bus.callbacks, isEmpty);
    expect(container.read(pmTrackingProvider).hasIncoming, isFalse);
    expect(container.read(doNotDisturbProvider), isNull);
  });

  test('换账号后旧回调不能写入新账号状态', () async {
    await login(42);
    final oldPm =
        bus.callbacks['/private-message-topic-tracking-state/user/42']!.single;
    final oldDnd = bus.callbacks['/do-not-disturb/42']!.single;
    bus.emit('/private-message-topic-tracking-state/user/42', {
      'message_type': 'unread',
      'topic_id': 1,
    });
    expect(container.read(pmTrackingProvider).incomingTopicIds, {1});
    await login(99);
    oldPm(
      MessageBusMessage(
        channel: '/private-message-topic-tracking-state/user/42',
        messageId: 2,
        data: {'message_type': 'unread', 'topic_id': 2},
      ),
    );
    oldDnd(
      MessageBusMessage(
        channel: '/do-not-disturb/42',
        messageId: 2,
        data: {'ends_at': 'Wed, 21 Oct 2099 07:28:00 GMT'},
      ),
    );
    expect(container.read(pmTrackingProvider).hasIncoming, isFalse);
    expect(container.read(doNotDisturbProvider), isNull);
    expect(
      bus.callbacks.containsKey(
        '/private-message-topic-tracking-state/user/42',
      ),
      isFalse,
    );
  });

  test('勿扰推送支持HTTP日期与退出勿扰', () async {
    await login(42);
    bus.emit('/do-not-disturb/42', {
      'ends_at': 'Wed, 21 Oct 2099 07:28:00 GMT',
    });
    expect(
      container.read(doNotDisturbProvider)!.toUtc(),
      DateTime.utc(2099, 10, 21, 7, 28),
    );
    expect(container.read(doNotDisturbProvider.notifier).isActive, isTrue);
    bus.emit('/do-not-disturb/42', {'ends_at': null});
    expect(container.read(doNotDisturbProvider.notifier).isActive, isFalse);
  });

  test('分类变更重拉，退出后的旧分类回调不再触发请求', () async {
    container.listen(categoriesProvider, (_, _) {});
    await container.read(categoriesProvider.future);
    await login(42);
    final oldCallback = bus.callbacks['/categories']!.single;
    bus.emit('/categories', {});
    await container.read(categoriesProvider.future);
    expect(categoryLoads, 2);
    await login(null);
    oldCallback(
      MessageBusMessage(channel: '/categories', messageId: 2, data: {}),
    );
    await container.pump();
    expect(categoryLoads, 2);
  });
}
