// Lorewatch stand-ins for the two Plezy app settings the copied player reads
// (Plezy's `SettingsService.subtitleRenderResolution` and
// `DevicePerformance.isLowEndHardware`). Set these before creating a Player.

/// Resolution the Android subtitle plane renders at, relative to the screen.
enum SubtitleRenderResolution { screen, video, threeQuarter, half, third, quarter }

extension SubtitleRenderResolutionScale on SubtitleRenderResolution {
  /// Only Android reads this; the Apple-only [SubtitleRenderResolution.video]
  /// basis maps to full scale here.
  double get androidRenderScale => switch (this) {
    SubtitleRenderResolution.screen => 1.0,
    SubtitleRenderResolution.video => 1.0,
    SubtitleRenderResolution.threeQuarter => 0.75,
    SubtitleRenderResolution.half => 0.5,
    SubtitleRenderResolution.third => 1 / 3,
    SubtitleRenderResolution.quarter => 0.25,
  };
}

abstract final class PlayerSettings {
  /// Android subtitle plane resolution. Lower values help weak TV boxes.
  static SubtitleRenderResolution subtitleRenderResolution = SubtitleRenderResolution.screen;

  /// Low-end device: the ExoPlayer path adds a frame of subtitle latency.
  static bool lowEndHardware = false;
}
