import 'dart:convert';
import 'dart:io';

import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/services/download_service.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:fluxdo/services/log/log_writer.dart';
import 'package:fluxdo/services/log/logger_utils.dart';
import 'package:fluxdo/services/public_file_channel.dart';
import 'package:fluxdo/utils/platform_utils.dart';
import 'package:fluxdo/utils/share_utils.dart';
import 'package:path/path.dart' as p;
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _Picker extends FilePicker {
  int calls = 0;
  Uint8List? bytes;
  Object? error;
  String? result = '/export/app_log_share.jsonl';

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async {
    calls++;
    this.bytes = bytes;
    if (error != null) throw error!;
    return result;
  }
}

class _Paths extends PathProviderPlatform {
  _Paths(this.downloadsPath);
  final String downloadsPath;
  int calls = 0;

  @override
  Future<String?> getDownloadsPath() async {
    calls++;
    return downloadsPath;
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.fluxdo/public_file');
  late Directory sandbox;
  late File source;
  late List<String> nativeCalls;
  late _Picker picker;
  late _Paths paths;
  late PathProviderPlatform originalPaths;
  FilePicker? originalPicker;
  Map<String, Object?>? nativeResult;
  Object? nativeError;

  setUp(() async {
    sandbox = Directory.systemTemp.createTempSync('file-save-test-');
    source = File(p.join(sandbox.path, 'app_log_share.jsonl'))
      ..writeAsStringSync('{"message":"测试日志"}\n');
    await LogWriter.initForTesting(Directory(p.join(sandbox.path, 'logs')));
    try {
      originalPicker = FilePicker.platform;
    } catch (_) {
      originalPicker = null;
    }
    picker = _Picker();
    FilePicker.platform = picker;
    originalPaths = PathProviderPlatform.instance;
    paths = _Paths(p.join(sandbox.path, 'Downloads'));
    PathProviderPlatform.instance = paths;
    PlatformUtils.debugDesktopOverride = false;
    PublicFileChannel.debugPlatformOverride = TargetPlatform.iOS;
    DownloadService.debugIsIOSOverride = false;
    nativeCalls = [];
    nativeError = null;
    nativeResult = {'uri': '', 'displayName': '用户命名的日志.jsonl'};
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      nativeCalls.add(call.method);
      expect((call.arguments as Map)['sourcePath'], source.path);
      if (nativeError != null) throw nativeError!;
      return nativeResult;
    });
  });

  tearDown(() async {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    if (originalPicker != null) FilePicker.platform = originalPicker!;
    PathProviderPlatform.instance = originalPaths;
    PlatformUtils.debugDesktopOverride = null;
    PublicFileChannel.debugPlatformOverride = null;
    DownloadService.debugIsIOSOverride = null;
    await LogWriter.resetForTesting();
    sandbox.deleteSync(recursive: true);
  });

  Future<List<Map<String, dynamic>>> readLogs() async {
    await LogWriter.instance.flushNow();
    return (await LogWriter.readAllContent())
        .split('\n')
        .where((line) => line.isNotEmpty)
        .map((line) => jsonDecode(line) as Map<String, dynamic>)
        .toList();
  }


  test('iOS 保存日志直接调用原生另存为，不写入应用下载目录', () async {
    final outcome = await ShareUtils.saveFile(XFile(source.path));
    expect(nativeCalls, ['saveAs']);
    expect(outcome.shared, isTrue);
    expect(outcome.displayName, '用户命名的日志.jsonl');
    expect(outcome.finalPath, isNull);
    expect(picker.calls, 0);
    expect(paths.calls, 0);
    expect(Directory(paths.downloadsPath).existsSync(), isFalse);
  });

  test('iOS 直接请求公共下载目录时不会调用原生通道', () async {
    expect(
      await PublicFileChannel.saveToDownloads(
        sourcePath: source.path,
        fileName: p.basename(source.path),
      ),
      isNull,
    );
    expect(nativeCalls, isEmpty);
  });

  test('iOS 取消系统保存面板后不启用其他保存方式，也不记录错误', () async {
    nativeResult = null;
    final outcome = await ShareUtils.saveFile(XFile(source.path));
    expect(outcome.shared, isFalse);
    expect(nativeCalls, ['saveAs']);
    expect(picker.calls, 0);
    expect(paths.calls, 0);
    expect(await readLogs(), isEmpty);
  });

  testWidgets('原生通道缺失时携带真实文件内容进入备用面板，并持久化异常', (tester) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          home: const Scaffold(body: SizedBox.shrink()),
        ),
      ),
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    final print = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {};
    try {
      final outcome = await tester.runAsync(
        () => ShareUtils.saveFile(XFile(source.path)),
      );
      expect(outcome!.shared, isTrue);
    } finally {
      debugPrint = print;
    }
    expect(picker.calls, 1);
    expect(picker.bytes, source.readAsBytesSync());
    expect(paths.calls, 0);
    final warning = (await tester.runAsync(readLogs))!.single;
    expect(warning['level'], 'warning');
    expect(warning['stage'], 'nativeSaveAs');
    expect(warning['errorType'], 'MissingPluginException');
    expect(warning['sourcePath'], source.path);
    expect(warning['stackTrace'], isNotEmpty);
  });

  testWidgets('原生及备用面板都失败时显示错误，异常进入正式版日志', (tester) async {
    nativeError = PlatformException(code: 'NO_VIEW_CONTROLLER');
    picker.error = PlatformException(code: 'SAVE_FAILED');
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          home: const Scaffold(body: SizedBox.shrink()),
        ),
      ),
    );
    final outcome = await tester.runAsync(
      () => ShareUtils.saveFile(XFile(source.path)),
    );
    expect(outcome!.shared, isFalse);
    await tester.pumpAndSettle();
    expect(find.text(S.current.share_saveFailed), findsOneWidget);
    final entries = await tester.runAsync(readLogs);
    expect(entries!.map((entry) => entry['stage']), [
      'nativeSaveAs',
      'pickerSaveAs',
    ]);
    expect(entries.map((entry) => entry['platformCode']), [
      'NO_VIEW_CONTROLLER',
      'SAVE_FAILED',
    ]);
    expect(entries.last['level'], 'error');
    expect(entries.last['stackTrace'], isNotEmpty);
    await tester.pump(const Duration(seconds: 7));
    await tester.pumpAndSettle();
  });

  test('Android 保留公共下载目录保存及 content URI 返回', () async {
    PublicFileChannel.debugPlatformOverride = TargetPlatform.android;
    nativeResult = {
      'uri': 'content://downloads/log',
      'displayName': '日志.jsonl',
    };
    final outcome = await ShareUtils.saveFile(XFile(source.path));
    expect(nativeCalls, ['saveToDownloads']);
    expect(outcome.isContentUri, isTrue);
    expect(outcome.displayName, '日志.jsonl');
    expect(paths.calls, 0);
  });

  test('Android 不支持公共下载目录时保留应用内文件副本', () async {
    PublicFileChannel.debugPlatformOverride = TargetPlatform.android;
    nativeResult = null;
    final outcome = await ShareUtils.saveFile(XFile(source.path));
    expect(outcome.shared, isTrue);
    expect(nativeCalls, ['saveToDownloads']);
    expect(paths.calls, 1);
    expect(
      File(outcome.finalPath!).readAsStringSync(),
      source.readAsStringSync(),
    );
    expect(picker.calls, 0);
  });

  test('Android 公共目录写入异常时保留应用副本并留下非致命诊断', () async {
    PublicFileChannel.debugPlatformOverride = TargetPlatform.android;
    nativeError = PlatformException(code: 'MEDIASTORE_FAILED');
    final outcome = await ShareUtils.saveFile(XFile(source.path));
    expect(outcome.shared, isTrue);
    expect(outcome.isContentUri, isFalse);
    expect(File(outcome.finalPath!).readAsBytesSync(), source.readAsBytesSync());
    final warning = (await readLogs()).singleWhere(
      (entry) => entry['tag'] == 'FileSave',
    );
    expect(warning['level'], 'warning');
    expect(warning['stage'], 'publicDownloads');
    expect(warning['platformCode'], 'MEDIASTORE_FAILED');
    expect(picker.calls, 0);
  });

  test('Android 取消 SAF 另存为时不静默改存其他位置', () async {
    PublicFileChannel.debugPlatformOverride = TargetPlatform.android;
    nativeResult = null;
    final outcome = await ShareUtils.saveFileAs(XFile(source.path));
    expect(outcome.shared, isFalse);
    expect(nativeCalls, ['saveAs']);
    expect(paths.calls, 0);
    expect(picker.calls, 0);
    expect(await readLogs(), isEmpty);
  });

  testWidgets('桌面保存仍将文件复制到用户选择的位置', (tester) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          home: const Scaffold(body: SizedBox.shrink()),
        ),
      ),
    );
    PlatformUtils.debugDesktopOverride = true;
    picker.result = p.join(sandbox.path, 'selected.jsonl');
    final outcome = await tester.runAsync(
      () => ShareUtils.saveFile(XFile(source.path)),
    );
    expect(outcome!.finalPath, picker.result);
    expect(File(picker.result!).readAsStringSync(), source.readAsStringSync());
    expect(picker.bytes, isNull);
    expect(nativeCalls, isEmpty);
  });

  for (final entry in ['saveFile', 'saveFileAs']) {
    testWidgets('桌面 $entry 面板失败时给出错误提示并记录 picker 阶段', (tester) async {
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            navigatorKey: navigatorKey,
            home: const Scaffold(body: SizedBox.shrink()),
          ),
        ),
      );
      PlatformUtils.debugDesktopOverride = true;
      picker.error = PlatformException(
        code: 'PICKER_FAILED',
        message: 'https://user:password@example.com/file?token=secret#fragment',
      );
      final outcome = await tester.runAsync(
        () => entry == 'saveFile'
            ? ShareUtils.saveFile(XFile(source.path))
            : ShareUtils.saveFileAs(XFile(source.path)),
      );
      expect(outcome!.shared, isFalse);
      await tester.pumpAndSettle();
      expect(find.text(S.current.share_saveFailed), findsOneWidget);
      final entries = (await tester.runAsync(readLogs))!;
      expect(entries.single['stage'], 'desktopPicker');
      expect(entries.single['platformCode'], 'PICKER_FAILED');
      final logged = jsonEncode(entries);
      expect(logged, isNot(contains('password')));
      expect(logged, isNot(contains('secret')));
      expect(logged, isNot(contains('fragment')));
      expect(nativeCalls, isEmpty);
      await tester.pump(const Duration(seconds: 7));
      await tester.pumpAndSettle();
    });
  }

  testWidgets('桌面用户取消保存不复制文件且不记录失败', (tester) async {
    // 桌面另存为对话框标题走 S.current(依赖 navigatorKey.currentContext),
    // 因此这里必须挂起真实应用树,与其余桌面用例同口径。
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          home: const Scaffold(body: SizedBox.shrink()),
        ),
      ),
    );
    PlatformUtils.debugDesktopOverride = true;
    picker.result = null;
    final outcome = await tester.runAsync(
      () => ShareUtils.saveFile(XFile(source.path)),
    );
    expect(outcome!.shared, isFalse);
    expect(nativeCalls, isEmpty);
    // 日志落盘是真实异步 IO,必须走 runAsync 才不会被 fake async 卡住。
    expect(await tester.runAsync(readLogs), isEmpty);
    expect(source.readAsStringSync(), '{"message":"测试日志"}\n');
  });

  testWidgets('桌面复制失败时提示并记录 copy 阶段而非 picker 阶段', (tester) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          home: const Scaffold(body: SizedBox.shrink()),
        ),
      ),
    );
    PlatformUtils.debugDesktopOverride = true;
    picker.result = p.join(sandbox.path, 'missing', 'selected.jsonl');
    final outcome = await tester.runAsync(
      () => ShareUtils.saveFile(XFile(source.path)),
    );
    expect(outcome!.shared, isFalse);
    await tester.pumpAndSettle();
    expect(find.text(S.current.share_saveFailed), findsOneWidget);
    final failure = (await tester.runAsync(readLogs))!.single;
    expect(failure['stage'], 'desktopCopy');
    expect(failure['osErrorCode'], isNotNull);
    expect(failure['errorType'], isNotEmpty);
    await tester.pump(const Duration(seconds: 7));
    await tester.pumpAndSettle();
  });

  test('日志导出文件无法生成时留下独立的生成阶段异常', () async {
    final blocked = Directory(
      p.join(sandbox.path, 'logs', 'app_log_share.jsonl'),
    );
    blocked.createSync();
    await expectLater(
      LoggerUtils.getShareFilePath(),
      throwsA(isA<FileSystemException>()),
    );
    final failure = (await readLogs()).singleWhere(
      (entry) => entry['tag'] == 'LogExport',
    );
    expect(failure['stage'], 'writeExportFile');
    // 日志里的路径由生产代码拼出,Windows 上分隔符可能与 p.join 混用,
    // 用 p.equals 做规范化比较(仍指向同一个文件)。
    expect(p.equals(failure['sourcePath'] as String, blocked.path), isTrue);
    expect(failure['osErrorCode'], isNotNull);
    expect(failure['stackTrace'], isNotEmpty);
    expect(nativeCalls, isEmpty);
  });
}
