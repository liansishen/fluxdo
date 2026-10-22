import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';

import 'app_logger.dart';

/// 每次点击对应一条诊断链路，正式版也落盘，不记录请求头或 URL 查询参数。
class DownloadDiagnostics {
  DownloadDiagnostics(String url)
    : id = '${DateTime.now().microsecondsSinceEpoch}-${_sequence++}',
      url = sanitizeUrl(url);

  static int _sequence = 0;
  final String id;
  final String url;
  String stage = 'start';
  String? directory;
  String? savePath;
  String? temporaryPath;
  int receivedBytes = 0;
  int? totalBytes;

  Map<String, dynamic> get fields => {
    'downloadId': id,
    'stage': stage,
    'url': url,
    'platform': Platform.operatingSystem,
    if (directory != null) 'directory': directory,
    if (savePath != null) 'savePath': savePath,
    if (temporaryPath != null) 'temporaryPath': temporaryPath,
    'receivedBytes': receivedBytes,
    if (totalBytes != null) 'totalBytes': totalBytes,
  };

  void enter(String nextStage) {
    stage = nextStage;
    AppLogger.info('下载阶段: $stage', tag: 'Download', fields: fields);
  }

  void failure(
    Object error,
    StackTrace stackTrace, {
    bool fatal = true,
    String? atStage,
  }) {
    final failedStage = atStage ?? stage;
    final fileError = error is FileSystemException
        ? error
        : error is DioException && error.error is FileSystemException
        ? error.error as FileSystemException
        : null;
    final details = <String, dynamic>{
      ...fields,
      'stage': failedStage,
      'errorType': error.runtimeType.toString(),
      'fatal': fatal,
      if (fileError != null) ...{
        'filePath': fileError.path,
        'osErrorCode': fileError.osError?.errorCode,
      },
      if (error is PlatformException) ...{
        'platformCode': error.code,
        'platformDetails': redact(error.details.toString()),
      },
      if (error is DioException) ...{
        'dioType': error.type.name,
        'statusCode': error.response?.statusCode,
        'requestUrl': sanitizeUrl(error.requestOptions.uri.toString()),
        if (error.error != null)
          'causeType': error.error.runtimeType.toString(),
      },
    };
    // 不对 Dio 异常整体调用 toString，避免插件错误携带请求头和响应正文。
    final message = error is DioException
        ? '${error.type.name}: ${redact(error.message ?? '')}'
        : redact(error.toString());
    final safeStackTrace = StackTrace.fromString(redact(stackTrace.toString()));
    if (fatal) {
      AppLogger.error(
        '下载失败: $failedStage',
        tag: 'Download',
        error: message,
        stackTrace: safeStackTrace,
        fields: details,
      );
    } else {
      AppLogger.warning(
        '下载辅助步骤失败: $failedStage',
        tag: 'Download',
        fields: {
          ...details,
          'error': message,
          'stackTrace': safeStackTrace.toString(),
        },
      );
    }
  }

  static String sanitizeUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasAuthority) return '<invalid-url>';
    return Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: uri.path,
    ).toString();
  }

  /// 异常文案只保留 URL 的协议、主机和路径，不留下凭据、签名或片段。
  static String redact(String message) => message.replaceAllMapped(
    RegExp(r'''https?://[^\s<>"']+''', caseSensitive: false),
    (match) => sanitizeUrl(match[0]!),
  );
}
