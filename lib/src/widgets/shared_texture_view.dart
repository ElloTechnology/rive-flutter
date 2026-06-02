import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:rive/src/widgets/inherited_widgets.dart';
import 'package:rive_native/rive_native.dart';
import 'package:meta/meta.dart';

/// Renderers the [artboard] to a [sharedTexture].
///
/// See [RivePanel]. Only useful when using `Factory.rive`.
///
/// **EXPERIMENTAL**: This API may change or be removed in a future release.
@experimental
class SharedTextureView extends StatefulWidget {
  final Artboard artboard;
  final SharedTextureArtboardWidgetPainter painter;
  final SharedRenderTexture sharedTexture;
  final int drawOrder;
  const SharedTextureView({
    required this.artboard,
    required this.painter,
    required this.sharedTexture,
    required this.drawOrder,
    super.key,
  });

  @override
  State<SharedTextureView> createState() => _SharedTextureViewState();
}

class _SharedTextureViewState extends State<SharedTextureView> {
  @override
  void initState() {
    super.initState();
    widget.painter.artboardChanged(widget.artboard);
  }

  @override
  void didUpdateWidget(covariant SharedTextureView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.artboard != widget.artboard) {
      widget.painter.artboardChanged(widget.artboard);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SharedTextureViewRenderer(
      renderTexturePainter: widget.painter,
      sharedTexture: widget.sharedTexture,
      devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
      drawOrder: widget.drawOrder,
    );
  }
}

class SharedTextureViewRenderer extends LeafRenderObjectWidget {
  final RenderTexturePainter renderTexturePainter;
  final SharedRenderTexture sharedTexture;
  final double devicePixelRatio;
  final int drawOrder;

  const SharedTextureViewRenderer({
    super.key,
    required this.renderTexturePainter,
    required this.sharedTexture,
    required this.devicePixelRatio,
    required this.drawOrder,
  });

  @override
  RenderObject createRenderObject(BuildContext context) {
    return SharedTextureViewRenderObject(sharedTexture)
      ..painter = renderTexturePainter
      ..scrollPosition = Scrollable.maybeOf(context)?.position
      ..devicePixelRatio = devicePixelRatio
      ..drawOrder = drawOrder;
  }

  @override
  void updateRenderObject(
    BuildContext context,
    covariant SharedTextureViewRenderObject renderObject,
  ) {
    renderObject
      ..shared = sharedTexture
      ..painter = renderTexturePainter
      ..scrollPosition = Scrollable.maybeOf(context)?.position
      ..devicePixelRatio = devicePixelRatio
      ..drawOrder = drawOrder;
  }

  @override
  void didUnmountRenderObject(
      covariant SharedTextureViewRenderObject renderObject) {
    renderObject.painter = null;
  }
}

