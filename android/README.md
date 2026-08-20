# 原生 Android 应用

这是独立运行的原生 Android 客户端。安装 APK 后，用户只需完成图书馆微信登录、选择阅览室和座位；应用直接访问图书馆接口，不需要部署 Node.js、填写域名或配置服务器地址。

## 功能

- 微信链接回调解析，本机会话存储
- 自动读取阅览室与座位
- 实时空位监控和预约
- 明日定时预约、排队通道和结果复核
- 前台服务、锁屏后台运行、成功通知与震动

## 构建

在仓库根目录运行：

```powershell
powershell -ExecutionPolicy Bypass -File .\android\build-apk.ps1
```

脚本使用仓库内的 JDK 17、Android SDK 35 和 Gradle 8.9 工具目录，生成：

```text
output/gotolibrary-native-v1.4.2.apk
```

Android Studio 也可以直接打开 `android/`。项目最低支持 Android 8.0（API 26）。

当前 release APK 使用本机 Android 测试证书签名，适合直接安装测试。正式上架应用商店前，应换成长期 release keystore。
