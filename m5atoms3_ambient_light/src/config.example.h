#pragma once
// Wi-Fi・EC2制御API設定のテンプレート。
// cp config.example.h config.h してから実際の値を入力すること（config.h は git 管理外）

#define WIFI_SSID "your-ssid"
#define WIFI_PASSWORD "your-password"

// terraform output ec2_control_api_endpoint の値（末尾スラッシュなし）
#define EC2_CONTROL_API_BASE "https://xxxxxxxxxx.execute-api.ap-northeast-1.amazonaws.com"

// infra/terraform.tfvars の ec2_control_shared_secret と同じ値
#define EC2_CONTROL_SHARED_SECRET "change-me"
