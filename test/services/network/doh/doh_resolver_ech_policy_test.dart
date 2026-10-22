import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/services/network/doh/doh_resolver.dart';
import 'package:fluxdo/services/network/doh/ech_dns_policy.dart';

void main() {
  test('原生解析保留真实域名，策略切换后清除 Dart 地址缓存', () async {
    final hosts = <String>[];
    final resolver = DohResolver(
      serverUrl: 'https://dns.example/dns-query',
      enableFallback: false,
      nativeLookup: (host, server, preferIPv6) async {
        hosts.add(host);
        return [hosts.length == 1 ? '104.21.0.10' : '104.21.0.11'];
      },
    );
    addTearDown(resolver.dispose);

    expect((await resolver.resolveAll('linux.do')).single.address, '104.21.0.10');
    expect((await resolver.resolveAll('linux.do')).single.address, '104.21.0.10');
    expect(hosts, ['linux.do']);

    resolver.echDnsPolicy = const EchDnsPolicy(enabled: false);
    expect((await resolver.resolveAll('linux.do')).single.address, '104.21.0.11');
    expect(hosts, ['linux.do', 'linux.do']);
  });

  test('切换策略时丢弃旧请求结果，旧请求完成不移除新请求的去重状态', () async {
    final oldAnswer = Completer<List<String>>();
    final newAnswer = Completer<List<String>>();
    var calls = 0;
    final resolver = DohResolver(
      serverUrl: 'https://dns.example/dns-query',
      enableFallback: false,
      nativeLookup: (host, server, preferIPv6) {
        calls++;
        return calls == 1 ? oldAnswer.future : newAnswer.future;
      },
    );
    addTearDown(resolver.dispose);

    final oldRequest = resolver.resolveAll('linux.do');
    resolver.echDnsPolicy = const EchDnsPolicy(enabled: false);
    final newRequest = resolver.resolveAll('linux.do');
    oldAnswer.complete(['104.21.0.10']);
    await Future<void>.delayed(Duration.zero);
    final joinedRequest = resolver.resolveAll('linux.do');
    expect(calls, 2);

    newAnswer.complete(['104.21.0.11']);
    for (final request in [oldRequest, newRequest, joinedRequest]) {
      expect((await request).single.address, '104.21.0.11');
    }
    expect((await resolver.resolveAll('linux.do')).single.address, '104.21.0.11');
    expect(calls, 2);
  });
}
