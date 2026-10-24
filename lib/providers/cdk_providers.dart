import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/cdk_user_info.dart';
import '../services/cdk_oauth_service.dart';
import '../services/network/exceptions/oauth_exception.dart';
import '../services/site_context.dart';
import 'core_providers.dart';

final cdkOAuthServiceProvider = Provider((ref) => CdkOAuthService());

final cdkUserInfoProvider =
    AsyncNotifierProvider<CdkUserInfoNotifier, CdkUserInfo?>(() {
      return CdkUserInfoNotifier();
    });

class CdkUserInfoNotifier extends AsyncNotifier<CdkUserInfo?> {
  static const String _cacheKey = 'cdk_user_info';
  static const String _enabledKey = 'cdk_enabled';
  static const String _cacheUserKey = 'cdk_user_info_username';

  // 首次加载与刷新共享同一账号的请求，不跨账号复用。
  Future<CdkUserInfo?>? _inFlightFetch;
  String? _inFlightUsername;
  int _requestGeneration = 0;

  String _accountCacheKey(String username) =>
      SiteContext.storageKey('${_cacheKey}_account_$username');

  bool _isCurrentRequest(int generation, String? username) =>
      ref.mounted &&
      generation == _requestGeneration &&
      ref.read(currentUserProvider).value?.username == username;

  @override
  Future<CdkUserInfo?> build() async {
    if (!SiteContext.isLinuxDo) return null;
    final generation = ++_requestGeneration;
    _inFlightFetch = null;
    _inFlightUsername = null;
    final service = ref.read(cdkOAuthServiceProvider);
    ref.onDispose(() {
      _requestGeneration++;
      _inFlightFetch = null;
      _inFlightUsername = null;
      service.cancelPendingRequests();
    });

    // 用户资料的其他字段刷新不应重新请求余额。
    final currentUsername = ref.watch(
      currentUserProvider.select((value) => value.value?.username),
    );
    final userFuture = currentUsername == null
        ? ref.watch(currentUserProvider.future)
        : null;
    final username = currentUsername ?? (await userFuture!)?.username;
    if (!_isCurrentRequest(generation, username)) return null;
    final prefs = await SharedPreferences.getInstance();
    if (!_isCurrentRequest(generation, username)) return null;
    if (username == null) {
      await _clearCache(prefs, null);
      return null;
    }
    if (!(prefs.getBool(_enabledKey) ?? false)) return null;

    // 新缓存按站点和账号隔离；旧缓存必须同时通过归属键与内容校验。
    CdkUserInfo? cachedInfo;
    final accountCache = prefs.getString(_accountCacheKey(username));
    final cached =
        accountCache ?? prefs.getString(SiteContext.storageKey(_cacheKey));
    if (cached != null) {
      try {
        final info = CdkUserInfo.fromJson(
          jsonDecode(cached) as Map<String, dynamic>,
        );
        final isLegacy = accountCache == null;
        final cachedUser = isLegacy
            ? prefs.getString(SiteContext.storageKey(_cacheUserKey))
            : null;
        if (info.username == username &&
            (cachedUser == null || cachedUser == username)) {
          cachedInfo = info;
        } else {
          await _clearCache(prefs, username);
        }
      } catch (_) {
        // 缓存损坏不影响重新请求。
      }
    }
    if (!_isCurrentRequest(generation, username)) return null;

    try {
      return await _fetchUserInfo(username);
    } on OAuthExpiredException catch (_) {
      if (!_isCurrentRequest(generation, username)) return null;
      // 只有业务会话确认过期才清除当前账号的缓存。
      await _clearCache(prefs, username);
      rethrow;
    } catch (e) {
      if (!_isCurrentRequest(generation, username) ||
          !(prefs.getBool(_enabledKey) ?? false)) {
        return null;
      }
      if (OAuthErrorPolicy.isCfChallenge(e)) rethrow;
      if (cachedInfo != null) return cachedInfo;
      rethrow;
    }
  }

  Future<CdkUserInfo?> _fetchUserInfo(String username) {
    if (_inFlightFetch != null && _inFlightUsername == username) {
      return _inFlightFetch!;
    }
    late final Future<CdkUserInfo?> future;
    future = _doFetchUserInfo(username).whenComplete(() {
      if (identical(_inFlightFetch, future)) {
        _inFlightFetch = null;
        _inFlightUsername = null;
      }
    });
    _inFlightUsername = username;
    return _inFlightFetch = future;
  }

