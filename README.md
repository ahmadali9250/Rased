# Rased | راصد

**Rased** is an AI-powered, high-speed dashcam application built with Flutter. It utilizes on-device machine learning (TensorFlow Lite) to automatically detect road hazards—such as potholes, cracks, and broken manholes—in real-time, tagging them with high-accuracy GPS coordinates and reporting them to a central backend.

---

## Key Features

* **Real-Time AI Detection:** Uses a custom YOLO vision model (Float32) running entirely on-device to scan the road without lag.
* **High-Accuracy GPS Tagging:** Automatically locks onto the user's coordinates to ensure precise location data for municipal repairs.
* **Manual Reporting:** A fallback feature allowing users to manually capture damage, verified by the local AI before submission.
* **Bilingual UI & Dark Theme:** Fully responsive, RTL-supported Arabic interface with a sleek, dark-themed design and yellow accents.
* **Seamless Backend Integration:** Robust REST API communication handling user authentication, role management (SuperAdmin/User), and hazard report queueing.

---

## Tech Stack

* **Frontend:** Flutter & Dart
* **AI/ML:** TensorFlow Lite (`tflite_flutter`)
* **Hardware Integration:** Camera API, Geolocator, Image Picker
* **State Management & Storage:** SharedPreferences, HTTP
* **Backend Integration:** RESTful APIs (via DigitalOcean/Render)

---

## Getting Started

Follow these steps to run the Rased app on your local machine.

### Prerequisites
* [Flutter SDK](https://docs.flutter.dev/get-started/install) (latest stable version)
* Android Studio / VS Code
* An Android/iOS physical device (Recommended for Camera and AI performance)

### Installation

1. **Clone the repository:**
```bash
   git clone [https://github.com/YourUsername/Rased.git](https://github.com/YourUsername/Rased.git)
   cd Rased
   ```

2. **Install dependencies:**
```bash
   flutter pub get
   ```

3. **Add the AI Model:**
   * Due to file size limits, the `best_float32.tflite` model is not tracked in version control.
   * Obtain the model file from the team and place it in the `assets/` directory.
   * Ensure `classes.txt` is also present in the `assets/` directory.

4. **Run the application:**
```bash
   flutter run
   ```

---

## Team

* **Frontend Engineer:** [Ahmad Ali](https://github.com/ahmadali9250)
* **AI / ML Engineer:** [Abdallah Abughallous](https://github.com/AbdaullahAG)
* **Backend Engineer:** [Abd Alqader Alsa'di](https://github.com/Abedalqaders)

---

## Privacy & Permissions

Rased requires the following permissions to function correctly:
* **Camera:** To scan the road and capture hazard photos.
* **Location:** To attach precise GPS coordinates to hazard reports.
* **Storage:** To temporarily queue reports if the device loses internet connection.
