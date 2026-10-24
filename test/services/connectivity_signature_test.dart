import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/connectivity_service.dart';

void main() {
  group('ConnectivityService.signatureOf', () {
    test('单一连接类型直接用名字', () {
      expect(
        ConnectivityService.signatureOf([ConnectivityResult.wifi]),
        'wifi',
      );
      expect(
        ConnectivityService.signatureOf([ConnectivityResult.mobile]),
        'mobile',
      );
    });

    test('多个类型按名字排序后用 | 连接，与输入顺序无关', () {
      expect(
        ConnectivityService.signatureOf([
          ConnectivityResult.wifi,
          ConnectivityResult.vpn,
        ]),
        'vpn|wifi',
      );
      expect(
        ConnectivityService.signatureOf([
          ConnectivityResult.vpn,
          ConnectivityResult.wifi,
        ]),
        'vpn|wifi',
      );
      expect(
        ConnectivityService.signatureOf([
          ConnectivityResult.wifi,
          ConnectivityResult.mobile,
          ConnectivityResult.ethernet,
        ]),
        'ethernet|mobile|wifi',
      );
    });

    test('重复项去重', () {
      expect(
        ConnectivityService.signatureOf([
          ConnectivityResult.wifi,
          ConnectivityResult.wifi,
          ConnectivityResult.vpn,
          ConnectivityResult.wifi,
        ]),
        'vpn|wifi',
      );
    });

    test('none 被过滤掉', () {
      expect(
        ConnectivityService.signatureOf([
          ConnectivityResult.none,
          ConnectivityResult.wifi,
        ]),
        'wifi',
      );
      expect(ConnectivityService.signatureOf([ConnectivityResult.none]), '');
      expect(
        ConnectivityService.signatureOf([
          ConnectivityResult.none,
          ConnectivityResult.none,
        ]),
        '',
      );
    });

    test('空列表返回空串', () {
      expect(ConnectivityService.signatureOf(const []), '');
    });
  });

  group('冷启动网络签名补种', () {
    final service = ConnectivityService();
    setUp(() => service.networkSignature.value = null);
    tearDown(() => service.networkSignature.value = null);

    test('有效初始结果在代理启动前可用', () {
      service.seedInitialSignature([
        ConnectivityResult.wifi,
        ConnectivityResult.vpn,
      ]);
      expect(service.networkSignature.value, 'vpn|wifi');
    });

    test('未知和 none 不登记，后到的有效结果仍能补种', () {
      service.seedInitialSignature(const []);
      service.seedInitialSignature([ConnectivityResult.none]);
      expect(service.networkSignature.value, isNull);
      service.seedInitialSignature([ConnectivityResult.mobile]);
      expect(service.networkSignature.value, 'mobile');
    });

    test('晚到的初始结果不覆盖换网后的签名', () {
      service.networkSignature.value = 'mobile';
      service.seedInitialSignature([ConnectivityResult.wifi]);
      expect(service.networkSignature.value, 'mobile');
    });
  });
}
