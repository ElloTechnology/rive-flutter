/// Web stub for [ThreadedRiveController].
///
/// Threaded rendering requires native Metal/Vulkan GPU access and is not
/// supported on web. This stub provides the same public API surface so that
/// the types are importable on web, but [initialize] always returns `false`.

import 'package:flutter/widgets.dart' show Alignment;
import 'package:rive_native/rive_native.dart';

import 'event_drainer.dart';

class SnapshotEntry {
  final String name;
  final int type;
  final String rawValue;
  const SnapshotEntry({
    required this.name,
    required this.type,
    required this.rawValue,
  });
}

class RiveThreadedEvent {
  final String name;
  final double secondsDelay;
  const RiveThreadedEvent(this.name, this.secondsDelay);
}

class ThreadedFrame {
  final List<SnapshotEntry> properties;
  final List<RiveThreadedEvent> events;
  const ThreadedFrame({required this.properties, required this.events});
}

class ThreadedRiveController {
  ThreadedRiveController({
    required Artboard artboard,
    required StateMachine stateMachine,
    ViewModelInstance? viewModelInstance,
  });

  static ThreadedRiveController? get debugActiveController => null;

  bool get isInitialized => false;
  bool get hasFatalError => false;
  int get advanceCount => 0;
  int get renderedCount => 0;

  RenderTexture get renderTexture =>
      throw UnsupportedError('Threaded rendering is not supported on web');

  Future<bool> initialize({
    required int width,
    required int height,
    required double devicePixelRatio,
    Fit fit = Fit.contain,
    Alignment alignment = Alignment.center,
  }) async =>
      false;

  void claimNativeOwnership() {}
  void dispose() {}
  void advance(double elapsedSeconds) {}
  void setEnumProperty(String name, String value) {}
  void setNumberProperty(String name, double value) {}
  void setBoolProperty(String name, bool value) {}
  void setStringProperty(String name, String value) {}
  void fireTriggerProperty(String name) {}
  void watchProperty(String name) {}
  void unwatchProperty(String name) {}
  List<SnapshotEntry> acquireSnapshot({int maxProperties = 32}) => const [];
  ThreadedFrame acquireFrame({
    int maxProperties = 64,
    int maxEvents = kDefaultPollCap,
  }) =>
      const ThreadedFrame(properties: [], events: []);
  List<RiveThreadedEvent> pollEvents({
    int maxEvents = kDefaultPollCap,
    void Function(int maxEvents)? onCapHit,
  }) =>
      const [];
  void pointerDown(double x, double y, {int pointerId = 0}) {}
  void pointerMove(double x, double y, {int pointerId = 0}) {}
  void pointerUp(double x, double y, {int pointerId = 0}) {}
  void pointerExit(double x, double y, {int pointerId = 0}) {}
}
