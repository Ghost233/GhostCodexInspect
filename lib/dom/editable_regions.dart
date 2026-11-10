import 'dart:async';
import 'dart:convert';

import '../cdp/cdp_client.dart';
import '../relay/relay.dart';

/// 只发送可编辑区域的位置，不读取输入内容，供像素画面的触摸命中判断。
class EditableRegions {
  EditableRegions(this.page, this.relay);
  final CdpPage page;
  final RelayServer relay;
  Timer? _timer;
  bool _polling = false;
  bool _active = false;
  String? _last;
  List<dynamic> _regions = [];
  void Function(int)? _previousAuthed;

  Future<void> start() async {
    _active = true;
    _previousAuthed = relay.onClientAuthed;
    relay.onClientAuthed = _authed;
    await _poll();
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) => _poll());
  }

  void _authed(int id) {
    _previousAuthed?.call(id);
    relay.sendTo(
      id,
      RelayChannel.ctrl,
      RelayMessageType.inputTargets,
      _regions,
    );
  }

  Future<void> _poll() async {
    if (!_active || _polling) return;
    _polling = true;
    try {
      final raw = await page.evaluate('''(() => JSON.stringify(
        [...document.querySelectorAll('input,textarea,[contenteditable]')]
          .filter(el => !el.disabled && !el.readOnly &&
            (el.isContentEditable || el.tagName === 'TEXTAREA' ||
             (el.tagName === 'INPUT' && !['hidden','button','submit','reset','checkbox','radio','range','color','file','image'].includes(el.type))) &&
            getComputedStyle(el).visibility !== 'hidden')
          .map(el => { const r = el.getBoundingClientRect(); return {x:r.x,y:r.y,width:r.width,height:r.height}; })
          .filter(r => r.width > 0 && r.height > 0 && r.x < innerWidth && r.y < innerHeight && r.x+r.width > 0 && r.y+r.height > 0)
      ))()''');
      if (raw is! String || !_active || raw == _last) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      _last = raw;
      _regions = decoded;
      relay.broadcast(
        RelayChannel.ctrl,
        RelayMessageType.inputTargets,
        decoded,
      );
    } catch (_) {
      // 导航期间暂时不可读，保留最近的位置并在下次轮询更新。
    } finally {
      _polling = false;
    }
  }

  void stop() {
    _active = false;
    _timer?.cancel();
    if (relay.onClientAuthed == _authed) relay.onClientAuthed = _previousAuthed;
  }
}
