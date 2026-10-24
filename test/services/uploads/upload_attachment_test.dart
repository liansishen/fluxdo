import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/services/local_notification_service.dart';
import 'package:fluxdo/services/preloaded_data_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('附件上限前置检查、等于上限允许、媒体改名及 413 分类', (tester) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          navigatorKey: navigatorKey,
          home: const SizedBox.shrink(),
        ),
      ),
    );
    await tester.runAsync(() async {
      SharedPreferences.setMockInitialValues({});
      expect(
        await PreloadedDataService().hydrateFromHtml(
          '<meta id="data-discourse-setup">'
          '<script id="data-preloaded" type="application/json">${jsonEncode({
            'currentUser': {'id': 1, 'username': 'tester'},
            'siteSettings': {'enable_direct_s3_uploads': false, 'max_attachment_size_kb': 1},
            'site': {'categories': []},
          })}</script>',
        ),
        true,
      );
      final dir = await Directory.systemTemp.createTemp('upload-attachment');
      addTearDown(() => dir.delete(recursive: true));
      final service = DiscourseService();
      var requests = 0;
      var reject = false;
      final names = <String>[];
      final interceptor = InterceptorsWrapper(
        onRequest: (options, handler) {
          requests++;
          expect(options.path, '/uploads.json');
          names.add((options.data as FormData).files.single.value.filename!);
          if (reject) {
            handler.reject(
              DioException.badResponse(
                statusCode: 413,
                requestOptions: options,
                response: Response(requestOptions: options, statusCode: 413),
              ),
            );
          } else {
            handler.resolve(
              Response(
                requestOptions: options,
                data: {'id': 1, 'short_url': 'upload://accepted'},
              ),
            );
          }
        },
      );
      service.dio.interceptors.insert(0, interceptor);
      addTearDown(() => service.dio.interceptors.remove(interceptor));
      Future<File> file(String name, int size) => File(
        '${dir.path}${Platform.pathSeparator}$name',
      ).writeAsBytes(List.filled(size, 1));
      final oversized = await file('large.pdf', 1025);
      await expectLater(
        service.uploadFile(oversized.path),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            '附件大小提示',
            contains(
              S.current.error_fileTooBigLimit(
                UploadResult.formatFileSize(1024),
                UploadResult.formatFileSize(1025),
              ),
            ),
          ),
        ),
      );
      expect(requests, 0);
      final exact = await file('exact.pdf', 1024);
      await service.uploadFile(exact.path);
      expect(names.last, 'exact.pdf');
      final media = await file('recording.mp4', 512);
      await service.uploadMediaAsXz(media.path);
      expect(names.last, 'recording.xz');
      reject = true;
      await expectLater(
        service.uploadFile(exact.path),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            '附件 413',
            contains(S.current.error_fileTooBig),
          ),
        ),
      );
      final image = await file('image.jpg', 2048);
      await expectLater(
        service.uploadFile(image.path),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            '图片 413',
            contains(S.current.error_imageTooBig),
          ),
        ),
      );
      await expectLater(
        service.uploadMediaAsXz(media.path),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            '媒体 413',
            contains(S.current.error_fileTooBig),
          ),
        ),
      );
    });
  });
}
