import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/notification.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/recent_notifications_provider.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/services/auth_session.dart';

DiscourseNotification _notification(int id) => DiscourseNotification(
  id: id,
  userId: 1,
  notificationType: NotificationType.fromId(1),
  read: false,
  highPriority: false,
  createdAt: DateTime(2026, 10, 27),
  data: NotificationData.fromJson(const {}),
);

NotificationListResponse _response(int id) => NotificationListResponse(
  notifications: [_notification(id)],
  totalRowsNotifications: 1,
  seenNotificationId: 0,
);

class _Service implements DiscourseService {
  final calls = <bool>[];
  List<int> ids = [1];
  Future<NotificationListResponse> Function()? load;

  @override
  final currentUserNotifier = ValueNotifier<User?>(
    User(id: 1, username: 'alice', trustLevel: 2),
  );

  @override
  Future<NotificationListResponse> getRecentNotifications({
    bool silent = false,
  }) async {
    calls.add(silent);
    if (load != null) return load!();
    return NotificationListResponse(
      notifications: [for (final id in ids) _notification(id)],
      totalRowsNotifications: ids.length,
      seenNotificationId: 0,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _Service service;
  late ProviderContainer container;

  setUp(() {
    RecentNotificationsNotifier.clearPrefetched();
    service = _Service();
    addTearDown(service.currentUserNotifier.dispose);
    container = ProviderContainer(
      overrides: [discourseServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);
    addTearDown(RecentNotificationsNotifier.clearPrefetched);
  });

  test('预取用 silent；面板打开时先显示预取的，再正常拉一次', () async {
    await RecentNotificationsNotifier.prefetch(service);
    expect(service.calls, [true]);

    service.ids = [2, 1];
    final first = await container.read(recentNotificationsProvider.future);
    expect(first.map((n) => n.id), [1], reason: '先显示预取的那份');
    expect(service.calls, [true], reason: '建 provider 时不再请求');

    await container.read(recentNotificationsProvider.notifier).refreshOnOpen();
    expect(service.calls, [true, false], reason: '再正常拉一次，更新已看到位置');
    expect(
      container.read(recentNotificationsProvider).value!.map((n) => n.id),
      [2, 1],
    );
  });

  test('没有预取：建 provider 时正常拉，面板打开不重复拉', () async {
    await container.read(recentNotificationsProvider.future);
    await container.read(recentNotificationsProvider.notifier).refreshOnOpen();
    expect(service.calls, [false]);
  });

  test('30 秒内不重复预取；退出登录清掉预取', () async {
    await RecentNotificationsNotifier.prefetch(service);
    await RecentNotificationsNotifier.prefetch(service);
    expect(service.calls, [true]);
    RecentNotificationsNotifier.clearPrefetched();
    await container.read(recentNotificationsProvider.future);
    expect(service.calls, [true, false], reason: '清掉后不用旧账号那份');
  });

  for (final oldFinishesFirst in [true, false]) {
    test('换号后旧预取${oldFinishesFirst ? '先' : '后'}返回不回写或干扰新预取', () async {
      final oldResponse = Completer<NotificationListResponse>();
      final newResponse = Completer<NotificationListResponse>();
      service.load = () => oldResponse.future;
      final oldPrefetch = RecentNotificationsNotifier.prefetch(service);

      RecentNotificationsNotifier.clearPrefetched();
      service.currentUserNotifier.value = User(
        id: 2,
        username: 'bob',
        trustLevel: 2,
      );
      service.load = () => newResponse.future;
      final newPrefetch = RecentNotificationsNotifier.prefetch(service);
      expect(service.calls, [true, true], reason: '新账号立即发起预取');
      expect(identical(oldPrefetch, newPrefetch), isFalse);

      if (oldFinishesFirst) {
        oldResponse.complete(_response(1));
        await oldPrefetch;
        expect(
          identical(RecentNotificationsNotifier.prefetch(service), newPrefetch),
          isTrue,
          reason: '旧请求结束不能清掉新请求的在途引用',
        );
      }
      newResponse.complete(_response(2));
      await newPrefetch;
      if (!oldFinishesFirst) {
        oldResponse.complete(_response(1));
        await oldPrefetch;
      }

      final first = await container.read(recentNotificationsProvider.future);
      expect(first.map((n) => n.id), [2]);
      expect(service.calls, [true, true], reason: '消费新账号预取，不补发请求');
    });
  }

  test('清理后即使身份相同，旧在途响应也不能覆盖新的预取', () async {
    final oldResponse = Completer<NotificationListResponse>();
    service.load = () => oldResponse.future;
    final oldPrefetch = RecentNotificationsNotifier.prefetch(service);
    RecentNotificationsNotifier.clearPrefetched();
    service.load = () async => _response(2);
    await RecentNotificationsNotifier.prefetch(service);
    oldResponse.complete(_response(1));
    await oldPrefetch;

    final first = await container.read(recentNotificationsProvider.future);
    expect(first.map((n) => n.id), [2]);
    expect(service.calls, [true, true]);
  });

  test('身份变化即使未显式清理，也不复用旧账号在途请求和节流窗口', () async {
    final oldResponse = Completer<NotificationListResponse>();
    service.load = () => oldResponse.future;
    final oldPrefetch = RecentNotificationsNotifier.prefetch(service);
    service.currentUserNotifier.value = User(
      id: 2,
      username: 'bob',
      trustLevel: 2,
    );
    service.load = () async => _response(2);
    await RecentNotificationsNotifier.prefetch(service);
    oldResponse.complete(_response(1));
    await oldPrefetch;

    final first = await container.read(recentNotificationsProvider.future);
    expect(first.map((n) => n.id), [2]);
    expect(service.calls, [true, true]);
  });

  for (final changeSession in [false, true]) {
    test('消费预取时拒绝${changeSession ? '旧会话' : '其他账号'}的缓存', () async {
      await RecentNotificationsNotifier.prefetch(service);
      if (changeSession) {
        AuthSession().advance();
      } else {
        service.currentUserNotifier.value = User(
          id: 2,
          username: 'bob',
          trustLevel: 2,
        );
      }
      service.ids = [2];
      final first = await container.read(recentNotificationsProvider.future);
      expect(first.map((n) => n.id), [2]);
      expect(service.calls, [true, false], reason: '身份不匹配时正常拉取');
    });
  }

  test('未登录时不预取通知', () async {
    service.currentUserNotifier.value = null;
    await RecentNotificationsNotifier.prefetch(service);
    expect(service.calls, isEmpty);
  });
}
