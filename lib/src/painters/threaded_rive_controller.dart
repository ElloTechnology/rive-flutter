import 'dart:ffi';

import 'package:flutter/widgets.dart' show Alignment;

// Internal import to access raw native pointers for artboard/SM/VMI handoff.
// ignore: implementation_imports
import 'package:rive_native/src/ffi/rive_ffi_reference.dart'
    show RiveFFIReference;
// ignore: implementation_imports
import 'package:rive_native/src/ffi/rive_ffi.dart'
    show FFIRiveArtboard, FFIRiveViewModelInstanceRuntime, FFIStateMachine;
// ignore: implementation_imports
import 'package:rive_native/src/ffi/rive_threaded_ffi.dart';
import 'package:rive_native/rive_native.dart';

import 'event_drainer.dart';

/// A controller for Rive content that advances and renders on a dedicated C++
/// background thread.
///
/// Unlike [RiveWidgetController], this class does NOT advance the state machine
/// on the Flutter UI thread. Instead it:
///
/// 1. Creates its own [RenderTexture] to obtain a `MetalTextureRenderer*`.
/// 2. Passes that renderer — plus the artboard, state machine, and optional
///    ViewModel instance — to [RiveThreadedBindings.create] which hands off
///    native ownership to a [ThreadedScene] running on a background C++ thread.
/// 3. Exposes [advance], [setEnumProperty], [acquireSnapshot], etc. as thin
///    wrappers around [RiveThreadedBindings].
///
/// ## Ownership
///
/// After [initialize] succeeds:
/// - The native [ThreadedScene] owns the artboard and state machine via
///   `unique_ptr`. [releaseNativeOwnership] is called on the Dart wrappers so
///   their [NativeFinalizer]s do not attempt a double-free.
/// - If initialization fails before [ThreadedScene] creation, this controller
///   disposes any native pointers claimed from the Dart wrappers.
/// - The ViewModel instance is ref-counted; both Dart and C++ hold a ref.
///   While this controller is initialized, callers must route ViewModel writes
///   through this controller so they are applied on the background thread.
/// - The [RenderTexture] is owned by this controller and disposed in [dispose].
///
/// ## Lifecycle
///
/// 1. Construct with already-created [artboard], [stateMachine], optional
///    [viewModelInstance].
/// 2. Call [initialize] once the layout size is known (async — awaits
///    [RenderTexture.makeRenderTexture]).
/// 3. [ThreadedRiveView] drives the ticker and calls [advance] each frame.
/// 4. Call [dispose] when done.
class ThreadedRiveController {
  ThreadedRiveController({
    required this.artboard,
    required this.stateMachine,
    this.viewModelInstance,
  });

  /// Most recently initialized [ThreadedRiveController], or `null` if none is
  /// alive. Set during [initialize] success and cleared in [dispose].
  ///
  /// Intended for the threaded-rive bench harness, which needs to read
  /// [advanceCount] / [renderedCount] without plumbing a controller reference
  /// through every layer. Do NOT use from production code — if more than one
  /// controller is alive at once, only the latest is visible here.
  static ThreadedRiveController? get debugActiveController =>
      _debugActiveController;
  static ThreadedRiveController? _debugActiveController;

  final Artboard artboard;
  final StateMachine stateMachine;

  /// Optional ViewModel instance. The C++ side adds its own ref, so the Dart
  /// side retains ownership and must call [viewModelInstance.dispose] normally.
  final ViewModelInstance? viewModelInstance;

  RenderTexture? _renderTexture;
  RiveThreadedBindings? _bindings;

  bool _isDisposed = false;

  /// Cached raw pointer for [artboard], set by [claimNativeOwnership].
  Pointer<Void>? _cachedAbPtr;

  /// Cached raw pointer for [stateMachine], set by [claimNativeOwnership].
  Pointer<Void>? _cachedSmPtr;

  /// Cached raw pointer for [viewModelInstance], set by [claimNativeOwnership].
  /// Captured synchronously so the worker still receives the C++ handle even
  /// if the Dart [ViewModelInstance] is disposed before [initialize] runs
  /// (e.g. by a widget unmount triggered by the same `setState` that activates
  /// threaded rendering).
  Pointer<Void>? _cachedVmiPtr;

