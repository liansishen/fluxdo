import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/user_content_providers.dart';

class _CurrentUser extends CurrentUserNotifier {
  @override
  Future<User?> build() async => User(id: 42, username: 'me', trustLevel: 1);

  void logout() => state = const AsyncData(null);
}

class _Messages extends PrivateMessagesNotifier {
  final requests = <Completer<TopicListResponse>>[];

  @override
  Future<TopicListResponse> fetch(int page) {
    final request = Completer<TopicListResponse>();
    requests.add(request);
    return request.future;
  }
}

final _messagesProvider = AsyncNotifierProvider<_Messages, List<Topic>>(
  _Messages.new,
);

Topic _topic(int id) => Topic(
  id: id,
  title: '私信$id',
  slug: 'message-$id',
  postsCount: 1,
  replyCount: 0,
  views: 0,
  likeCount: 0,
  categoryId: '2',
);

void main() {
  late ProviderContainer container;
  late _Messages messages;

  setUp(() async {
    container = ProviderContainer(
      overrides: [currentUserProvider.overrideWith(_CurrentUser.new)],
    );
    await container.read(currentUserProvider.future);
    container.listen(_messagesProvider, (_, _) {});
    messages = container.read(_messagesProvider.notifier);
    messages.requests.single.complete(
      TopicListResponse(topics: [_topic(1)], moreTopicsUrl: '/next'),
    );
    await container.read(_messagesProvider.future);
  });

  tearDown(() => container.dispose());

  test('退出后迟到的自动刷新不能恢复前账号私信', () async {
    final refresh = messages.refresh();
    final pending = messages.requests.last;
    (container.read(currentUserProvider.notifier) as _CurrentUser).logout();
    await container.pump();
    expect(await container.read(_messagesProvider.future), isEmpty);
    pending.complete(TopicListResponse(topics: [_topic(2)]));
    await refresh;
    expect(container.read(_messagesProvider).requireValue, isEmpty);
    expect(messages.hasMore, isFalse);
  });

  test('刷新抢先完成后旧分页不能覆盖新窗口', () async {
    final loadMore = messages.loadMore();
    final oldPage = messages.requests.last;
    final refresh = messages.refresh();
    messages.requests.last.complete(TopicListResponse(topics: [_topic(3)]));
    await refresh;
    oldPage.complete(TopicListResponse(topics: [_topic(2)]));
    await loadMore;
    expect(
      container.read(_messagesProvider).requireValue.map((topic) => topic.id),
      [3],
    );
  });

  test('刷新完成后旧分页失败不回退列表或阻断后续分页', () async {
    final loadMore = messages.loadMore();
    final oldPage = messages.requests.last;
    final refresh = messages.refresh();
    messages.requests.last.complete(
      TopicListResponse(topics: [_topic(3)], moreTopicsUrl: '/next'),
    );
    await refresh;
    oldPage.completeError(StateError('旧分页失败'));
    await loadMore;
    expect(
      container.read(_messagesProvider).requireValue.map((topic) => topic.id),
      [3],
    );
    expect(messages.isLoadMoreFailed, isFalse);
  });

  test('分页失败保留列表并允许显式重试', () async {
    final loadMore = messages.loadMore();
    messages.requests.last.completeError(StateError('加载失败'));
    await loadMore;
    expect(messages.isLoadMoreFailed, isTrue);
    expect(container.read(_messagesProvider).requireValue.single.id, 1);
    final retry = messages.retryLoadMore();
    messages.requests.last.complete(TopicListResponse(topics: [_topic(2)]));
    await retry;
    expect(messages.isLoadMoreFailed, isFalse);
    expect(
      container.read(_messagesProvider).requireValue.map((topic) => topic.id),
      [1, 2],
    );
  });
}
