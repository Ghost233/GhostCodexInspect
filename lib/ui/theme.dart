/// 宿主应用主题（工单 #13）。
///
/// 按 macos-ui-standards 设计基线实现：
/// - 文本一律走角色（textTheme），不在页面里散落自定字号；角色到 Apple
///   文本样式的映射见 docs/design.md；
/// - 颜色用语义 ColorScheme（浅色/深色双套），状态色配文字/图标不单靠颜色；
/// - 控件圆角 8、容器圆角 12、分隔线 1。
library;

import 'package:flutter/material.dart';

/// 语义状态色调（运行/就绪、警示、失败、未知）。
enum StatusTone { neutral, success, warning, error }

/// 构建宿主主题。配色约定与 GhostModelDeck 保持一致（同一作者的工具家族），
/// 文本角色按 Apple macOS 尺度映射。
ThemeData buildAppTheme(Brightness brightness, {String? fontFamily}) {
  final dark = brightness == Brightness.dark;
  final scheme = dark
      ? const ColorScheme.dark(
          primary: Color(0xFF79AFFF),
          secondary: Color(0xFF79AFFF),
          onPrimary: Color(0xFF0C1626),
          surface: Color(0xFF202123),
          onSurface: Color(0xFFF0F0F1),
          onSurfaceVariant: Color(0xFF96989D),
          outline: Color(0xFF45474B),
          outlineVariant: Color(0xFF303236),
          surfaceContainer: Color(0xFF18191B),
          surfaceContainerLow: Color(0xFF26272A),
          surfaceContainerHigh: Color(0xFF2C2D30),
          error: Color(0xFFFF8A8A),
        )
      : const ColorScheme.light(
          primary: Color(0xFF286AE6),
          secondary: Color(0xFF286AE6),
          onPrimary: Colors.white,
          surface: Colors.white,
          onSurface: Color(0xFF222327),
          onSurfaceVariant: Color(0xFF747983),
          outline: Color(0xFFD1D3D8),
          outlineVariant: Color(0xFFE5E6E9),
          surfaceContainer: Color(0xFFFAFAFB),
          surfaceContainerLow: Color(0xFFF3F4F6),
          surfaceContainerHigh: Color(0xFFEDEEF0),
          error: Color(0xFFD64747),
        );
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    brightness: brightness,
    fontFamily: fontFamily,
  );
  final text = base.textTheme.copyWith(
    // 内容页主标题：Apple Title 1（22/26）
    headlineSmall: base.textTheme.headlineSmall!.copyWith(
      fontSize: 22,
      height: 26 / 22,
      fontWeight: FontWeight.w600,
      color: scheme.onSurface,
    ),
    // 窗口/工具栏标题：Apple Title 2（17/22）
    titleLarge: base.textTheme.titleLarge!.copyWith(
      fontSize: 17,
      height: 22 / 17,
      fontWeight: FontWeight.w600,
      color: scheme.onSurface,
    ),
    // 区域/卡片标题：Apple Title 3（15/20，Semibold）
    titleMedium: base.textTheme.titleMedium!.copyWith(
      fontSize: 15,
      height: 20 / 15,
      fontWeight: FontWeight.w600,
      color: scheme.onSurface,
    ),
    // 强调正文：Apple Headline（13/16，Bold）
    titleSmall: base.textTheme.titleSmall!.copyWith(
      fontSize: 13,
      height: 16 / 13,
      fontWeight: FontWeight.w700,
      color: scheme.onSurface,
    ),
    // 正文与名称：Apple Body（13/16）
    bodyMedium: base.textTheme.bodyMedium!.copyWith(
      fontSize: 13,
      height: 16 / 13,
      color: scheme.onSurface,
    ),
    // 辅助信息：Apple Callout（12/15）
    bodySmall: base.textTheme.bodySmall!.copyWith(
      fontSize: 12,
      height: 15 / 12,
      color: scheme.onSurfaceVariant,
    ),
    labelLarge: base.textTheme.labelLarge!.copyWith(
      fontSize: 13,
      height: 16 / 13,
      fontWeight: FontWeight.w600,
    ),
    labelMedium: base.textTheme.labelMedium!.copyWith(
      fontSize: 12,
      height: 15 / 12,
      fontWeight: FontWeight.w500,
      color: scheme.onSurfaceVariant,
    ),
    // 状态标记：Apple Caption 1（10/13，Medium）
    labelSmall: base.textTheme.labelSmall!.copyWith(
      fontSize: 10,
      height: 13 / 10,
      fontWeight: FontWeight.w600,
      color: scheme.onSurfaceVariant,
    ),
  );
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(8));
  return base.copyWith(
    textTheme: text,
    scaffoldBackgroundColor: scheme.surfaceContainer,
    visualDensity: VisualDensity.compact,
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant,
      thickness: 1,
      space: 1,
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: scheme.surface,
      hintStyle: text.bodyMedium!.copyWith(color: scheme.onSurfaceVariant),
      labelStyle: text.bodySmall,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: scheme.outline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: scheme.outline),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 32),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        textStyle: text.labelLarge,
        shape: shape,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(64, 32),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        textStyle: text.labelLarge,
        shape: shape,
        side: BorderSide(color: scheme.outline),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(48, 32),
        textStyle: text.labelLarge,
        shape: shape,
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: scheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      titleTextStyle: text.titleMedium,
      contentTextStyle: text.bodyMedium,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: scheme.surfaceContainerHigh,
      contentTextStyle: text.bodyMedium,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      behavior: SnackBarBehavior.floating,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: scheme.outlineVariant),
      ),
      textStyle: text.bodySmall,
    ),
  );
}

/// 状态色调对应的颜色（深色/浅色分别保证对比度 ≥4.5:1 于容器底）。
Color statusToneColor(BuildContext context, StatusTone tone) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return switch (tone) {
    StatusTone.neutral => Theme.of(context).colorScheme.onSurfaceVariant,
    StatusTone.success =>
      dark ? const Color(0xFF77D6A5) : const Color(0xFF218854),
    StatusTone.warning =>
      dark ? const Color(0xFFE9BC72) : const Color(0xFFA16B19),
    StatusTone.error => Theme.of(context).colorScheme.error,
  };
}
