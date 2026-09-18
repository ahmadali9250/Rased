"""
check_model.py
===============
فحص سريع لأي ملف .tflite قبل ما تنقلوه للتطبيق — يتأكد إنه فعلاً قابل
للتحميل والتشغيل (allocate_tensors + invoke ببيانات وهمية) بمعزل تام
عن أندرويد/Flutter. لو فشل هون، المشكلة بالموديل نفسه مش بالتطبيق.

الاستخدام:
    python check_model.py path/to/best_float16.tflite
"""

import sys

import numpy as np
from ai_edge_litert.interpreter import Interpreter

if len(sys.argv) < 2:
    print("الاستخدام: python check_model.py path/to/model.tflite")
    sys.exit(1)

model_path = sys.argv[1]

interp = Interpreter(model_path=model_path)
interp.allocate_tensors()
print("✅ allocate_tensors نجح")

input_details = interp.get_input_details()
output_details = interp.get_output_details()

print(f"   input:  shape={input_details[0]['shape']}  dtype={input_details[0]['dtype']}")
print(f"   output: shape={output_details[0]['shape']} dtype={output_details[0]['dtype']}")

dummy = np.zeros(input_details[0]['shape'], dtype=input_details[0]['dtype'])
interp.set_tensor(input_details[0]['index'], dummy)
interp.invoke()
print("✅ invoke نجح كمان — الموديل سليم 100%")
