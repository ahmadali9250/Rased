"""
check_model.py
===============
فحص سريع لأي ملف .tflite قبل نقله للتطبيق، بمعزل عن أندرويد/Flutter:

  * يتأكد أنه يُحمَّل ويُنفَّذ (allocate_tensors + invoke).
  * يطبع شكل/نوع الإدخال والمخرج وكيف سيقرأه التطبيق
    (end-to-end [1,N,6] / raw rows [1,N,4+nc] / raw cols [1,4+nc,N]).
  * يعدّ العمليات ويعلّم التي لا يدعمها GPU delegate عادةً
    (TOPK_V2, GATHER, CAST, SELECT, ...) — وجودها يعني أن جزءاً من الـ graph
    سيعمل على CPU حتى مع GPU.
  * يقيس زمن invoke على هذا الحاسوب (للمقارنة النسبية بين الملفات فقط؛
    الأرقام المطلقة على الهاتف تظهر بلوحة AI داخل التطبيق).

الاستخدام:
    python check_model.py path/to/pothole_yolo26n_416_fp32_raw.tflite [runs]
"""

from __future__ import annotations

import sys
import time

import numpy as np

try:
    from ai_edge_litert.interpreter import Interpreter
except ImportError:  # pragma: no cover
    from tensorflow.lite import Interpreter  # type: ignore

GPU_UNFRIENDLY = {
    "TOPK_V2", "GATHER", "GATHER_ND", "CAST", "SELECT", "SELECT_V2",
    "LOGICAL_AND", "LOGICAL_OR", "NOT_EQUAL", "EQUAL", "FLOOR_MOD",
    "SIGN", "ARG_MAX", "ARG_MIN", "NON_MAX_SUPPRESSION_V4",
    "NON_MAX_SUPPRESSION_V5", "WHERE", "SCATTER_ND", "UNIQUE",
}

if len(sys.argv) < 2:
    print("الاستخدام: python check_model.py path/to/model.tflite [runs]")
    sys.exit(1)

model_path = sys.argv[1]
runs = int(sys.argv[2]) if len(sys.argv) > 2 else 20

interp = Interpreter(model_path=model_path, num_threads=4)
interp.allocate_tensors()
print("✅ allocate_tensors نجح")

inp = interp.get_input_details()[0]
out = interp.get_output_details()[0]
in_shape = [int(x) for x in inp["shape"]]
out_shape = [int(x) for x in out["shape"]]

layout = "NCHW" if len(in_shape) == 4 and in_shape[1] == 3 else "NHWC"
print(f"   input:  shape={in_shape} dtype={inp['dtype'].__name__} layout={layout} "
      f"quant={inp.get('quantization')}")
print(f"   output: shape={out_shape} dtype={out['dtype'].__name__} "
      f"quant={out.get('quantization')}")

# كيف سيفسّره التطبيق (nc=1 للحفر)
nc = 1
if len(out_shape) == 3 and out_shape[2] == 6:
    kind = "end-to-end [1, max_det, 6] (xyxy, conf, cls) — parser: endToEnd"
elif len(out_shape) == 3 and out_shape[2] == 4 + nc:
    kind = f"raw rows [1, anchors, {4 + nc}] (xyxy px + scores) — parser: rowsRaw"
elif len(out_shape) == 3 and out_shape[1] == 4 + nc:
    kind = f"raw cols [1, {4 + nc}, anchors] (cxcywh + scores) — parser: colsRaw + NMS"
else:
    kind = "❌ غير معروف — التطبيق سيرفض هذا الموديل"
print(f"   app parser: {kind}")

# العمليات
try:
    ops = interp._get_ops_details()  # noqa: SLF001 — API داخلي لكنه مستقر عملياً
    names = [o["op_name"] for o in ops]
    counts: dict[str, int] = {}
    for n in names:
        counts[n] = counts.get(n, 0) + 1
    bad = {n: c for n, c in counts.items() if n in GPU_UNFRIENDLY}
    print(f"   ops: {len(names)} total, {len(counts)} distinct")
    if bad:
        print(f"   ⚠️ GPU-unfriendly ops (ستعمل على CPU): {bad}")
    else:
        print("   ✅ لا توجد عمليات معروفة بعدم دعم GPU delegate")
except Exception as e:  # noqa: BLE001
    print(f"   (تعذّر قراءة قائمة العمليات: {e})")

# invoke + توقيت
dtype = inp["dtype"]
if np.issubdtype(dtype, np.integer):
    dummy = np.zeros(in_shape, dtype=dtype)
else:
    dummy = np.random.rand(*in_shape).astype(dtype)
interp.set_tensor(inp["index"], dummy)
interp.invoke()
print("✅ invoke نجح")

times = []
for _ in range(runs):
    t0 = time.perf_counter()
    interp.invoke()
    times.append((time.perf_counter() - t0) * 1000)
times.sort()
print(f"   invoke (CPU, 4 threads, {runs} runs): median {times[len(times) // 2]:.1f} ms, "
      f"min {times[0]:.1f} ms  — للمقارنة النسبية بين الملفات فقط")

result = interp.get_tensor(out["index"])
print(f"   sample output: min={float(result.min()):.3f} max={float(result.max()):.3f}")
