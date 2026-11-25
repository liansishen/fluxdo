/// 简单的异步信号量,限制并发解码数避免内存峰值。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

class AsyncSemaphore {
  AsyncSemaphore(this.maxCount) : assert(maxCount > 0);

  final int maxCount;
  int _current = 0;
  final _queue = <Completer<void>>[];

  Future<void> acquire() {
    if (_current < maxCount) {
      _current++;
      return SynchronousFuture<void>(null);
    }
    final c = Completer<void>();
    _queue.add(c);
    return c.future;
  }

  void release() {
    if (_queue.isNotEmpty) {
      _queue.removeAt(0).complete();
    } else {
      _current--;
    }
  }
}
