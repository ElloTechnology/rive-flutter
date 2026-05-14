import 'dart:ffi';

// Internal import to access raw native pointers for artboard/SM/VMI handoff.
// ignore: implementation_imports
import 'package:rive_native/src/ffi/rive_ffi_reference.dart'
    show RiveFFIReference;
// ignore: implementation_imports
import 'package:rive_native/src/ffi/rive_ffi.dart'
    show FFIRiveArtboard, FFIStateMachine;
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
/// - The [RenderTexture] is owned by this controller and disposed in [dispose].
///
/// ## Lifecycle
///
/// 1. Construct with already-created [artboard], [stateMachine], optional
///    [viewModelInstance].
/// 2. Call [initialize] once the layout size is known (async — awaits
///    [RenderTexture.makeRenderTexture]).
/// 3. [BackgroundRiveView] drives the ticker and calls [advance] each frame.
/// 4. Call [dispose] when done.
class BackgroundRiveWidgetController {
  BackgroundRiveWidgetController({
    required this.artboard,
    required this.stateMachine,
    this.viewModelInstance,
  });

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

  Factory? _cachedArtboardFactory;
  bool _ownsClaimedNativePointers = false;

  /// Properties queued via [watchProperty] before [initialize] completes.
  final List<String> _pendingWatchProperties = [];

  bool get isInitialized => _bindings != null;

  /// The [RenderTexture] whose [textureId] [BackgroundRiveView] composites.
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
    _cachedArtboardFactory = ffiArtboard.riveFactory;
    ffiArtboard.releaseNativeOwnership();
    ffiStateMachine.releaseNativeOwnership();
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
  }) async {
    if (_isDisposed) return false;
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

    // Use cached pointers if claimNativeOwnership() was called synchronously
    // before this (async) initialize(); fall back to reading from the wrappers
    // if ownership has not been claimed yet.
    final abPtr = _cachedAbPtr ?? _nativePtrOf(artboard);
    final smPtr = _cachedSmPtr ?? _nativePtrOf(stateMachine);
    final vmiPtr = _nativePtrOf(viewModelInstance);

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

    // Transfer native ownership if not already done via claimNativeOwnership().
    if (_cachedAbPtr == null) {
      if (artboard is FFIRiveArtboard) {
        (artboard as FFIRiveArtboard).releaseNativeOwnership();
      }
      if (stateMachine is FFIStateMachine) {
        (stateMachine as FFIStateMachine).releaseNativeOwnership();
      }
    }

    _renderTexture = rt;
    _bindings = bindings;

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
    final artboardFactory = _cachedArtboardFactory;
    _cachedAbPtr = null;
    _cachedSmPtr = null;
    _cachedArtboardFactory = null;

    if (abPtr != null && abPtr != nullptr && artboardFactory != null) {
      FFIRiveArtboard(abPtr, artboardFactory).dispose();
    }
    if (smPtr != null && smPtr != nullptr) {
      FFIStateMachine(smPtr).dispose();
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

  // ---------------------------------------------------------------------------
  // Events
  // ---------------------------------------------------------------------------

  /// Drains pending Rive state-machine reported events.
  ///
  /// Calls `RiveThreadedBindings.pollEvents` in a loop with [maxEvents] as
  /// the per-call cap, accumulating until a non-full batch arrives. The cap
  /// matches the C++-side `riveThreadedPollEvents` truncation, so any depth
  /// queued between Flutter post-frame ticks surfaces in full instead of
  /// silently dropping past the cap.
  List<RiveThreadedEvent> pollEvents({int maxEvents = kDefaultPollCap}) {
    final bindings = _bindings;
    if (bindings == null) return const [];
    return drainPolls<RiveThreadedEvent>(
      poll: (n) => bindings.pollEvents(maxEvents: n),
      maxEvents: maxEvents,
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
