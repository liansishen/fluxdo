import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/models/ldc_user_info.dart';

Map<String, dynamic> _response({Object id = '123456', int? dailyLimit}) => {
  'id': id,
  'username': 'example',
  'nickname': '测试用户',
  'trust_level': 2,
  'avatar_url': '',
  'total_receive': '100.25',
  'total_payment': '10',
  'total_transfer': '5',
  'total_community': '30',
  'community_balance': '20',
  'available_balance': '85.25',
  'pay_score': 10,
  'is_pay_key': false,
  'is_admin': false,
  'remain_quota': dailyLimit == null ? '-1' : '90',
  'pay_level': 1,
  'daily_limit': dailyLimit,
};

void main() {
  test('字符串 ID 和无限额响应可读取余额，缓存往返保留无限额语义', () {
    final user = LdcUserInfo.fromJson(_response());
    expect(user.id, 123456);
    expect(user.availableBalance, '85.25');
    expect(user.dailyLimit, isNull);
    expect(user.remainQuota, '-1');

    final cached = LdcUserInfo.fromJson(
      jsonDecode(jsonEncode(user.toJson())) as Map<String, dynamic>,
    );
    expect(cached.id, 123456);
    expect(cached.availableBalance, '85.25');
    expect(cached.dailyLimit, isNull);
    expect(cached.remainQuota, '-1');
  });

  test('旧版整数 ID 缓存和有限额度仍可读取', () {
    final user = LdcUserInfo.fromJson(_response(id: 123456, dailyLimit: 100));
    expect(user.id, 123456);
    expect(user.dailyLimit, 100);
    expect(user.remainQuota, '90');
  });
}
