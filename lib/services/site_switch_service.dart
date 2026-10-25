import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/forum_site.dart';
import 'app_logger.dart';
import 'cf_clearance_refresh_service.dart';
import 'log/log_writer.dart';
import 'network/doh/network_settings_service.dart';
import 'network/doh_proxy/doh_proxy_service.dart';
import 'site_context.dart';
import 'site_data_lifecycle.dart';
import 'user_api_key_service.dart';

/// 切站是保存选择并重启运行环境，不是登出；旧站凭据与 Cookie 全部保留。
class SiteSwitchService {
  SiteSwitchService._();

  static final instance = SiteSwitchService._();
  static const _channel = MethodChannel('fluxdo/site_switch');
  static const pendingUrlKey = 'pending_site_open_url';

  final ValueNotifier<bool> _isSwitching = ValueNotifier(false);
  ValueListenable<bool> get isSwitching => _isSwitching;

  Future<void> switchTo(ForumSite target, {Uri? openUrl}) async {
    if (target == SiteContext.current) return;
    if (_isSwitching.value) throw StateError('正在切换站点');
    _isSwitching.value = true;
    SharedPreferences? preferences;
    String? previousUrl;
    var pendingUrlChanged = false;
    var selectionSaved = false;
    var mobileServicesStopped = false;
    var stage = 'preferences';
    final fields = {
      'fromSite': SiteContext.current.id,
      'toSite': target.id,
      'platform': Platform.operatingSystem,
    };
    AppLogger.info('开始切换站点', tag: 'SiteSwitch', fields: fields);
    try {
      preferences = await SharedPreferences.getInstance();
      previousUrl = preferences.getString(pendingUrlKey);
      stage = 'validate_url';
      if (openUrl != null && !await _isValidTargetUrl(target, openUrl)) {
        throw ArgumentError.value(target.id, 'target', '链接与目标站点不匹配');
      }
      stage = 'check_support';
      if (await _channel.invokeMethod<bool>('isSupported') != true) {
        throw PlatformException(code: 'SITE_SWITCH_UNSUPPORTED');
      }
      // 先保存编辑器当前值与延迟落盘数据，失败时不离开当前站点。
      stage = 'flush_site_data';
      await SiteDataLifecycle.flushBeforeSwitch();
      stage = 'save_selection';
      pendingUrlChanged = true;
      if (openUrl == null) {
        await preferences.remove(pendingUrlKey);
      } else if (!await preferences.setString(
        pendingUrlKey,
        openUrl.toString(),
      )) {
        throw const FileSystemException('无法保存待打开的站点链接');
      }
      await SiteContext.persistSelection(target);
      selectionSaved = true;

      // 移动端代理由进程级 Rust 状态持有，重建引擎前必须停止。
      // iOS 不退出进程；否则新引擎会继承旧代理和验证 WebView 的运行状态。
      if (Platform.isAndroid || Platform.isIOS) {
        stage = 'stop_mobile_services';
        mobileServicesStopped = true;
        await CfClearanceRefreshService().stop();
        await DohProxyService.instance.stop();
      }
      stage = 'restart';
      AppLogger.info(
        '站点选择已保存，准备重建运行环境',
        tag: 'SiteSwitch',
        fields: fields,
      );
      await LogWriter.instance.flushNow();
      // 桌面重启进程，iOS 重建引擎；旧环境不再接受第二次切换。
      await _channel.invokeMethod<void>('restart');
    } catch (error, stackTrace) {
      // 只记录类型、平台错误码和栈，不落盘可能含认证参数的异常正文或链接。
      AppLogger.error(
        '切换站点失败，正在恢复原站',
        tag: 'SiteSwitch',
        stackTrace: stackTrace,
        fields: {
          ...fields,
          'stage': stage,
          'errorType': error.runtimeType.toString(),
          if (error is PlatformException) 'errorCode': error.code,
        },
      );
      try {
        if (selectionSaved) {
          await SiteContext.persistSelection(SiteContext.current);
        }
        if (pendingUrlChanged && preferences != null) {
          if (previousUrl == null) {
            await preferences.remove(pendingUrlKey);
          } else {
            await preferences.setString(pendingUrlKey, previousUrl);
          }
        }
        if (mobileServicesStopped) {
          await NetworkSettingsService.instance.restartProxy();
          CfClearanceRefreshService().start();
        }
      } catch (recoveryError, recoveryStackTrace) {
        AppLogger.error(
          '切换失败后恢复原站状态失败',
          tag: 'SiteSwitch',
          stackTrace: recoveryStackTrace,
          fields: {
            ...fields,
            'stage': 'rollback',
            'errorType': recoveryError.runtimeType.toString(),
            if (recoveryError is PlatformException)
              'errorCode': recoveryError.code,
          },
        );
      } finally {
        _isSwitching.value = false;
      }
      rethrow;
    }
  }

  static Future<bool> _isValidTargetUrl(ForumSite target, Uri uri) async {
    if (ForumSite.fromUri(uri) == target) return true;
    if (uri.scheme != 'discourse' ||
        uri.host != 'auth_redirect' ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort) {
      return false;
    }
    return await UserApiKeyService().resolveAuthRedirectSite(uri) == target;
  }
}
