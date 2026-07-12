# Client endpoints

Use a single injectable base URL in Android/KMP projects.

- Android emulator: `http://10.0.2.2:18080`
- Desktop/iOS simulator on the same Mac: `http://127.0.0.1:18080`
- Physical Android via `adb reverse`: `http://127.0.0.1:18080`
- Physical device over Wi-Fi: `http://<Mac-LAN-IP>:18080`

Recommended debug configuration:

```kotlin
interface MediaLabConfig {
    val baseUrl: String
}

fun MediaLabConfig.image(
    file: String = "sample.jpg",
    width: Int = 320,
    height: Int = 180,
    quality: Int = 60,
    format: String = "webp",
): String = "$baseUrl/img/insecure/rs:fill:$width:$height/q:$quality/plain/local:///$file@$format"

fun MediaLabConfig.raw(path: String): String = "$baseUrl/media/$path"
fun MediaLabConfig.mock(path: String): String = "$baseUrl/mock/$path"
```

Media3 HLS example:

```kotlin
val mediaItem = MediaItem.fromUri("$baseUrl/media/video/hls/master.m3u8")
player.setMediaItem(mediaItem)
player.prepare()
```

For debug HTTP on Android 9+, allow cleartext only in the debug manifest/network security config, not in release builds.