  bool _ownsClaimedNativePointers = false;

  /// Properties queued via [watchProperty] before [initialize] completes.
  final List<String> _pendingWatchProperties = [];

  bool get isInitialized => _bindings != null;

  /// True after the native render callback has marked a fatal EGL/GL error
  /// (e.g. EGL_CONTEXT_LOST, or any of clear/makeRenderer/flush returning
  /// false). Once set the bg worker has permanently stopped drawing; the
  /// caller should tear down this controller and fall back to the synchronous
  /// path. The flag is one-way and survives until [dispose].
  bool get hasFatalError => _bindings?.hasFatalError ?? false;

  /// Total bg-thread cycles completed since this controller was initialized.
  /// Bumped once per native `runOneFrame` (state-machine advance + snapshot +
  /// event collection), regardless of whether the render callback produced a
  /// new image. Diverges from [renderedCount] when the render callback
  /// no-ops (zero-size surface, paused worker, future damage tracking).
  ///
  /// Diagnostic-only — used by the threaded-rive bench harness to expose the
  /// bg cycle rate decoupled from the flutter frame rate.
  int get advanceCount => _bindings?.advanceCount ?? 0;

  /// Total bg-thread cycles that produced a new RenderImage. Subset of
  /// [advanceCount]. Diagnostic-only.
  int get renderedCount => _bindings?.renderedCount ?? 0;

