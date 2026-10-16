# 领域文档

说明工程类 skills 探索代码库时应如何读取当前仓库的领域文档。

## 探索前读取

- 仓库根目录的 **`GLOSSARY.md`**；或
- 根目录的 **`GLOSSARY-MAP.md`**（如果存在）。它为每个上下文指向一个 `GLOSSARY.md`；读取与当前主题相关的每一份。
- **`docs/adr/`**：读取涉及即将处理区域的 ADR。多上下文仓库还要检查 `src/<context>/docs/adr/` 中限定于该上下文的决策。

其中任何文件不存在时，**静默继续**。不要报告缺失，也不要提前建议创建。`$domain-modeling` skill（由 `$grill-with-docs` 和 `$improve-codebase-architecture` 调用）会在术语或决策真正得到确定时按需创建。

## 文件结构

单上下文仓库（大多数仓库）：

```
/
├── GLOSSARY.md
├── docs/adr/
│   ├── 0001-event-sourced-orders.md
│   └── 0002-postgres-for-write-model.md
└── src/
```

多上下文仓库（根目录存在 `GLOSSARY-MAP.md`）：

```
/
├── GLOSSARY-MAP.md
├── docs/adr/                          ← 系统级决策
└── src/
    ├── ordering/
    │   ├── GLOSSARY.md
    │   └── docs/adr/                  ← 上下文特定决策
    └── billing/
        ├── GLOSSARY.md
        └── docs/adr/
```

## 使用术语表词汇

输出中命名领域概念时（issue 标题、重构提案、假设、测试名称等），使用 `GLOSSARY.md` 定义的术语。不要漂移到术语表明确要求避免的同义词。

所需概念尚未进入术语表时，把它视为信号：要么你正在发明项目不使用的语言（重新考虑），要么确有缺口（记录给 `$domain-modeling`）。

## 标记 ADR 冲突

输出与现有 ADR 矛盾时，明确指出，不要静默覆盖：

> _与 ADR-0007（事件溯源订单）矛盾，但值得重新讨论，因为……_
