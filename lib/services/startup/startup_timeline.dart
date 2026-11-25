import '../app_logger.dart';

/// 冷启动节点按 main 入口累计，内容就绪或预加载失败时只写一次日志。
class StartupTimeline {
  StartupTimeline._();

  static final Stopwatch _watch = Stopwatch();
  static final Map<String, int> _marks = {};
  static bool _reported = false;

  /// main() 第一行调用
  static void start() {
    if (!_watch.isRunning) _watch.start();
  }

  /// 同名节点仅记第一次，报告后停止接收新节点。
  static void mark(String name) {
    if (!_watch.isRunning || _reported) return;
    _marks.putIfAbsent(name, () => _watch.elapsedMilliseconds);
  }

  /// 启动日志写过之后才到的节点（靠启动快照先出了内容，这次运行的首页数据后到）：
  /// 单独记一条。日志还没写时等同 [mark]，跟着启动日志一起出
  static void late(String name) {
    if (!_watch.isRunning || _marks.containsKey(name)) return;
    if (!_reported) {
      mark(name);
      return;
    }
    final ms = _watch.elapsedMilliseconds;
    _marks[name] = ms;
    AppLogger.info(
      '启动后 $ms ms：$name',
      tag: 'Startup',
      fields: {
        'type': 'startup',
        'event': 'startup_late_mark',
        'name': name,
        'ms': ms,
      },
    );
  }

  /// 记最后一个节点并写日志
  static void finish(String name) {
    if (!_watch.isRunning || _reported) return;
    mark(name);
    _reported = true;
    AppLogger.info(
      '冷启动 ${_marks[name]} ms（$name）',
      tag: 'Startup',
      fields: {
        'type': 'startup',
        'event': 'startup_timeline',
        'marks': Map<String, int>.of(_marks),
      },
    );
  }
}
