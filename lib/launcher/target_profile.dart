/// 目标应用描述：对多目标通用的可配置数据结构。
///
/// ChatGPT.app 是一期内置适配（重命名的 `Codex Framework.framework`），
/// 同时保留标准 `Electron Framework.framework` 作为通用回退判据。
/// 术语见根目录 GLOSSARY.md（目标应用、调试端口、前提校验）。
library;

/// 启动方式：`.app` 经 `open` 拉起，或直接执行 bundle 内可执行文件。
///
/// 直接执行用于开发期 fixture（Electron 需要把应用目录作为位置参数传入，
/// `open --args` 对已运行实例丢参数，且 fixture 需要稳定的 argv 顺序）。
enum LaunchMode {
  /// `open -n <app> --args <args...>`：面向已安装的目标应用。
  openCommand,

  /// `Process.start(<可执行文件>, <args...>)`：面向开发期 fixture。
  directExec,
}

/// 一个目标应用的完整静态描述。
class TargetProfile {
  const TargetProfile({
    required this.id,
    required this.displayName,
    required this.bundleId,
    required this.appPath,
    required this.frameworkNames,
    required this.shellUrlSchemes,
    this.expectedPrincipalClass,
    this.expectedAsarName,
    this.userDataDir,
    this.defaultDebugPort = 9238,
    this.launchMode = LaunchMode.openCommand,
    this.executablePathOverride,
    this.positionalArgs = const [],
    this.requiresExplicitConsent = false,
  });

  /// 目标应用标识（如 `chatgpt-codex`、`electron-fixture`）。
  final String id;

  /// 展示名（如 `ChatGPT（Codex）`）。
  final String displayName;

  /// CFBundleIdentifier（期望值，实测不符会在前提校验中告警）。
  final String bundleId;

  /// `.app` bundle 绝对路径。
  final String appPath;

  /// Electron 框架候选名（按优先级），适配目标应用对框架的重命名。
  /// 任一名称的 `Contents/Frameworks/<name>.framework` 存在即视为 Electron。
  final List<String> frameworkNames;

  /// shell 页面 URL 的自定义 scheme 列表（CDP target 过滤用）。
  /// ChatGPT.app 为 `app` 与 `codex-sandbox`；fixture 为 `file`。
  final List<String> shellUrlSchemes;

  /// 期望的 NSPrincipalClass（辅助判据）。为 null 时只记录实测值不校验。
  final String? expectedPrincipalClass;

  /// 期望的 asar 载荷文件名（如 `app.asar`）。为 null 时接受任意 `*.asar`。
  final String? expectedAsarName;

  /// 进程用户数据目录（信息性记录，未展开 `~`）。
  final String? userDataDir;

  /// 默认调试端口。每个目标应用独占一个端口。
  final int defaultDebugPort;

  /// 启动方式。
  final LaunchMode launchMode;

  /// 可执行文件路径覆盖；默认从 Info.plist 的 CFBundleExecutable 推导
  /// `Contents/MacOS/<CFBundleExecutable>`。
  final String? executablePathOverride;

  /// 位置参数（在开关参数之前传给可执行文件）。
  /// fixture 用它把应用目录传给 Electron 二进制。
  final List<String> positionalArgs;

  /// 是否为真实目标应用：启动/停止前必须显式确认
  /// （AppLauncher 要求 `confirmRealTarget: true`），防止误触真机。
  final bool requiresExplicitConsent;

  /// 一期内置适配：ChatGPT.app（Codex 桌面端，bundle id `com.openai.codex`）。
  ///
  /// 依据 issue #2 实测：框架被重命名为 `Codex Framework.framework`，
  /// NSPrincipalClass 为 `BrowserCrApplication`，asar 载荷为 `app.asar`，
  /// shell 页面 scheme 为 `app://`（另有 `codex-sandbox`）。
  static const chatGpt = TargetProfile(
    id: 'chatgpt-codex',
    displayName: 'ChatGPT（Codex）',
    bundleId: 'com.openai.codex',
    appPath: '/Applications/ChatGPT.app',
    frameworkNames: ['Codex Framework', 'Electron Framework'],
    expectedPrincipalClass: 'BrowserCrApplication',
    expectedAsarName: 'app.asar',
    userDataDir: '~/Library/Application Support/Codex',
    shellUrlSchemes: ['app', 'codex-sandbox'],
    requiresExplicitConsent: true,
  );

  /// 开发期 fixture 目标：以 `node_modules/electron/dist/Electron.app` 为
  /// 目标 bundle（标准 Electron，走通用判据），应用目录作为位置参数。
  factory TargetProfile.electronFixture({
    required String electronAppPath,
    required String fixtureDir,
  }) {
    return TargetProfile(
      id: 'electron-fixture',
      displayName: 'Electron 替身 fixture',
      bundleId: 'com.github.Electron',
      appPath: electronAppPath,
      frameworkNames: const ['Electron Framework'],
      // 原生 Electron 的 NSPrincipalClass 是 AtomApplication，只记录不校验。
      shellUrlSchemes: const ['file'],
      launchMode: LaunchMode.directExec,
      positionalArgs: [fixtureDir],
    );
  }
}
