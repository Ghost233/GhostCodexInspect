/// 文件对话框拦截守卫（工单 #20）。
///
/// 会话存活期间启用 `Page.setInterceptFileChooserDialog`，把原生文件
/// 选择框拦下；首次触发时：
/// 1. 以空文件列表释放本次选择（`DOM.setFileInputFiles`）；
/// 2. 向远程端广播 `ctrl/fileChooserHint` 提示「文件操作请回本机」；
/// 3. **解除拦截**——本机直操与后续点击回归原生行为，不被持久影响。
///
/// grilling 2026-10-18 决策：不做远程文件上传管道，文件操作回本机。
library;

import 'dart:async';

import '../cdp/cdp_client.dart';
import '../relay/relay.dart';

/// 远程端展示的提示文案。
const kFileChooserHintMessage = '文件选择需要回本机操作（远程文件上传未开放）';

/// 文件对话框拦截守卫：DOM 重绘与画面流会话共用（两会话互斥，见 #14）。
class FileChooserGuard {
  FileChooserGuard({required this.page, required this.relay});

  final CdpPage page;
  final RelayServer relay;

  StreamSubscription<Map<String, dynamic>>? _subscription;

  /// 拦截是否仍然挂起（首次触发后解除）。
  bool _armed = false;

  bool get isArmed => _armed;

  /// 已释放的选择次数（诊断/测试观测用）。
  int _releasedCount = 0;
  int get releasedCount => _releasedCount;

  /// 启用拦截并开始监听。
  Future<void> start() async {
    await page.send('Page.setInterceptFileChooserDialog', {'enabled': true});
    _armed = true;
    _subscription = page.fileChooserOpened.listen(
      _onFileChooserOpened,
      onError: (_) {},
    );
  }

  /// 停止监听并解除拦截（幂等）。
  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    if (_armed) {
      _armed = false;
      try {
        await page.send('Page.setInterceptFileChooserDialog', {
          'enabled': false,
        });
      } catch (_) {
        // 页面已关闭时静默：CDP 会话结束拦截随之失效。
      }
    }
  }

  void _onFileChooserOpened(Map<String, dynamic> params) {
    if (!_armed) return;
    // 先解除再释放：本机直操只被拦一次，后续点击走原生框（工单验收项）。
    _armed = false;
    _releasedCount++;
    final backendNodeId = params['backendNodeId'];
    if (backendNodeId is int) {
      unawaited(
        page
            .send('DOM.setFileInputFiles', {
              'files': <String>[],
              'backendNodeId': backendNodeId,
            })
            .catchError((_) => <String, dynamic>{}),
      );
    }
    unawaited(
      page
          .send('Page.setInterceptFileChooserDialog', {'enabled': false})
          .catchError((_) => <String, dynamic>{}),
    );
    relay.broadcast(RelayChannel.ctrl, RelayMessageType.fileChooserHint, {
      'message': kFileChooserHintMessage,
    });
  }
}
