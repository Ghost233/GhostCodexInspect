# 中转信封协议：v1 文本 JSON 为基线，v2 二进制按能力协商，类型 id 只能追加

宿主↔远程端走单条 WebSocket，信封 `{v,ch,t,seq,ts,data}`，通道 dom/frame/input/ctrl。v2 二进制帧（15 字节头 + 原始 payload，通道/类型 id = 枚举序 + 1）只用于宿主→远程端大流量下行（dom 压缩 payload、frame JPEG），控制面永远文本。协商：auth 握手 `data.caps` 声明 `bin.v2`，服务端 authOk 回显后生效；未声明的旧客户端全程文本帧（向后兼容）。dom 大 payload 文本路径用 fflate 压缩标记（`z`/`b64` 字段），v2 路径恒定压缩。

## Consequences

- **RelayChannel / RelayMessageType 枚举只能末尾追加，禁止重排或插入**——二进制 id 派生自枚举序，重排即协议破坏。远程端 `TYPE_NAMES`/`CHANNEL_NAMES` 数组须同步。
- 实测带宽比 v2/v1 ≈ 0.744（≈ base64 理论 0.75）。
- seq 按通道单调递增，用于远程端乱序检测与 resync 触发。
