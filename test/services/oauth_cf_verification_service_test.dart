import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/oauth_cf_verification_service.dart';

void main() {
  for (final baseUrl in ['https://credit.linux.do', 'https://cdk.linux.do']) {
    Map<String, dynamic> response({
      int status = 200,
      String? url,
      String? contentType,
      String? cfMitigated,
      String? body,
      bool redirected = false,
    }) => {
      'url': url ?? '$baseUrl/api/v1/oauth/user-info',
      'status': status,
      'contentType': contentType ?? 'application/json; charset=utf-8',
      'cfMitigated': cfMitigated,
      'body': body ?? jsonEncode({'data': {'username': 'alice'}}),
      'redirected': redirected,
    };

    test('$baseUrl 只有业务域实际返回用户信息才完成验证', () {
      expect(OAuthCfVerificationService.isVerifiedResponse(baseUrl, response()), isTrue);
      for (final url in [
        'https://linux.do/api/v1/oauth/user-info',
        'https://connect.linux.do/api/v1/oauth/user-info',
        'https://example.com/api/v1/oauth/user-info',
        '$baseUrl/dashboard',
        'http://${Uri.parse(baseUrl).host}/api/v1/oauth/user-info',
        'about:blank',
        '',
      ]) {
        expect(OAuthCfVerificationService.isVerifiedResponse(baseUrl, response(url: url)), isFalse);
      }
    });

    test('$baseUrl 业务401结束挑战，由后续余额请求处理授权过期', () {
      expect(OAuthCfVerificationService.isVerifiedResponse(baseUrl,
        response(status: 401, body: '{"message":"未登录"}')), isTrue);
    });

    test('$baseUrl 普通JSON403不是挑战也不是自动重新授权', () {
      expect(OAuthCfVerificationService.isVerifiedResponse(baseUrl,
        response(status: 403, body: '{"message":"权限不足"}')), isTrue);
    });

    test('$baseUrl 挑战、重定向、损坏数据不能伪装验证成功', () {
      for (final value in [
        response(cfMitigated: 'challenge'),
        response(status: 403, contentType: 'text/html', body: '<script>cf_chl_opt={}</script>'),
        response(status: 503),
        response(redirected: true),
        response(body: 'not json'),
        response(body: '{"data":null}'),
      ]) {
        expect(OAuthCfVerificationService.isVerifiedResponse(baseUrl, value), isFalse);
      }
    });
  }
}
