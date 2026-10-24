import '../app_logger.dart';

/// 冷启动节点按 main 入口累计，内容就绪或预加载失败时只写一次日志。
class StartupTimeline {
  StartupTimeline._();

  static final Stopwatch _watch = Stopwatch();
  static final Map<String, int> _marks = {};
  static bool _reported = false;

  static void start() {
    if (!_watch.isRunning) _watch.start();
  }

  /// 同名节点仅记第一次，报告后停止接收新节点。
  static void mark(String name) {
    if (!_watch.isRunning || _reported) return;
    _marks.putIfAbsent(name, () => _watch.elapsedMilliseconds);
  }

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
