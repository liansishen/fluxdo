import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/services/preloaded_data_service.dart';
import 'package:fluxdo/services/uploads/s3_multipart_upload.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Storage implements HttpClientAdapter {
  _Storage(this.mode);
  final String mode;
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    await requestStream?.drain<void>();
    if (mode == 'storage') {
      throw DioException.connectionError(
        requestOptions: options,
        reason: '不可达',
      );
    }
    if (mode == 'cancel') {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.cancel,
      );
    }
    return ResponseBody.fromString(
      '',
      200,
      headers: {
        'etag': ['etag'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final mode in ['storage', 'cancel', 'create', 'presign', 'complete']) {
    test('上传路由边界：$mode', () async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({
        'linux_do_username': 'tester',
      });
      expect(
        await PreloadedDataService().hydrateFromHtml(
          '<meta id="data-discourse-setup">'
          '<script id="data-preloaded" type="application/json">${jsonEncode({
            'currentUser': {'id': 1, 'username': 'tester'},
            'siteSettings': {'enable_direct_s3_uploads': true},
            'site': {'categories': []},
          })}</script>',
        ),
        true,
      );
      final storage = _Storage(mode);
      S3MultipartUpload.debugStorageFactory = () =>
          Dio()..httpClientAdapter = storage;
      addTearDown(() => S3MultipartUpload.debugStorageFactory = null);
      final paths = <String>[];
      final service = DiscourseService();
      final interceptor = InterceptorsWrapper(
        onRequest: (options, handler) {
          paths.add(options.path);
          final failedAction = switch (mode) {
            'create' => '/uploads/create-multipart.json',
            'presign' => '/uploads/batch-presign-multipart-parts.json',
            'complete' => '/uploads/complete-multipart.json',
            _ => '',
          };
          if (options.path == failedAction) {
            handler.reject(
              DioException.connectionError(
                requestOptions: options,
                reason: '控制请求失败',
              ),
            );
            return;
          }
          if (options.path == '/uploads/create-multipart.json') {
            expect((options.data as Map)['file_name'], 'photo.jpg');
          }
          if (options.path == '/uploads.json') {
            final form = options.data as FormData;
            expect(form.files.single.value.filename, 'photo.jpg');
          }
          final data = switch (options.path) {
            '/uploads/create-multipart.json' => {
              'external_upload_identifier': 'external',
              'unique_identifier': 'unique',
            },
            '/uploads/batch-presign-multipart-parts.json' => {
              'presigned_urls': {
                '1': 'https://storage.test/1?signature=secret',
              },
            },
            '/uploads.json' => {'id': 7, 'short_url': 'upload://standard.jpeg'},
            _ => {'success': 'OK'},
          };
          handler.resolve(Response(requestOptions: options, data: data));
        },
      );
      service.dio.interceptors.insert(0, interceptor);
      addTearDown(() => service.dio.interceptors.remove(interceptor));
      final dir = await Directory.systemTemp.createTemp('upload-route');
      addTearDown(() => dir.delete(recursive: true));
      final file = await File(
        '${dir.path}${Platform.pathSeparator}photo.jpg',
      ).writeAsBytes(List.filled(32, 7));
      final future = service.uploadFile(file.path);
      if (mode == 'storage') {
        expect((await future).shortUrl, 'upload://standard.jpeg');
        expect(storage.calls, 3);
        expect(paths, contains('/uploads/abort-multipart.json'));
        expect(paths, isNot(contains('/uploads/complete-multipart.json')));
        expect(paths.last, '/uploads.json');
      } else {
        await expectLater(
          future,
          throwsA(
            isA<DioException>().having(
              (e) => e.type,
              '错误类型',
              mode == 'cancel'
                  ? DioExceptionType.cancel
                  : DioExceptionType.connectionError,
            ),
          ),
        );
        expect(paths, isNot(contains('/uploads.json')));
        expect(
          paths.where((p) => p == '/uploads/create-multipart.json'),
          hasLength(1),
        );
        expect(storage.calls, mode == 'create' || mode == 'presign' ? 0 : 1);
      }
    });
  }
}
