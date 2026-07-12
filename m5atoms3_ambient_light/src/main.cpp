/*
 * M5AtomS3 + M5Stack用環境光センサユニット（BH1750FVI, I2C 0x23）
 * 部屋の明るさをモニタリングし、ボタン長押しでEC2をstart/stopする
 *
 * 接続: AtomS3 の HY2.0-4P 拡張ポート（GROVE）
 *   G1 -> SCL, G2 -> SDA
 *
 * ボタン操作（M5.BtnA、本体前面ボタン）:
 *   1〜3秒 長押し → EC2 start
 *   3秒以上 長押し → EC2 stop
 *
 * 表示: HAS_DISPLAY の定義有無で切り替える。
 *   定義あり（デフォルト、AtomS3無印用） : 内蔵ディスプレイに表示
 *   定義なし（AtomS3 Lite等、ディスプレイ非搭載機用）: RGB LEDの色で表示
 *   ディスプレイが無い機体で一時的に動かす場合は下の #define をコメントアウトする
 */

// #define HAS_DISPLAY

#include <M5Unified.h>
#include <BH1750.h>
#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <HTTPClient.h>
#include "config.h"

#ifndef HAS_DISPLAY
// M5UnifiedのM5.Led APIはAtomS3 Liteでは既知の不具合でRMT初期化に失敗するため
// (https://github.com/m5stack/M5Unified/issues/178)、Adafruit_NeoPixelで
// GPIO35のRGB LEDを直接制御する
#include <Adafruit_NeoPixel.h>
static const uint8_t RGB_LED_PIN = 35;
Adafruit_NeoPixel pixel(1, RGB_LED_PIN, NEO_GRB + NEO_KHZ800);
#endif

static const uint8_t BH1750_ADDR = 0x23;
static const uint32_t READ_INTERVAL_MS = 1000;
static const uint32_t WIFI_CONNECT_TIMEOUT_MS = 15000;
static const uint32_t BTN_START_MIN_MS = 1000;
static const uint32_t BTN_STOP_MIN_MS = 3000;

// ボタン長押し中に閾値を跨いだことを画面表示で知らせるための状態
enum class BtnFeedback
{
  None,
  Holding,    // 押下中、まだ START 閾値未満
  ReadyStart, // START 閾値以上、STOP 閾値未満
  ReadyStop,  // STOP 閾値以上
};

BH1750 lightMeter;
uint32_t lastReadMs = 0;
uint32_t btnPressStartMs = 0;
BtnFeedback lastBtnFeedback = BtnFeedback::None;

// TLSハンドシェイクはスタックを数KB消費するため、loopタスクのデフォルトスタック（8KB）
// を溢れさせないようローカル変数ではなくグローバルで保持する
WiFiClientSecure secureClient;

void showBtnFeedback(BtnFeedback fb)
{
#ifdef HAS_DISPLAY
  M5.Display.fillScreen(BLACK);
  M5.Display.setCursor(0, 0);
  switch (fb)
  {
  case BtnFeedback::Holding:
    M5.Display.setTextColor(WHITE, BLACK);
    M5.Display.print("...");
    break;
  case BtnFeedback::ReadyStart:
    M5.Display.setTextColor(GREEN, BLACK);
    M5.Display.print("START");
    break;
  case BtnFeedback::ReadyStop:
    M5.Display.setTextColor(RED, BLACK);
    M5.Display.print("STOP");
    break;
  default:
    break;
  }
#else
  // ディスプレイが無い機体（AtomS3 Lite等）ではRGB LEDの色でボタン状態を表す
  switch (fb)
  {
  case BtnFeedback::Holding:
    pixel.setPixelColor(0, pixel.Color(40, 40, 40)); // 白（弱め）
    break;
  case BtnFeedback::ReadyStart:
    pixel.setPixelColor(0, pixel.Color(0, 120, 0)); // 緑
    break;
  case BtnFeedback::ReadyStop:
    pixel.setPixelColor(0, pixel.Color(120, 0, 0)); // 赤
    break;
  default:
    pixel.setPixelColor(0, pixel.Color(0, 0, 0)); // 消灯
    break;
  }
  pixel.show();
#endif
}

void connectWiFi()
{
  if (WiFi.status() == WL_CONNECTED)
    return;

  Serial.printf("[WiFi] %s に接続中...\n", WIFI_SSID);
  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);

  uint32_t start = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - start < WIFI_CONNECT_TIMEOUT_MS)
  {
    delay(200);
  }

  if (WiFi.status() == WL_CONNECTED)
  {
    Serial.printf("[WiFi] 接続完了 IP=%s\n", WiFi.localIP().toString().c_str());
  }
  else
  {
    Serial.println("[WiFi] 接続タイムアウト");
  }
}

