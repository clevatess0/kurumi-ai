# KurumiAI

KurumiAI is a Turkish-speaking Android voice assistant built with Flutter. It
uses Groq's OpenAI-compatible chat completions API and can respond with speech,
open installed apps, report battery status, create alarms, and open web
searches or URLs.

## Run

1. Install Flutter 3.22 or newer and an Android SDK.
2. From this directory, run:

   ```bash
   flutter pub get
   flutter run
   ```

3. On first launch, open the settings panel and enter a Groq API key.

The API key is stored locally on the device with `shared_preferences`. It is
never included in the project source.

## Android permissions

The Android manifest requests internet access and microphone access, and
declares the Android intent queries needed for opening apps, browsers, and
alarms. Microphone access is requested at runtime by the app.

## Notes

- This build targets Android because the assistant's app-launching and alarm
  tools use Android intents.
- The assistant's animated core loads the Rive asset from the network and
  shows a loading state if it is unavailable.