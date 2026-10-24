import 'dart:convert';

import 'package:ai_model_manager/ai_model_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('重复模型 ID 仍可通过长按拖动排序并保存顺序', (tester) async {
    final provider = AiProvider(
      id: 'provider-1',
      name: 'Test Provider',
      type: AiProviderType.openai,
      baseUrl: 'https://example.com',
      models: const [
        AiModel(id: 'duplicate', name: 'Model A'),
        AiModel(id: 'duplicate', name: 'Model B'),
        AiModel(id: 'model-c', name: 'Model C'),
      ],
    );

    SharedPreferences.setMockInitialValues({
      'ai_providers': jsonEncode([provider.toJson()]),
      '__secure_fallback__ai_provider_key_provider-1': 'test-key',
    });
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          aiSharedPreferencesProvider.overrideWithValue(prefs),
        ],
        child: MaterialApp(
          home: AiProviderEditPage(provider: provider),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).at(2), 'test-key');
    await tester.pump();

    await tester.tap(find.byIcon(Symbols.layers_rounded));
    await tester.pumpAndSettle();

    final modelAFinder = find.text('Model A');
    final modelCFinder = find.text('Model C');
    expect(modelAFinder, findsOneWidget);
    expect(modelCFinder, findsOneWidget);

    final modelCCard = find.ancestor(
      of: modelCFinder,
      matching: find.byType(ReorderableDelayedDragStartListener),
    );
    final modelACard = find.ancestor(
      of: modelAFinder,
      matching: find.byType(ReorderableDelayedDragStartListener),
    );
    final target = tester.getCenter(modelACard);
    final start = tester.getCenter(modelCCard);
    final drag = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 600));
    await drag.moveTo(target);
    await tester.pump(const Duration(milliseconds: 400));
    await drag.up();
    await tester.pumpAndSettle();

    expect(
      tester.getTopLeft(modelCFinder).dy,
      lessThan(tester.getTopLeft(modelAFinder).dy),
    );

    await tester.tap(find.text(AiL10n.current.save));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    final saved = jsonDecode(prefs.getString('ai_providers')!) as List<dynamic>;
    final savedModels =
        (saved.single as Map<String, dynamic>)['models'] as List<dynamic>;
    expect(
      savedModels
          .map((model) => (model as Map<String, dynamic>)['name'])
          .toList(),
      ['Model C', 'Model A', 'Model B'],
    );
  });
}
