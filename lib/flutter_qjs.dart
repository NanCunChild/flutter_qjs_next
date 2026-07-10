import 'package:flutter_qjs_es2023/javascript_runtime.dart';
import './quickjs/quickjs_runtime2.dart';
import './extensions/handle_promises.dart';

export './extensions/handle_promises.dart';
export './quickjs/quickjs_runtime2.dart';
export 'flutter_qjs_logger.dart';
export 'javascript_runtime.dart';
export 'js_eval_result.dart';

JavascriptRuntime getJavascriptRuntime({
  Map<String, dynamic>? extraArgs = const {},
}) {
  JavascriptRuntime runtime;
  runtime = QuickJsRuntime2();
  runtime.enableHandlePromises();
  return runtime;
}
