class WakelockWrapper {
  static Future<void> enable() async {}
  static Future<void> disable() async {}
}

void enableWakelock() => WakelockWrapper.enable();
void disableWakelock() => WakelockWrapper.disable();
