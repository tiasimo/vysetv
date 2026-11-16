/// Stands in for the real Windows plugin so it never gets built in. Only phones use brightness, but
/// the real one talks to the monitor over DDC/CI anyway: it reads at every launch and whenever the
/// window gains focus or changes size, and writes whenever the window loses focus.
class ScreenBrightnessWindows {
  static void registerWith() {}
}