// EC2 start/stop API を呼び出す。action は "start" または "stop"
bool callEc2Api(const char *action)
{
  Serial.printf("[EC2] callEc2Api(%s) 開始\n", action);
  connectWiFi();
  if (WiFi.status() != WL_CONNECTED)
  {
    Serial.println("[EC2] Wi-Fi未接続のため中止");
    return false;
  }

  // TLS証明書検証は省略（疎通確認用途の簡略化。将来 Amazon Root CA1 のピン留めで強化可能）
  secureClient.setInsecure();

  HTTPClient http;
  String url = String(EC2_CONTROL_API_BASE) + "/ec2/" + action;
  if (!http.begin(secureClient, url))
  {
    Serial.println("[EC2] HTTP begin失敗");
    return false;
  }
  http.addHeader("X-Api-Secret", EC2_CONTROL_SHARED_SECRET);

  int statusCode = http.POST("{}");
  String body = http.getString();
  http.end();

  Serial.printf("[EC2] POST /ec2/%s -> %d: %s\n", action, statusCode, body.c_str());

  bool ok = (statusCode == 200);
#ifdef HAS_DISPLAY
  M5.Display.fillScreen(BLACK);
  M5.Display.setCursor(0, 0);
  M5.Display.setTextColor(WHITE, BLACK);
  M5.Display.printf("%s %s", action, ok ? "OK" : "NG");
#else
  pixel.setPixelColor(0, ok ? pixel.Color(0, 120, 0) : pixel.Color(120, 0, 0)); // 成功=緑、失敗=赤
  pixel.show();
  delay(1500); // 結果を一定時間表示してから消灯に戻す
  pixel.setPixelColor(0, pixel.Color(0, 0, 0));
  pixel.show();
#endif

  return ok;
}

void setup()
{
  auto cfg = M5.config();
  cfg.serial_baudrate = 115200; // 未指定だとM5.begin()がSerial.begin()を呼ばない
  M5.begin(cfg);

#ifdef HAS_DISPLAY
  M5.Display.setRotation(0);
  M5.Display.setTextSize(2);
  M5.Display.setTextColor(WHITE, BLACK);
  M5.Display.fillScreen(BLACK);
#else
  pixel.begin();
  pixel.setBrightness(60); // フル輝度だと眩しいため抑える
  pixel.setPixelColor(0, pixel.Color(0, 0, 0));
  pixel.show();

  // LED自己診断: 各色を順番に光らせて動作確認する
  struct
  {
    const char *name;
    uint8_t r, g, b;
  } ledTestPatterns[] = {
      {"白", 40, 40, 40},
      {"緑", 0, 120, 0},
      {"赤", 120, 0, 0},
      {"青", 0, 0, 120},
      {"消灯", 0, 0, 0},
  };
  for (auto &p : ledTestPatterns)
  {
    Serial.printf("[LED] 自己診断: %s\n", p.name);
    pixel.setPixelColor(0, pixel.Color(p.r, p.g, p.b));
    pixel.show();
    delay(600);
  }
#endif

  // M5Unified の Ex_I2C は Arduino Wire と互換性がないため、
  // ピン番号だけ取得して標準の Wire を GROVE ポート用に初期化する
  Wire.begin(M5.Ex_I2C.getSDA(), M5.Ex_I2C.getSCL());

  if (!lightMeter.begin(BH1750::CONTINUOUS_HIGH_RES_MODE, BH1750_ADDR, &Wire))
  {
    Serial.println("[BH1750] センサーが見つかりません");
#ifdef HAS_DISPLAY
    M5.Display.setCursor(0, 0);
    M5.Display.println("Sensor NG");
#endif
  }

  connectWiFi();
  Serial.println("[BOOT] setup完了、loop開始");
}

void loop()
{
  M5.update();

  if (M5.BtnA.wasPressed())
  {
    btnPressStartMs = millis();
    lastBtnFeedback = BtnFeedback::Holding;
    Serial.printf("[BTN] wasPressed at %lu\n", (unsigned long)btnPressStartMs);
    showBtnFeedback(BtnFeedback::Holding);
  }

  if (M5.BtnA.isPressed())
  {
    uint32_t heldMs = millis() - btnPressStartMs;
    BtnFeedback fb = (heldMs >= BTN_STOP_MIN_MS)    ? BtnFeedback::ReadyStop
                     : (heldMs >= BTN_START_MIN_MS) ? BtnFeedback::ReadyStart
                                                    : BtnFeedback::Holding;
    if (fb != lastBtnFeedback)
    {
      lastBtnFeedback = fb;
      Serial.printf("[BTN] isPressed heldMs=%lu -> feedback=%d\n", (unsigned long)heldMs, (int)fb);
      showBtnFeedback(fb);
    }
  }

  if (M5.BtnA.wasReleased())
  {
    uint32_t heldMs = millis() - btnPressStartMs;
    Serial.printf("[BTN] wasReleased heldMs=%lu (start=%lu stop=%lu)\n",
                  (unsigned long)heldMs, (unsigned long)BTN_START_MIN_MS, (unsigned long)BTN_STOP_MIN_MS);
    lastBtnFeedback = BtnFeedback::None;
    if (heldMs >= BTN_STOP_MIN_MS)
    {
      Serial.println("[BTN] -> stop");
      callEc2Api("stop");
    }
    else if (heldMs >= BTN_START_MIN_MS)
    {
      Serial.println("[BTN] -> start");
      callEc2Api("start");
    }
    else
    {
      Serial.println("[BTN] -> 閾値未満、何もしない");
      lastReadMs = 0; // 閾値未満で離した場合は次ループで即座に照度表示へ戻す
    }
  }

  uint32_t now = millis();
  if (now - lastReadMs < READ_INTERVAL_MS)
  {
    delay(10);
    return;
  }
  lastReadMs = now;

  float lux = lightMeter.readLightLevel();
  if (lux < 0)
  {
    Serial.println("[BH1750] 読み取り失敗");
    return;
  }

  Serial.printf("照度: %.1f lux\n", lux);

#ifdef HAS_DISPLAY
  M5.Display.fillScreen(BLACK);
  M5.Display.setCursor(0, 0);
  M5.Display.setTextColor(WHITE, BLACK);
  M5.Display.printf("%.0f lx", lux);
#endif
}