class SharedTextureViewRenderObject extends RiveNativeRenderBox
    implements SharedTexturePainter {
  SharedRenderTexture _shared;

  SharedTextureViewRenderObject(this._shared)
      : super(UnimplementedRenderTexture()) {
    _shared.texture.onTextureChanged = _onRiveTextureChanged;
  }

  int drawOrder = 1;

  /// Accumulated elapsed seconds across frames while dirty tracking skips
  /// the paint cycle. Reset to 0 after each [paintIntoSharedTexture] call.
  double _accumulatedElapsed = 0;

  SharedRenderTexture get shared => _shared;
  set shared(SharedRenderTexture value) {
    if (_shared == value) {
      return;
    }
    _shared.texture.onTextureChanged = null;
    _shared.removePainter(this);
    _shared = value;
    _shared.texture.onTextureChanged = _onRiveTextureChanged;
    _shared.addPainter(this);
    markNeedsPaint();
  }

  bool _shouldAdvance = true;

  @override
  bool get shouldAdvance => _shouldAdvance;

  // Repaint when the texture is created/changed. This reduces the flicker when
  // resizing the widget. This flicker is caused by recreating the underlying
  // texture Rive draws to.
  void _onRiveTextureChanged() => markNeedsLayout();

  @override
  void paintTexture(double elapsedSeconds, {bool forceShouldAdvance = false}) {
    // do nothing. we draw to the shared texture.
  }

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.smallest;

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    _shared.schedulePaint();
  }

  ScrollPosition? _scrollPosition;
  set scrollPosition(ScrollPosition? v) {
    if (identical(v, _scrollPosition)) return;
    _unsubscribe();
    _scrollPosition = v;
    _subscribe();
    _scheduleCheck();
  }

  void _subscribe() => _scrollPosition?.addListener(_scheduleCheck);
  void _unsubscribe() => _scrollPosition?.removeListener(_scheduleCheck);

  void _scheduleCheck() {
    if (!attached) return;
    markNeedsPaint();
  }

  @override
  void dispose() {
    _shared.removePainter(this);
    _shared.texture.onTextureChanged = null;
    super.dispose();
  }

  @override
  void paintIntoSharedTexture(RenderTexture texture) {
    final panelKeyContext = shared.panelKey.currentContext;
    if (panelKeyContext == null) {
      return;
    }
    final panelRenderBox = panelKeyContext.findRenderObject() as RenderBox;
    final dpr = devicePixelRatio;

    // Read the transform fresh every paint. The cached scale on
    // [RiveNativeRenderBox] (`desiredTransformWidth/HeightScale`) only
    // refreshes when this RenderObject's own paint() runs, which composited
    // ancestors (RepaintBoundary inside PageView, Opacity layers, etc.) can
    // skip while still animating a Transform.scale — leaving the cached
    // scale stale while localToGlobal still tracks the live transform.
    //
    // Native: getTransformTo(panelRenderBox) gives the painter->panel relative
    // transform; any ancestor transform shared with the panel cancels out and
    // the Texture widget re-applies it at composite time.
    //
    // Web: the shared texture is a platform view (HtmlElementView) that does
    // NOT re-apply ancestor Flutter transforms (e.g. an ancestor FittedBox /
    // Transform.scale) at composite time. Bake the full painter->screen
    // transform into the draw coordinates instead, otherwise the artwork
    // renders at window-relative coordinates under any ancestor transform.
    final double scaleX, scaleY, translateX, translateY;
    if (kIsWeb) {
      final screen = getTransformTo(null).storage;
      final panelPosition = panelRenderBox.localToGlobal(Offset.zero);
      final globalPosition = localToGlobal(Offset.zero) - panelPosition;
      scaleX = screen[0].abs();
      scaleY = screen[5].abs();
      translateX = globalPosition.dx;
      translateY = globalPosition.dy;
    } else {
      final m = getTransformTo(panelRenderBox).storage;
      scaleX = m[0].abs();
      scaleY = m[5].abs();
      translateX = m[12];
      translateY = m[13];
    }

    // When dirty tracking is enabled, use accumulated elapsed time so the
    // controller receives the full wall-clock delta since the last advance.
    final effectiveElapsed =
        _shared.dirtyTrackingEnabled ? _accumulatedElapsed : elapsedSeconds;
    _accumulatedElapsed = 0;

    final renderer = texture.renderer;
    renderer.save();
    renderer.transform(Mat2D.fromScaleAndTranslation(
      scaleX * dpr,
      scaleY * dpr,
      translateX * dpr,
      translateY * dpr,
    ));
    _shouldAdvance = rivePainter?.paint(
          texture,
          dpr,
          size,
          effectiveElapsed,
        ) ??
        false;
    if (_shouldAdvance) {
      restartTickerIfStopped();
    } else {
      stopTicker();
    }
    renderer.restore();
  }

  @override
  int get sharedDrawOrder => drawOrder;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    markNeedsLayout();
    _shared.addPainter(this);
  }

  @override
  void frameCallback(Duration duration) {
    super.frameCallback(duration);
    _accumulatedElapsed += elapsedSeconds;
    _shared.onFrameTick?.call(elapsedSeconds);
    _shared.schedulePaint();
  }

  @override
  void detach() {
    _unsubscribe();
    _scrollPosition = null;
    _shared.removePainter(this);
    super.detach();
  }
}

base class SharedTextureArtboardWidgetPainter
    extends ArtboardWidgetPainter<ArtboardPainter> {
  SharedTextureArtboardWidgetPainter(ArtboardPainter super.painter);

  void artboardChanged(Artboard artboard) => painter?.artboardChanged(artboard);
}