  /// The [RenderTexture] whose [textureId] [ThreadedRiveView] composites.
  ///
  /// Valid only after [initialize] returns `true`.
  RenderTexture get renderTexture {
    assert(isInitialized, 'renderTexture accessed before initialize()');
    return _renderTexture!;
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /// Synchronously transfers native ownership of [artboard] and [stateMachine]
  /// from the originating [RiveWidgetController] to this controller.
  ///
  /// Call this immediately after construction (before any widget rebuild that
  /// could trigger [RiveWidgetController.dispose]), then call [initialize]
  /// asynchronously once layout dimensions are available.
  ///
  /// After this call the Dart [artboard] and [stateMachine] wrappers have
  /// [_pointer] set to null, so any subsequent [dispose] on the original
  /// controller is a safe no-op. [initialize] uses the cached pointer values
  /// rather than reading from the (now-null) wrappers.
  void claimNativeOwnership() {
    if (_ownsClaimedNativePointers || isInitialized) return;

    final ffiArtboard = artboard;
    final ffiStateMachine = stateMachine;
    if (ffiArtboard is! FFIRiveArtboard ||
        ffiStateMachine is! FFIStateMachine) {
      return;
    }

    final abPtr = ffiArtboard.pointer;
    final smPtr = ffiStateMachine.pointer;
    if (abPtr == nullptr || smPtr == nullptr) return;

    _cachedAbPtr = abPtr;
    _cachedSmPtr = smPtr;
    ffiArtboard.releaseNativeOwnership();
    ffiStateMachine.releaseNativeOwnership();

    // Capture and detach the VMI native pointer synchronously too. Without
    // this, a widget rebuild that follows a setState activating threaded mode
    // can unmount the originating RiveBuilder, whose dispose() calls
    // viewModelInstance.dispose() → frees the WrappedVMIRuntime native object
    // and nulls _pointer. By the time the asynchronous initialize() reads
    // viewModelInstance.pointer it would be nullptr, leaving
    // ThreadedScene::m_viewModelInstance null and dropping every input write
    // with `setViewModelEnum: no input named '<name>'`. The C++ side still
    // ref-counts the underlying ViewModelInstanceRuntime via
    // riveThreadedRefViewModelInstance, so detaching the Dart finalizer here
    // is safe — only the WrappedVMIRuntime Dart wrapper is released.
    final ffiVmi = viewModelInstance;
    if (ffiVmi is FFIRiveViewModelInstanceRuntime) {
      final vmiPtr = ffiVmi.pointer;
      if (vmiPtr != nullptr) {
        _cachedVmiPtr = vmiPtr;
        ffiVmi.releaseNativeOwnership();
      }
    }

    _ownsClaimedNativePointers = true;
  }

  /// Initialises the [RenderTexture] and the native [ThreadedScene] binding.
  ///
  /// [width] / [height] are physical pixel dimensions (logical × device pixel
  /// ratio). [devicePixelRatio] is used for Metal's display scaling.
  ///
  /// Returns `true` on success (Metal / iOS / macOS with Phase 2 symbols).
  /// Returns `false` on unsupported platforms or if object pointers are invalid.
  Future<bool> initialize({
    required int width,
    required int height,
    required double devicePixelRatio,
    Fit fit = Fit.contain,
    Alignment alignment = Alignment.center,
  }) async {
    if (_isDisposed) return false;
    if (isInitialized) return true;
    assert(!isInitialized, 'initialize() called more than once');

    final rt = RiveNative.instance.makeRenderTexture();
    await rt.makeRenderTexture(width, height);

    // dispose() may have been called while the render-texture allocation was
    // awaited. Abandon the allocation rather than completing a binding for a
    // controller that has already been torn down.
    if (_isDisposed) {
      rt.dispose();
      _disposeClaimedNativePointers();
      return false;
    }

    if (!rt.isReady) {
      rt.dispose();
      _disposeClaimedNativePointers();
      return false;
    }

    final rendererPtr = rt.nativeRendererPtr;
    if (rendererPtr is! Pointer<Void> || rendererPtr == nullptr) {
      rt.dispose();
      _disposeClaimedNativePointers();
      return false;
    }

    claimNativeOwnership();

    final abPtr = _cachedAbPtr ?? nullptr;
    final smPtr = _cachedSmPtr ?? nullptr;
    // Prefer the pointer captured during claimNativeOwnership — the Dart
    // [viewModelInstance] wrapper may have been disposed before this async
    // initialize runs (see comment in claimNativeOwnership above).
    final vmiPtr = _cachedVmiPtr ?? _nativePtrOf(viewModelInstance);

    if (abPtr == nullptr || smPtr == nullptr) {
      rt.dispose();
      _disposeClaimedNativePointers();
      return false;
    }

    if (_isDisposed) {
      rt.dispose();
      _disposeClaimedNativePointers();
      return false;
    }

    final bindings = RiveThreadedBindings.create(
      metalTextureRenderer: rendererPtr,
      artboard: abPtr,
      stateMachine: smPtr,
      viewModelInstance: vmiPtr,
      width: width,
      height: height,
      devicePixelRatio: devicePixelRatio,
      fit: fit.index,
      alignmentX: alignment.x,
      alignmentY: alignment.y,
    );

    if (bindings == null) {
      rt.dispose();
      _disposeClaimedNativePointers();
      return false;
    }

    _ownsClaimedNativePointers = false;

    // Final check: dispose() could have raced in between create() and here.
    // Dispose both allocations so no native resources are leaked.
    if (_isDisposed) {
      bindings.dispose();
      rt.dispose();
      return false;
    }

    _renderTexture = rt;
    _bindings = bindings;
    _debugActiveController = this;

    // Flush any watchProperty calls made before initialization completed.
    for (final name in _pendingWatchProperties) {
      _bindings!.watchProperty(name);
    }
    _pendingWatchProperties.clear();

    return true;
  }

  /// Stops the background thread, unregisters the Flutter texture, and
  /// disposes the [RenderTexture].
  void dispose() {
    _isDisposed = true;
    _bindings?.dispose();
    _bindings = null;
    if (identical(_debugActiveController, this)) {
      _debugActiveController = null;
    }
    _disposeClaimedNativePointers();
    _renderTexture?.dispose();
    _renderTexture = null;
    // Artboard/SM are owned by C++ (already released above).
    // ViewModelInstance retains normal Dart ownership — caller disposes it.
  }

  void _disposeClaimedNativePointers() {
    if (!_ownsClaimedNativePointers) return;

    _ownsClaimedNativePointers = false;
    final abPtr = _cachedAbPtr;
    final smPtr = _cachedSmPtr;
    _cachedAbPtr = null;
    _cachedSmPtr = null;

    if (abPtr != null && abPtr != nullptr) {
      RiveThreadedBindings.releaseClaimedArtboard(abPtr);
    }
    if (smPtr != null && smPtr != nullptr) {
      RiveThreadedBindings.releaseClaimedStateMachine(smPtr);
    }
  }

  // ---------------------------------------------------------------------------
  // Per-frame
  // ---------------------------------------------------------------------------

  /// Posts [elapsedSeconds] to the background thread. Non-blocking.
  void advance(double elapsedSeconds) =>
      _bindings?.postElapsedTime(elapsedSeconds);

  // ---------------------------------------------------------------------------
  // ViewModel inputs
  // ---------------------------------------------------------------------------

  void setEnumProperty(String name, String value) =>
      _bindings?.setEnumProperty(name, value);

  void setNumberProperty(String name, double value) =>
      _bindings?.setNumberProperty(name, value);

  void setBoolProperty(String name, bool value) =>
      _bindings?.setBoolProperty(name, value);

  void setStringProperty(String name, String value) =>
      _bindings?.setStringProperty(name, value);

  void fireTriggerProperty(String name) => _bindings?.fireTrigger(name);

  // ---------------------------------------------------------------------------
  // Snapshot / watch
  // ---------------------------------------------------------------------------

  void watchProperty(String name) {
    if (_bindings != null) {
      _bindings!.watchProperty(name);
    } else {
      _pendingWatchProperties.add(name);
    }
  }

  void unwatchProperty(String name) {
    _pendingWatchProperties.remove(name);
    _bindings?.unwatchProperty(name);
  }

  /// Atomically acquires the latest ViewModel property snapshot.
  ///
  /// Returns an empty list if the controller is not initialised or no snapshot
  /// has been produced yet.
  List<SnapshotEntry> acquireSnapshot({int maxProperties = 32}) =>
      _bindings?.acquireSnapshot(maxProperties: maxProperties) ?? const [];

  /// Acquires the latest snapshot AND drains queued Rive events in a single
  /// FFI round-trip under one native mutex acquisition. The returned snapshot
  /// and event batch always come from the same bg cycle (events that announce
  /// a transition land in the same call as the snapshot reflecting it).
  ///
  /// Returns an empty frame if the controller is not initialised.
  ThreadedFrame acquireFrame({
    int maxProperties = 64,
    int maxEvents = kDefaultPollCap,
  }) =>
      _bindings?.acquireFrame(
        maxProperties: maxProperties,
        maxEvents: maxEvents,
      ) ??
      const ThreadedFrame(properties: [], events: []);

  // ---------------------------------------------------------------------------
  // Events
  // ---------------------------------------------------------------------------

  /// Drains pending Rive state-machine reported events.
  ///
  /// Calls `RiveThreadedBindings.pollEvents` in a loop with [maxEvents] as
  /// the per-call cap, accumulating until a non-full batch arrives or the
  /// iteration cap is hit. The per-call cap matches the C++-side
  /// `riveThreadedPollEvents` truncation, so any depth queued between Flutter
  /// post-frame ticks surfaces in full instead of silently dropping past the
  /// cap. [onCapHit] fires if the iteration ceiling is reached (events may
  /// still be queued past the returned batch).
  List<RiveThreadedEvent> pollEvents({
    int maxEvents = kDefaultPollCap,
    void Function(int maxEvents)? onCapHit,
  }) {
    final bindings = _bindings;
    if (bindings == null) return const [];
    return drainPolls<RiveThreadedEvent>(
      poll: (n) => bindings.pollEvents(maxEvents: n),
      maxEvents: maxEvents,
      onCapHit: onCapHit,
    );
  }

  // ---------------------------------------------------------------------------
  // Pointer events
  // ---------------------------------------------------------------------------

  void pointerDown(double x, double y, {int pointerId = 0}) =>
      _bindings?.pointerDown(x, y, pointerId: pointerId);

  void pointerMove(double x, double y, {int pointerId = 0}) =>
      _bindings?.pointerMove(x, y, pointerId: pointerId);

  void pointerUp(double x, double y, {int pointerId = 0}) =>
      _bindings?.pointerUp(x, y, pointerId: pointerId);

  void pointerExit(double x, double y, {int pointerId = 0}) =>
      _bindings?.pointerExit(x, y, pointerId: pointerId);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Pointer<Void> _nativePtrOf(Object? obj) {
  if (obj == null) return nullptr;
  if (obj is RiveFFIReference) return obj.pointer;
  return nullptr;
}
