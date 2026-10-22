import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/category.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/providers/category_provider.dart';
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:fluxdo/utils/relative_time_clock.dart';
import 'package:fluxdo/widgets/topic/painted_topic_card.dart';
import 'package:fluxdo/widgets/topic/topic_item_builder.dart';

Topic _topic() {
  return Topic(
    id: 1,
    title: 'Middle Click Topic',
    slug: 'middle-click-topic',
    postsCount: 1,
    replyCount: 0,
    views: 0,
    likeCount: 0,
    categoryId: '1',
  );
}

void main() {
  // 自绘排版缓存常驻订阅分钟心跳:在测试体外的真实时钟里挂一个监听,
  // 让心跳计时器不落在单个测试的 fake async 里(否则该测试退出时报
  // 「A Timer is still pending」)。
  void keepClockAlive() {}

  setUpAll(() => RelativeTimeClock.instance.addListener(keepClockAlive));
  tearDownAll(
    () => RelativeTimeClock.instance.removeListener(keepClockAlive),
  );

  testWidgets('鼠标中键点击帖子会触发后台开标签回调', (tester) async {
    PlatformUtils.debugDesktopOverride = true;
    addTearDown(() => PlatformUtils.debugDesktopOverride = null);

    var middleClicked = false;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          categoryMapProvider.overrideWith(
            (ref) => const AsyncValue.data(<int, Category>{}),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => buildTopicItem(
                context: context,
                topic: _topic(),
                isSelected: false,
                onTap: () {},
                onMiddleClick: () {
                  middleClicked = true;
                },
                enableLongPress: false,
              ),
            ),
          ),
        ),
      ),
    );

    // 默认话题卡走自绘路径([PaintedTopicCard]),不再是 widget 版 TopicCard。
    final topicCard = find.byType(PaintedTopicCard);
    final center = tester.getCenter(topicCard);
    final gesture = await tester.startGesture(
      center,
      kind: PointerDeviceKind.mouse,
      buttons: kMiddleMouseButton,
    );
    addTearDown(gesture.removePointer);
    await gesture.up();
    await tester.pump();

    expect(middleClicked, isTrue);
  });
}
