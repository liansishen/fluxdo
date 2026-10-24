import 'package:fluxdo/l10n/s.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_tools_anchor.dart';
import 'package:fluxdo/widgets/markdown_editor/composer_tools_panel.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;

void main() {
  testWidgets('工具分组通过 headingLevel 暴露移动端标题语义', (tester) async {
    final semantics = tester.ensureSemantics();
    final anchor = ComposerToolsAnchor()
      ..actions = [
        ComposerToolAction(
          id: 'bold',
          label: '加粗',
          icon: const Icon(Icons.format_bold),
          run: () {},
        ),
      ];
    addTearDown(anchor.dispose);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          home: Scaffold(body: ComposerExpandedTools(anchor: anchor)),
        ),
      ),
    );
    final heading = find.byKey(const ValueKey('composer-tools-group-format'));
    expect(heading, findsOneWidget);
    expect(tester.getSemantics(heading).getSemanticsData().headingLevel, 2);
    semantics.dispose();
  });
}
