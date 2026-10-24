import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/doh/network_settings_service.dart';
import 'package:fluxdo/services/network/vpn_auto_toggle_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('起代理前检测到 VPN 直接压制 DoH 偏好，断开后恢复', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    expect(NetworkSettingsService.instance.isInitialized, isFalse);
    final toggle = VpnAutoToggleService.instance..initialize(prefs);

    await toggle.syncInitialState([
      ConnectivityResult.wifi,
      ConnectivityResult.vpn,
    ]);
    expect(NetworkSettingsService.storedDohEnabled(prefs), isFalse);
    expect(toggle.isDohSuppressed, isTrue);

    await toggle.syncInitialState([ConnectivityResult.wifi]);
    expect(NetworkSettingsService.storedDohEnabled(prefs), isTrue);
    expect(toggle.isDohSuppressed, isFalse);
  });

  test('DoH 原本关闭则不登记压制，VPN 断开不擅自打开', () async {
    SharedPreferences.setMockInitialValues({'doh_enabled': false});
    final prefs = await SharedPreferences.getInstance();
    final toggle = VpnAutoToggleService.instance..initialize(prefs);

    await toggle.syncInitialState([ConnectivityResult.vpn]);
    expect(toggle.isDohSuppressed, isFalse);
    await toggle.syncInitialState([ConnectivityResult.mobile]);
    expect(NetworkSettingsService.storedDohEnabled(prefs), isFalse);
  });
}
