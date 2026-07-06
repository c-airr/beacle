import 'package:flutter/material.dart';

/// Linear / Vercel-inspired dark palette with subtle glass layers.
class BeacleColors {
  static const bg = Color(0xFF050505);
  static const surface = Color(0xFF0C0C0C);
  static const surfaceHi = Color(0xFF141414);
  static const glass = Color(0xCC101010);
  static const glassHi = Color(0xE6181818);
  static const border = Color(0xFF222222);
  static const borderGlow = Color(0xFF333333);
  static const hover = Color(0x10FFFFFF);
  static const glow = Color(0xFFFFFFFF);
  static const text = Color(0xFFF4F4F5);
  static const textDim = Color(0xFF71717A);
  static const accent = Color(0xFFE4E4E7);
  static const ok = Color(0xFF4ADE80);
  static const warn = Color(0xFFFBBF24);
  static const err = Color(0xFFF87171);

  static Color statusColor(String status) {
    switch (status) {
      case 'online':
        return ok;
      case 'high_load':
        return warn;
      case 'offline':
        return err;
      default:
        return textDim;
    }
  }
}

ThemeData beacleTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: BeacleColors.bg,
    colorScheme: base.colorScheme.copyWith(
      surface: BeacleColors.surface,
      primary: BeacleColors.text,
      secondary: BeacleColors.textDim,
      error: BeacleColors.err,
    ),
    dividerColor: BeacleColors.border,
    cardColor: BeacleColors.surface,
    hoverColor: BeacleColors.hover,
    textTheme: base.textTheme.apply(
      bodyColor: BeacleColors.text,
      displayColor: BeacleColors.text,
      fontFamily: 'Segoe UI',
    ),
    dialogTheme: base.dialogTheme.copyWith(
      backgroundColor: BeacleColors.glassHi,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: BeacleColors.surfaceHi,
      labelStyle: const TextStyle(color: BeacleColors.textDim, fontSize: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: BeacleColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: BeacleColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: BeacleColors.borderGlow),
      ),
      isDense: true,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: BeacleColors.glassHi,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: BeacleColors.border),
      ),
      textStyle: const TextStyle(color: BeacleColors.text, fontSize: 11),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStateProperty.all(BeacleColors.border),
      radius: const Radius.circular(4),
    ),
  );
}
