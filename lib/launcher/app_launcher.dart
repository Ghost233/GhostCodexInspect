/// 目标应用带参启动 / 停止 / 重启。
///
/// 通用逻辑：接受 [TargetProfile]（含目标路径）。启动前先完全退出运行中的
/// 实例（`open -a` 对已运行实例会丢弃参数，见工单 #10），再以
/// `--remote-debugging-port=<调试端口>` 拉起，并轮询 CDP HTTP 端点确认就绪。
///
/// 安全约束：真实目标应用（[TargetProfile.requiresExplicitConsent] 为 true，
/// 如 ChatGPT.app）的启动与停止必须显式传 `confirmRealTarget: true`；
/// 开发期与测试只允许操作 fixture。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'target_profile.dart';

/// 启动结果。
class LaunchResult {
  const LaunchResult({
    required this.profile,
    required this.pid,
    required this.debugPort,
    required this.args,
  });

  final TargetProfile profile;

  /// 新拉起进程的 pid（openCommand 模式下为 -1，进程归属 LaunchServices）。
  final int pid;

  /// 生效的调试端口。
  final int debugPort;

  /// 实际传给目标应用的完整参数。
  final List<String> args;
}

/// 带参启动器。
class AppLauncher {
  AppLauncher({HttpClient Function()? httpClientFactory})
    : _httpClientFactory = httpClientFactory ?? HttpClient.new;

  final HttpClient Function() _httpClientFactory;

  /// 目标应用可执行文件路径（供进程发现匹配）。
  Future<String> executablePathOf(TargetProfile profile) async {
    if (profile.executablePathOverride != null) {
      return profile.executablePathOverride!;
    }
    // 从 Info.plist 读 CFBundleExecutable。
    final result = await Process.run('plutil', [
      '-extract',
      'CFBundleExecutable',
      'raw',
      '-o',
      '-',
      '${profile.appPath}/Contents/Info.plist',
    ]);
    if (result.exitCode != 0) {
      throw StateError('无法读取 ${profile.appPath} 的 CFBundleExecutable');
    }
    return '${profile.appPath}/Contents/MacOS/${'${result.stdout}'.trim()}';
  }

  /// 查找正在运行的目标应用实例的 pid 列表。
  ///
  /// 以可执行文件绝对路径作为 pgrep 模式，避免误伤同名进程。
  Future<List<int>> findRunningPids(TargetProfile profile) async {
    final executable = await executablePathOf(profile);
    final result = await Process.run('pgrep', ['-f', executable]);
    if (result.exitCode != 0) return const [];
    return parsePgrepOutput('${result.stdout}');
  }

  /// 完全退出运行中的实例：先 SIGTERM，超时后 SIGKILL。
  Future<void> stop(
    TargetProfile profile, {
    bool confirmRealTarget = false,
    Duration gracePeriod = const Duration(seconds: 5),
  }) async {
    _guard(profile, confirmRealTarget, operation: '停止');
    final pids = await findRunningPids(profile);
    if (pids.isEmpty) return;
    for (final pid in pids) {
      Process.killPid(pid, ProcessSignal.sigterm);
    }
    final deadline = DateTime.now().add(gracePeriod);
    while (DateTime.now().isBefore(deadline)) {
      if ((await findRunningPids(profile)).isEmpty) return;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    for (final pid in await findRunningPids(profile)) {
      Process.killPid(pid, ProcessSignal.sigkill);
    }
  }

  /// 带参启动：先完全退出运行实例，再带调试端口拉起，
  /// 最后轮询 `http://127.0.0.1:<调试端口>/json/version` 确认 CDP 就绪。
  Future<LaunchResult> launch(
    TargetProfile profile, {
    int? debugPort,
    List<String> extraArgs = const [],
    bool confirmRealTarget = false,
    Duration readyTimeout = const Duration(seconds: 15),
  }) async {
    _guard(profile, confirmRealTarget, operation: '启动');
    final port = debugPort ?? profile.defaultDebugPort;
    final args = [
      ...profile.positionalArgs,
      '--remote-debugging-port=$port',
      ...extraArgs,
    ];

    // open -a 对已运行实例会丢弃参数，必须先完全退出。
    await stop(profile, confirmRealTarget: confirmRealTarget);

    int pid;
    switch (profile.launchMode) {
      case LaunchMode.openCommand:
        final process = await Process.start('open', [
          '-n',
          profile.appPath,
          '--args',
          ...args,
        ]);
        pid = -1;
        final exitCode = await process.exitCode;
        if (exitCode != 0) {
          throw StateError('open 启动 ${profile.appPath} 失败（exit $exitCode）');
        }
      case LaunchMode.directExec:
        final executable = await executablePathOf(profile);
        final process = await Process.start(
          executable,
          args,
          mode: ProcessStartMode.detachedWithStdio,
          // 某些开发机 shell 会导出 ELECTRON_RUN_AS_NODE=1（如为别的
          // Electron 项目所设），会让 Electron 二进制退化为 Node 运行。
          // 置空以确保目标应用以 Electron 模式启动。
          environment: const {'ELECTRON_RUN_AS_NODE': ''},
        );
        pid = process.pid;
        // 分离模式下不接 stdout/stderr，须显式丢弃避免管道阻塞。
        unawaited(process.stdout.drain<void>());
        unawaited(process.stderr.drain<void>());
    }

    await waitForDebugPort(port, timeout: readyTimeout);
    return LaunchResult(profile: profile, pid: pid, debugPort: port, args: args);
  }

  /// 重启 = 停止后带参启动。
  Future<LaunchResult> restart(
    TargetProfile profile, {
    int? debugPort,
    List<String> extraArgs = const [],
    bool confirmRealTarget = false,
  }) {
    return launch(
      profile,
      debugPort: debugPort,
      extraArgs: extraArgs,
      confirmRealTarget: confirmRealTarget,
    );
  }

  /// 轮询 CDP HTTP 端点直到就绪或超时。
  Future<void> waitForDebugPort(
    int port, {
    Duration timeout = const Duration(seconds: 15),
    Duration interval = const Duration(milliseconds: 250),
  }) async {
    final deadline = DateTime.now().add(timeout);
    final client = _httpClientFactory();
    try {
      while (DateTime.now().isBefore(deadline)) {
        try {
          final request = await client
              .get('127.0.0.1', port, '/json/version')
              .timeout(interval);
          final response = await request.close().timeout(interval);
          if (response.statusCode == 200) {
            await response.drain<void>();
            return;
          }
          await response.drain<void>();
        } on Object {
          // 端口未就绪，继续轮询。
        }
        await Future<void>.delayed(interval);
      }
    } finally {
      client.close();
    }
    throw TimeoutException('调试端口 127.0.0.1:$port 在 $timeout 内未就绪');
  }

  void _guard(
    TargetProfile profile,
    bool confirmRealTarget, {
    required String operation,
  }) {
    if (profile.requiresExplicitConsent && !confirmRealTarget) {
      throw StateError(
        '拒绝$operation真实目标应用 ${profile.appPath}：'
        '该操作需要显式确认（confirmRealTarget: true）。'
        '开发期与测试只允许操作 fixture。',
      );
    }
  }
}

/// 解析 `pgrep` 输出为 pid 列表（每行一个 pid）。
List<int> parsePgrepOutput(String output) {
  return const LineSplitter()
      .convert(output)
      .map((line) => int.tryParse(line.trim()))
      .nonNulls
      .toList();
}
