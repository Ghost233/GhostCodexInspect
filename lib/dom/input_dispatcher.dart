/// 输入反向（工单 #11）：远程端 input 通道信封 → CDP Input 域可信事件。
///
/// 坐标约定（docs/research/dom-replay.md §4.2）：远程端已完成缩放换算，
/// 到达宿主的 x/y 即源视口 CSS px（CDP 坐标即 CSS px，无 DPR 换算）。
///
/// 输入 payload schema（信封 `ch:input, t:input` 的 data）：
/// - `{kind:'mouse', action:'move'|'down'|'up', x, y, button?, clickCount?}`
/// - `{kind:'wheel', x, y, deltaX, deltaY}`
/// - `{kind:'text', text}` → `Input.insertText`
/// - `{kind:'key', key}` → `Input.dispatchKeyEvent`（rawKeyDown+keyUp），
///   覆盖 Backspace/Enter/Tab/Escape/方向键等不可打印键。
library;

import '../cdp/cdp_client.dart';

/// 输入 payload 非法时抛出。
class InputPayloadException implements Exception {
  InputPayloadException(this.message);
  final String message;
  @override
  String toString() => 'InputPayloadException: $message';
}

/// 不可打印键 → CDP dispatchKeyEvent 参数（windowsVirtualKeyCode/key/code，
/// Enter 附带 text '\r' 以触发表单提交等默认行为）。
const Map<String, Map<String, Object?>> kKeyEventParams = {
  'Backspace': {
    'windowsVirtualKeyCode': 8,
    'key': 'Backspace',
    'code': 'Backspace',
  },
  'Enter': {
    'windowsVirtualKeyCode': 13,
    'key': 'Enter',
    'code': 'Enter',
    'text': '\r',
  },
  'Tab': {'windowsVirtualKeyCode': 9, 'key': 'Tab', 'code': 'Tab'},
  'Escape': {'windowsVirtualKeyCode': 27, 'key': 'Escape', 'code': 'Escape'},
  'ArrowLeft': {
    'windowsVirtualKeyCode': 37,
    'key': 'ArrowLeft',
    'code': 'ArrowLeft',
  },
  'ArrowUp': {'windowsVirtualKeyCode': 38, 'key': 'ArrowUp', 'code': 'ArrowUp'},
  'ArrowRight': {
    'windowsVirtualKeyCode': 39,
    'key': 'ArrowRight',
    'code': 'ArrowRight',
  },
  'ArrowDown': {
    'windowsVirtualKeyCode': 40,
    'key': 'ArrowDown',
    'code': 'ArrowDown',
  },
  'Delete': {'windowsVirtualKeyCode': 46, 'key': 'Delete', 'code': 'Delete'},
  'Home': {'windowsVirtualKeyCode': 36, 'key': 'Home', 'code': 'Home'},
  'End': {'windowsVirtualKeyCode': 35, 'key': 'End', 'code': 'End'},
};

/// 校验并归一化 input payload；非法时抛 [InputPayloadException]。
/// 返回值可直接作为 [dispatchInput] 的输入。
Map<String, dynamic> validateInputPayload(Object? data) {
  if (data is! Map) {
    throw InputPayloadException('input payload 必须是对象：$data');
  }
  final payload = Map<String, dynamic>.from(data);
  final kind = payload['kind'];
  switch (kind) {
    case 'mouse':
      final action = payload['action'];
      if (action != 'move' && action != 'down' && action != 'up') {
        throw InputPayloadException('mouse action 非法：$action');
      }
      _requireNum(payload, 'x');
      _requireNum(payload, 'y');
      final buttons = payload['buttons'];
      if (buttons != null && (buttons is! int || buttons < 0 || buttons > 31)) {
        throw InputPayloadException('mouse buttons 必须是 0-31 的按键状态');
      }
    case 'wheel':
      _requireNum(payload, 'x');
      _requireNum(payload, 'y');
      _requireNum(payload, 'deltaX');
      _requireNum(payload, 'deltaY');
    case 'text':
      if (payload['text'] is! String) {
        throw InputPayloadException('text payload 缺 text 字符串');
      }
    case 'key':
      final key = payload['key'];
      if (key is! String || !kKeyEventParams.containsKey(key)) {
        throw InputPayloadException('不支持的 key：$key');
      }
    default:
      throw InputPayloadException('未知 input kind：$kind');
  }
  return payload;
}

/// 记录各远程端持有的按键，断线或停止会话时释放。
class RemoteMouseButtons {
  final _held = <int, Map<String, dynamic>>{};

  void record(int clientId, Map<String, dynamic> payload) {
    if (payload['kind'] != 'mouse') return;
    if (payload['action'] == 'up' || payload['buttons'] == 0) {
      _held.remove(clientId);
    } else if (payload['action'] == 'down') {
      _held[clientId] = {
        'x': payload['x'],
        'y': payload['y'],
        'button': payload['button'] ?? 'left',
      };
    } else if (_held.containsKey(clientId)) {
      _held[clientId]!.addAll({'x': payload['x'], 'y': payload['y']});
    }
  }

  Future<void> release(CdpPage page, {int? clientId}) async {
    final ids = clientId == null ? _held.keys.toList() : [clientId];
    final pending = [
      for (final id in ids)
        if (_held.containsKey(id)) _held.remove(id)!,
    ];
    for (final point in pending) {
      await dispatchInput(page, {
        'kind': 'mouse',
        'action': 'up',
        ...point,
        'buttons': 0,
      });
    }
  }
}

/// 下发到目标页面，不移动系统鼠标。
Future<void> dispatchInput(CdpPage page, Map<String, dynamic> payload) async {
  switch (payload['kind']) {
    case 'mouse':
      final type = switch (payload['action']) {
        'move' => 'mouseMoved',
        'down' => 'mousePressed',
        _ => 'mouseReleased',
      };
      await page.send('Input.dispatchMouseEvent', {
        'type': type,
        'x': (payload['x'] as num).toDouble(),
        'y': (payload['y'] as num).toDouble(),
        if (payload['buttons'] != null) 'buttons': payload['buttons'],
        if (type == 'mouseMoved' && (payload['buttons'] as int? ?? 0) != 0)
          'button': payload['button'] ?? 'left',
        if (type != 'mouseMoved') ...{
          'button': payload['button'] ?? 'left',
          'clickCount': payload['clickCount'] ?? 1,
        },
      });
    case 'wheel':
      await page.send('Input.dispatchMouseEvent', {
        'type': 'mouseWheel',
        'x': (payload['x'] as num).toDouble(),
        'y': (payload['y'] as num).toDouble(),
        'deltaX': (payload['deltaX'] as num).toDouble(),
        'deltaY': (payload['deltaY'] as num).toDouble(),
      });
    case 'text':
      // insertText 是 trusted 输入路径，el.value 赋值等合成方式会被拒收。
      await page.send('Input.insertText', {'text': payload['text']});
    case 'key':
      final params = kKeyEventParams[payload['key']]!;
      await page.send('Input.dispatchKeyEvent', {
        'type': 'rawKeyDown',
        ...params,
      });
      await page.send('Input.dispatchKeyEvent', {'type': 'keyUp', ...params});
  }
}

void _requireNum(Map<String, dynamic> payload, String field) {
  if (payload[field] is! num) {
    throw InputPayloadException('${payload['kind']} payload 缺数值字段 $field');
  }
}
