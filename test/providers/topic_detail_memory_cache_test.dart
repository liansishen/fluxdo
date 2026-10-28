import 'dart:async';

import 'package:fluxdo/services/auth_session.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/topic_detail_provider.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';

/// 测试约定:帖子 id == 楼层号
Post _post(int id) => Post(
  id: id,
  username: 'user$id',
  avatarTemplate: '',
  cooked: '<p>$id</p>',
  postNumber: id,
  postType: 1,
  updatedAt: DateTime(2026),
  createdAt: DateTime(2026),
  likeCount: 0,
  replyCount: 0,
);

TopicDetail _detail({
  int id = 7,
  List<int> loaded = const [1, 2, 3],
  int highest = 3,
}) => TopicDetail(
  id: id,
  title: 'Topic',
  slug: 'topic',
  postsCount: highest,
  highestPostNumber: highest,
  postStream: PostStream(
    posts: [for (final n in loaded) _post(n)],
    stream: [for (var n = 1; n <= highest; n++) n],
  ),
  categoryId: 1,
  closed: false,
  archived: false,
);

class _FakeDiscourseService implements DiscourseService {
  int detailRequests = 0;
  TopicDetail Function() next = _detail;
  Completer<TopicDetail>? pending;

  @override
  Future<TopicDetail> getTopicDetail(
    int id, {
    int? postNumber,
    bool trackVisit = false,
    String? filter,
    String? usernameFilters,
    bool filterTopLevelReplies = false,
  }) async {
    detailRequests++;
    final pending = this.pending;
    if (pending != null) return pending.future;
    return next();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  var clock = DateTime(2026, 10, 27, 12);
  setUp(() {
    TopicDetailMemoryCache.clear();
    clock = DateTime(2026, 10, 27, 12);
    TopicDetailMemoryCache.now = () => clock;
  });
  tearDown(() {
    TopicDetailMemoryCache.clear();
    TopicDetailMemoryCache.now = DateTime.now;
  });

  group('TopicDetailMemoryCache.take', () {
    test('列表最高楼层没超过缓存：复用', () {
      TopicDetailMemoryCache.put(_detail());
      expect(
        TopicDetailMemoryCache.take(
          7,
          expectedHighestPostNumber: 3,
          targetPostNumber: null,
        ),
        isNotNull,
      );
    });

    test('有新回复 / 没给列表楼层 / 过期 / 目标楼层不在窗口：不复用', () {
      TopicDetailMemoryCache.put(_detail());
      expect(
        TopicDetailMemoryCache.take(
          7,
          expectedHighestPostNumber: 4,
          targetPostNumber: null,
        ),
        isNull,
      );
      TopicDetailMemoryCache.put(_detail());
      expect(
        TopicDetailMemoryCache.take(
          7,
          expectedHighestPostNumber: null,
          targetPostNumber: null,
        ),
        isNull,
      );
      TopicDetailMemoryCache.put(_detail());
      clock = clock.add(const Duration(minutes: 4));
      expect(
        TopicDetailMemoryCache.take(
          7,
          expectedHighestPostNumber: 3,
          targetPostNumber: null,
        ),
        isNull,
      );
      TopicDetailMemoryCache.put(_detail(loaded: [2, 3], highest: 3));
      expect(
        TopicDetailMemoryCache.take(
          7,
          expectedHighestPostNumber: 3,
          targetPostNumber: null,
        ),
        isNull,
        reason: '从头看但缓存里没有 1 楼',
      );
    });

    test('取一次就作废', () {
      TopicDetailMemoryCache.put(_detail());
      TopicDetailMemoryCache.take(
        7,
        expectedHighestPostNumber: 3,
        targetPostNumber: 2,
      );
      expect(
        TopicDetailMemoryCache.take(
          7,
          expectedHighestPostNumber: 3,
          targetPostNumber: 2,
        ),
        isNull,
      );
    });

    test('超过上限时丢最旧的', () {
      for (var id = 1; id <= TopicDetailMemoryCache.maxEntries + 1; id++) {
        TopicDetailMemoryCache.put(_detail(id: id));
      }
      expect(
        TopicDetailMemoryCache.take(
          1,
          expectedHighestPostNumber: 3,
          targetPostNumber: null,
        ),
        isNull,
      );
      expect(
        TopicDetailMemoryCache.take(
          2,
          expectedHighestPostNumber: 3,
          targetPostNumber: null,
        ),
        isNotNull,
      );
    });
  });

  group('详情 provider', () {
    late _FakeDiscourseService service;
    late ProviderContainer container;

    setUp(() {
      service = _FakeDiscourseService();
      container = ProviderContainer(
        overrides: [discourseServiceProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);
    });

    Future<TopicDetail> open(TopicDetailParams params) async {
      final sub = container.listen(topicDetailProvider(params), (_, _) {});
      final detail = await container.read(topicDetailProvider(params).future);
      // 离开页面
      sub.close();
      await Future<void>.delayed(Duration.zero);
      return detail;
    }

    for (final flushCancellation in [false, true]) {
      test('换号失效后同一 keepAlive 详情不能复用旧状态：取消微任务已执行=$flushCancellation', () async {
        const params = TopicDetailParams(
          7,
          instanceId: 'same-instance',
          expectedHighestPostNumber: 3,
        );
        final provider = topicDetailProvider(params);
        final oldSub = container.listen(provider, (_, _) {});
        final oldDetail = await container.read(provider.future);
        final oldNotifier = container.read(provider.notifier);
        oldSub.close();
        if (flushCancellation) await Future<void>.delayed(Duration.zero);
        expect(container.read(provider).value, same(oldDetail));
        expect(container.read(provider.notifier), same(oldNotifier));
        expect(service.detailRequests, 1);

        // 等价于 logout → _resetAccountState → _attach 的会话与详情清理顺序。
        final pending = service.pending = Completer<TopicDetail>();
        AuthSession().advance();
        TopicDetailMemoryCache.clear();
        container.invalidate(topicDetailProvider);
        AuthSession().advance();
        await Future<void>.delayed(Duration.zero);
        expect(
          TopicDetailMemoryCache.take(
            7,
            expectedHighestPostNumber: 3,
            targetPostNumber: null,
          ),
          isNull,
        );

        final seen = <AsyncValue<TopicDetail>>[];
        final newSub = container.listen(
          provider,
          (_, next) => seen.add(next),
          fireImmediately: true,
        );
        addTearDown(newSub.close);
        final fresh = container.read(provider.future);
        await Future<void>.delayed(Duration.zero);
        expect(service.detailRequests, 2);
        expect(container.read(provider.notifier), isNot(same(oldNotifier)));
        expect(container.read(provider).isLoading, isTrue);
        expect(container.read(provider).hasValue, isFalse);
        expect(seen.any((value) => value.hasValue), isFalse);

        final newDetail = _detail(loaded: [1, 2, 3, 4], highest: 4);
        pending.complete(newDetail);
        final result = await fresh;
        expect(result.highestPostNumber, 4);
        expect(container.read(provider).value, same(result));
        expect(seen.any((value) => identical(value.value, oldDetail)), isFalse);
      });
    }

    for (final cancelBeforeClear in [false, true]) {
      test('清空前后取消旧详情都不能回填：先取消=$cancelBeforeClear', () async {
        const params = TopicDetailParams(7, instanceId: 'old');
        final sub = container.listen(topicDetailProvider(params), (_, _) {});
        await container.read(topicDetailProvider(params).future);
        if (cancelBeforeClear) sub.close();
        TopicDetailMemoryCache.clear();
        if (!cancelBeforeClear) sub.close();
        await Future<void>.delayed(Duration.zero);
        await open(
          const TopicDetailParams(
            7,
            instanceId: 'new',
            expectedHighestPostNumber: 3,
          ),
        );
        expect(service.detailRequests, 2);
      });
    }

    test('会话已推进但尚未清缓存：旧详情卸载不能供新会话复用', () async {
      const params = TopicDetailParams(7, instanceId: 'old');
      final sub = container.listen(topicDetailProvider(params), (_, _) {});
      await container.read(topicDetailProvider(params).future);
      AuthSession().advance();
      sub.close();
      await Future<void>.delayed(Duration.zero);
      await open(
        const TopicDetailParams(
          7,
          instanceId: 'new',
          expectedHighestPostNumber: 3,
        ),
      );
      expect(service.detailRequests, 2);
    });

    test('已缓存详情不能跨会话取出', () {
      TopicDetailMemoryCache.put(_detail());
      AuthSession().advance();
      expect(
        TopicDetailMemoryCache.take(
          7,
          expectedHighestPostNumber: 3,
          targetPostNumber: null,
        ),
        isNull,
      );
    });
    test('离开后马上从列表点回来、没有新回复：不再请求', () async {
      await open(
        const TopicDetailParams(
          7,
          instanceId: 'a',
          expectedHighestPostNumber: 3,
        ),
      );
      expect(service.detailRequests, 1);
      final again = await open(
        const TopicDetailParams(
          7,
          instanceId: 'b',
          expectedHighestPostNumber: 3,
        ),
      );
      expect(service.detailRequests, 1);
      expect(again.postStream.posts.map((p) => p.postNumber), [1, 2, 3]);
    });

    test('列表显示有新回复：照常请求', () async {
      await open(
        const TopicDetailParams(
          7,
          instanceId: 'a',
          expectedHighestPostNumber: 3,
        ),
      );
      service.next = () => _detail(loaded: [1, 2, 3, 4], highest: 4);
      final again = await open(
        const TopicDetailParams(
          7,
          instanceId: 'b',
          expectedHighestPostNumber: 4,
        ),
      );
      expect(service.detailRequests, 2);
      expect(again.highestPostNumber, 4);
    });

    test('页面里下拉刷新（重建）不读缓存', () async {
      const params = TopicDetailParams(
        7,
        instanceId: 'a',
        expectedHighestPostNumber: 3,
      );
      container.listen(topicDetailProvider(params), (_, _) {});
      await container.read(topicDetailProvider(params).future);
      // 另一个实例离开时留下了一份
      TopicDetailMemoryCache.put(_detail());
      container.invalidate(topicDetailProvider(params));
      await container.read(topicDetailProvider(params).future);
      expect(service.detailRequests, 2);
    });
  });
}