  Future<CdkUserInfo?> _doFetchUserInfo(String username) async {
    if (!SiteContext.isLinuxDo) return null;
    final generation = _requestGeneration;
    final prefs = await SharedPreferences.getInstance();
    if (!_isCurrentRequest(generation, username) ||
        !(prefs.getBool(_enabledKey) ?? false)) {
      return null;
    }

    final service = ref.read(cdkOAuthServiceProvider);
    final userInfo = await service.getUserInfo(expectedUsername: username);
    // 不依赖 provider 下一次重建：换号后即使旧请求先返回也不能回写。
    if (!_isCurrentRequest(generation, username) ||
        !(prefs.getBool(_enabledKey) ?? false)) {
      return null;
    }
    if (userInfo == null) return null;
    if (userInfo.username != username) {
      throw const OAuthExpiredException(serviceName: 'CDK');
    }
    await _clearLegacyCache(prefs);
    if (!_isCurrentRequest(generation, username) ||
        !(prefs.getBool(_enabledKey) ?? false)) {
      return null;
    }
    await prefs.setString(
      _accountCacheKey(username),
      jsonEncode(userInfo.toJson()),
    );
    return _isCurrentRequest(generation, username) ? userInfo : null;
  }

  Future<void> refresh() async {
    if (!SiteContext.isLinuxDo) return;
    final generation = _requestGeneration;
    var username = ref.read(currentUserProvider).value?.username;
    final previousData = state.value?.username == username ? state.value : null;
    if (previousData == null) {
      state = const AsyncLoading<CdkUserInfo?>();
    } else {
      // ignore: invalid_use_of_internal_member
      state = const AsyncLoading<CdkUserInfo?>().copyWithPrevious(state);
    }
    try {
      username ??= (await ref.read(currentUserProvider.future))?.username;
      if (!_isCurrentRequest(generation, username)) return;
      if (username == null) {
        state = const AsyncValue.data(null);
        return;
      }
      final result = await _fetchUserInfo(username);
      if (!_isCurrentRequest(generation, username)) return;
      state = AsyncValue.data(result);
    } catch (e, st) {
      if (!_isCurrentRequest(generation, username)) return;
      if (e is OAuthExpiredException) {
        final prefs = await SharedPreferences.getInstance();
        if (!_isCurrentRequest(generation, username)) return;
        await _clearCache(prefs, username);
        if (!_isCurrentRequest(generation, username)) return;
        state = AsyncValue.error(e, st);
      } else if (OAuthErrorPolicy.isCfChallenge(e)) {
        // 挑战状态保留旧余额，但不能伪装成本次请求成功。
        // ignore: invalid_use_of_internal_member
        state = AsyncValue<CdkUserInfo?>.error(e, st).copyWithPrevious(state);
      } else if (previousData != null) {
        state = AsyncValue.data(previousData);
      } else {
        state = AsyncValue.error(e, st);
      }
    }
  }

  /// 用户已手动通过 CF，取消旧请求并立即重新读取业务会话。
  Future<void> refreshAfterCfVerification() {
    if (!SiteContext.isLinuxDo) return Future.value();
    _requestGeneration++;
    _inFlightFetch = null;
    _inFlightUsername = null;
    ref.read(cdkOAuthServiceProvider).cancelPendingRequests();
    return refresh();
  }

  Future<void> clear() async {
    if (!SiteContext.isLinuxDo) return;
    final username =
        ref.read(currentUserProvider).value?.username ?? state.value?.username;
    final generation = ++_requestGeneration;
    _inFlightFetch = null;
    _inFlightUsername = null;
    ref.read(cdkOAuthServiceProvider).cancelPendingRequests();
    final prefs = await SharedPreferences.getInstance();
    await _clearCache(prefs, username);
    if (ref.mounted && generation == _requestGeneration) {
      state = const AsyncValue.data(null);
    }
  }

  Future<void> disable() async {
    if (!SiteContext.isLinuxDo) return;
    final username =
        ref.read(currentUserProvider).value?.username ?? state.value?.username;
    final generation = ++_requestGeneration;
    _inFlightFetch = null;
    _inFlightUsername = null;
    ref.read(cdkOAuthServiceProvider).cancelPendingRequests();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, false);
    await _clearCache(prefs, username);
    if (ref.mounted && generation == _requestGeneration) {
      state = const AsyncValue.data(null);
    }
  }

  Future<void> _clearCache(SharedPreferences prefs, String? username) async {
    if (username != null) await prefs.remove(_accountCacheKey(username));
    await _clearLegacyCache(prefs);
  }

  Future<void> _clearLegacyCache(SharedPreferences prefs) async {
    await prefs.remove(SiteContext.storageKey(_cacheKey));
    await prefs.remove(SiteContext.storageKey(_cacheUserKey));
  }
}
