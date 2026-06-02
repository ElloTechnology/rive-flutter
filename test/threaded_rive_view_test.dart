import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rive/rive.dart';
import 'package:rive_native/rive_native.dart' show Fit;

/// Captures the arguments [ThreadedRiveView] passes to
/// [ThreadedRiveController.initialize]. `initialize` returns `false` so the
/// view stops before building the `Texture` (which would need a real native
/// render texture); every other member is unused by that early-return path and
/// is routed through [noSuchMethod].
class _CapturingThreadedRiveController implements ThreadedRiveController {
  int? capturedWidth;
  int? capturedHeight;
  int? capturedFitWidth;
  int? capturedFitHeight;
  double? capturedDpr;
  Fit? capturedFit;
  int initializeCalls = 0;

  @override
  Future<bool> initialize({
    required int width,
    required int height,
    int fitWidth = 0,
    int fitHeight = 0,
    required double devicePixelRatio,
    Fit fit = Fit.contain,
    Alignment alignment = Alignment.center,
    double targetFps = 0.0,
  }) async {
    initializeCalls++;
    capturedWidth = width;
    capturedHeight = height;
    capturedFitWidth = fitWidth;
    capturedFitHeight = fitHeight;
    capturedDpr = devicePixelRatio;
    capturedFit = fit;
    return false;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Widget _host({
  required ThreadedRiveController controller,
  required double dpr,
  required Size logicalSize,
  Size? fitFrameSize,
}) {
  return MediaQuery(
    data: MediaQueryData(devicePixelRatio: dpr),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: SizedBox(
          width: logicalSize.width,
          height: logicalSize.height,
          child: ThreadedRiveView(
            controller: controller,
            fit: Fit.cover,
            fitFrameSize: fitFrameSize,
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('ThreadedRiveView fit-frame forwarding (XP-1123)', () {
    testWidgets(
        'forwards fitFrameSize x devicePixelRatio as fitWidth/fitHeight',
        (tester) async {
      final controller = _CapturingThreadedRiveController();

      await tester.pumpWidget(_host(
        controller: controller,
        dpr: 2.0,
        // Within the default 800x600 logical test surface so the view isn't
        // constraint-clamped.
        logicalSize: const Size(300, 400),
        fitFrameSize: const Size(260, 325),
      ));
      // Run the post-frame _tryInitialize and let the async initialize settle.
      await tester.pump();
      await tester.pump();

      expect(controller.initializeCalls, 1);
      // Texture is sized to the full widget bounds (logical x dpr).
      expect(controller.capturedWidth, 600);
      expect(controller.capturedHeight, 800);
      // Fit frame is the artboard layout box (logical x dpr), decoupled from
      // the texture so cover-fit matches the synchronous path.
      expect(controller.capturedFitWidth, 520);
      expect(controller.capturedFitHeight, 650);
      expect(controller.capturedDpr, 2.0);
      expect(controller.capturedFit, Fit.cover);
    });

    testWidgets('rounds fitFrameSize x dpr to the nearest pixel',
        (tester) async {
      final controller = _CapturingThreadedRiveController();

      await tester.pumpWidget(_host(
        controller: controller,
        dpr: 2.75,
        logicalSize: const Size(360, 800),
        fitFrameSize: const Size(260, 325),
      ));
      await tester.pump();
      await tester.pump();

      // (260 * 2.75).round() = 715, (325 * 2.75).round() = 894.
      expect(controller.capturedFitWidth, 715);
      expect(controller.capturedFitHeight, 894);
    });

    testWidgets(
        'omitting fitFrameSize sends 0/0 so native fits the full texture',
        (tester) async {
      final controller = _CapturingThreadedRiveController();

      await tester.pumpWidget(_host(
        controller: controller,
        dpr: 2.0,
        logicalSize: const Size(360, 800),
        // fitFrameSize intentionally null.
      ));
      await tester.pump();
      await tester.pump();

      expect(controller.initializeCalls, 1);
      expect(controller.capturedFitWidth, 0);
      expect(controller.capturedFitHeight, 0);
    });
  });
}
