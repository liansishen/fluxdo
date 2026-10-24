import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/widgets/post/post_item/widgets/post_footer_section/post_footer_section.dart';
import 'package:fluxdo/widgets/post/post_item/widgets/post_header.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late SharedPreferences preferences;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    LocaleSettings.setLocale(AppLocale.zh);
  });

  Widget app({
    String? device = 'iPhone 17 Pro Max',
    double width = 320,
    double scale = 1,
    Brightness brightness = Brightness.light,
  }) {
    final post = Post.fromJson({
      'id': 1,
      'post_number': 1,
      'username': 'tester',
      'name': '测试用户',
      'user_title': '社区成员',
      'ios_device_name': device,
    });
    return ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        currentUserProvider.overrideWith(_GuestUser.new),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.blue,
              brightness: brightness,
            ),
          ),
          locale: const Locale('zh'),
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: AppLocaleUtils.supportedLocales,
          home: Scaffold(
            body: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: Center(
                child: SizedBox(
                  width: width,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      PostHeader(
                        post: post,
                        topicId: 1,
                        isTopicOwner: false,
                        isOwnPost: false,
                        isWhisper: false,
                        cachedAvatarWidget: const SizedBox(
                          width: 40,
                          height: 40,
                        ),
                        isLoadingReplyHistoryNotifier: null,
                        onToggleReplyHistory: null,
                        buildCompactBadge: (_, text, background, foreground) =>
                            Text(text),
                        timeAndFloorWidget: const Text('#1'),
                      ),
                      PostFooterSection(
                        post: post,
                        topicId: 1,
                        topicHasAcceptedAnswer: false,
                        padding: EdgeInsets.zero,
                        onReply: null,
                        onEdit: null,
                        onShareAsImage: null,
                        onRefreshPost: null,
                        onJumpToPost: null,
                        onSolutionChanged: null,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('型号只在用户名旁出现一次，底部不重复显示', (tester) async {
    await tester.pumpWidget(app());
    expect(find.text('iPhone 17 Pro Max'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(PostHeader),
        matching: find.text('iPhone 17 Pro Max'),
      ),
      findsOneWidget,
    );
    expect(find.byTooltip('iPhone 17 Pro Max'), findsOneWidget);
    expect(find.text('@tester'), findsOneWidget);
    expect(find.text('社区成员'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('缺少或空白型号不产生空徽标', (tester) async {
    for (final device in <String?>[null, '', '   ']) {
      await tester.pumpWidget(app(device: device));
      expect(find.byIcon(Icons.smartphone_rounded), findsNothing);
      expect(find.text('@tester'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('窄屏大字号保留头衔和完整型号提示，不发生溢出', (tester) async {
    final device = List.filled(12, 'iPhone 17 Pro Max').join(' ');
    for (final brightness in Brightness.values) {
      for (final scale in [1.0, 2.5]) {
        await tester.pumpWidget(
          app(device: device, width: 320, scale: scale, brightness: brightness),
        );
        expect(find.byTooltip(device), findsOneWidget);
        expect(find.text('@tester'), findsOneWidget);
        expect(find.text('社区成员'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    }
  });
}

class _GuestUser extends CurrentUserNotifier {
  @override
  User? build() => null;
}
