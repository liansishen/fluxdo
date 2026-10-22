import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../l10n/s.dart';
import 'auth_session.dart';
import 'cf_clearance_authority.dart';
import 'network/cookie/boundary_sync_service.dart';
import 'network/cf/cf_challenge_classifier.dart';
import 'session/webview_use.dart';
import 'webview_settings.dart';
import 'windows_webview_environment_service.dart';

/// 在余额所属业务域验证，不以主站通过挑战代替子域验证。
class OAuthCfVerificationService {
  static Future<bool?> verify(BuildContext context, String baseUrl) {
    final origin = Uri.parse(baseUrl);
    if (origin.scheme != 'https' ||
        !const {'credit.linux.do', 'cdk.linux.do'}.contains(origin.host)) {
      throw ArgumentError.value(baseUrl, 'baseUrl', '不支持的余额业务域');
    }
    return Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => _BusinessVerificationPage(baseUrl: origin.origin),
    ));
  }

  /// 只有目标业务接口的明确 JSON 响应才证明挑战已结束。
  static bool isVerifiedResponse(String baseUrl, Map<dynamic, dynamic> result) {
    final actual = Uri.tryParse(result['url']?.toString() ?? '');
    final expected = Uri.parse('$baseUrl/api/v1/oauth/user-info');
    if (actual == null || actual.scheme != expected.scheme ||
        actual.host != expected.host || actual.port != expected.port ||
        actual.path != expected.path || result['redirected'] != false) {
      return false;
    }
    final status = result['status'];
    final contentType = result['contentType']?.toString() ?? '';
    final body = result['body']?.toString() ?? '';
    if (!contentType.toLowerCase().contains('application/json') ||
        CfChallengeClassifier.isChallenge(
          statusCode: status is int ? status : null,
          cfMitigated: result['cfMitigated']?.toString(),
          contentType: contentType,
          body: body,
        )) {
      return false;
    }
    try {
      final data = jsonDecode(body);
      // 业务明确拒绝也说明挑战结束，随后原生重读负责展示授权或权限状态。
      return data is Map &&
          ((status == 200 && data['data'] is Map) || status == 401 || status == 403);
    } on FormatException {
      return false;
    }
  }
}

class _BusinessVerificationPage extends StatefulWidget {
  const _BusinessVerificationPage({required this.baseUrl});
  final String baseUrl;

  @override
  State<_BusinessVerificationPage> createState() => _BusinessVerificationPageState();
}

class _BusinessVerificationPageState extends State<_BusinessVerificationPage> {
  late final WebViewUse _use;
  InAppWebViewController? _controller;
  bool _probing = false;
  bool _finished = false;

  String get _endpoint => '${widget.baseUrl}/api/v1/oauth/user-info';

  @override
  void initState() {
    super.initState();
    _use = WebViewUses.instance.start(
      WebViewUsePurpose.adapterRequest,
      url: _endpoint,
      reason: 'balance_manual_cf_verification',
      generation: AuthSession().generation,
    );
  }

  @override
  void dispose() {
    _use.end(WebViewUseOutcome.aborted);
    super.dispose();
  }

  Future<void> _probe() async {
    final controller = _controller;
    if (_probing || _finished || controller == null) return;
    setState(() => _probing = true);
    try {
      final current = await controller.getUrl();
      if (current == null || Uri.parse(current.toString()).origin != widget.baseUrl) {
        return;
      }
      final response = await controller.callAsyncJavaScript(functionBody: '''
        const response = await fetch('/api/v1/oauth/user-info', {
          credentials: 'include', cache: 'no-store', redirect: 'manual'
        });
        return {
          url: response.url, redirected: response.redirected,
          status: response.status,
          contentType: response.headers.get('content-type'),
          cfMitigated: response.headers.get('cf-mitigated'),
          body: await response.text()
        };
      ''');
      if (!mounted || _finished ||
          !AuthSession().isValid(_use.generation!)) return;
      final result = response?.value;
      if (result is! Map ||
          !OAuthCfVerificationService.isVerifiedResponse(widget.baseUrl, result)) return;
      // 只将已通过该业务接口确认的 clearance 定稿，避免健康旧值挡住新值。
      final authority = CfClearanceAuthority.instance;
      final clearance = await BoundarySyncService.instance.readCookieValueFromWebView(
        currentUrl: _endpoint,
        controller: controller,
        name: 'cf_clearance',
      );
      if (!mounted || !AuthSession().isValid(_use.generation!)) return;
      authority.expectVerifiedSuccessor(clearance);
      try {
        if (clearance != null && clearance.isNotEmpty) {
          final landed = await _use.landVerifiedClearance(clearance, controller: controller);
          if (!landed.completed) return;
        }
        final report = await _use.checkpoint(WebViewUseOutcome.loaded, controller: controller);
        if (!mounted || !AuthSession().isValid(_use.generation!) ||
            report.cookies?.completed != true) return;
      } finally {
        authority.expectVerifiedSuccessor(null);
      }
      authority.recordVerifiedHost(Uri.parse(widget.baseUrl).host);
      _finished = true;
      await _use.end(WebViewUseOutcome.aborted);
      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      // 挑战页或网络尚未就绪，保留页面供用户继续验证或取消。
    } finally {
      if (mounted) setState(() => _probing = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text('${context.l10n.cf_manualVerifyAction} · ${Uri.parse(widget.baseUrl).host}'),
      actions: [TextButton(
        onPressed: _probing ? null : _probe,
        child: Text(context.l10n.common_retry),
      )],
    ),
    body: WebViewSettings.wrapWithScrollFix(
      InAppWebView(
        webViewEnvironment: WindowsWebViewEnvironmentService.instance.environment,
        initialSettings: WebViewSettings.visible,
        initialUserScripts: WebViewSettings.compatPolyfillScripts,
        onReceivedServerTrustAuthRequest: (_, challenge) =>
            WebViewSettings.handleServerTrustAuthRequest(challenge),
        onWebViewCreated: (controller) async {
          _controller = controller;
          await _use.ready;
          if (!mounted) return;
          await controller.loadUrl(urlRequest: URLRequest(url: WebUri(_endpoint)));
        },
        onLoadStop: (controller, _) async {
          await WebViewSettings.injectScrollFix(controller);
          await _probe();
        },
      ),
      getController: () => _controller,
    ),
  );
}
