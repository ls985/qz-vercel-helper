package com.gotolibrary.app;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Intent;
import android.content.SharedPreferences;
import android.graphics.Color;
import android.os.IBinder;
import android.os.PowerManager;

import org.json.JSONException;

import java.time.Duration;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.time.LocalTime;
import java.time.ZoneId;
import java.time.ZonedDateTime;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Random;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;

public final class ReservationService extends Service {
    static final String ACTION_START = "com.gotolibrary.app.START";
    static final String ACTION_STOP = "com.gotolibrary.app.STOP";
    static final String ACTION_STATUS = "com.gotolibrary.app.STATUS";

    private static final String MONITOR_CHANNEL = "reservation_monitor";
    private static final String RESULT_CHANNEL = "reservation_result";
    private static final int MONITOR_NOTIFICATION = 41;
    private static final int RESULT_NOTIFICATION = 42;
    private static final ZoneId SHANGHAI = ZoneId.of("Asia/Shanghai");

    private final ExecutorService executor = Executors.newSingleThreadExecutor();
    private final Random random = new Random();
    private volatile boolean running;
    private Future<?> work;
    private PowerManager.WakeLock wakeLock;
    private SharedPreferences preferences;
    private NotificationManager notificationManager;

    @Override public void onCreate() {
        super.onCreate();
        preferences = AppConfig.prefs(this);
        notificationManager = getSystemService(NotificationManager.class);
        createNotificationChannels();
    }

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        String action = intent == null ? ACTION_START : intent.getAction();
        if (ACTION_STOP.equals(action)) {
            stopTask("任务已由用户停止");
            return START_NOT_STICKY;
        }
        if (running) return START_REDELIVER_INTENT;

        running = true;
        preferences.edit().putBoolean(AppConfig.KEY_RUNNING, true).apply();
        acquireWakeLock();
        updateState("正在启动", "正在检查本机配置");
        startForeground(MONITOR_NOTIFICATION, monitorNotification("正在启动", "正在检查本机配置"));
        work = executor.submit(this::runConfiguredTask);
        return START_REDELIVER_INTENT;
    }

    private void runConfiguredTask() {
        String cookie = AppConfig.getCookie(this);
        int roomId = preferences.getInt(AppConfig.KEY_ROOM_ID, 0);
        String roomName = preferences.getString(AppConfig.KEY_ROOM_NAME, String.valueOf(roomId));
        String mode = preferences.getString(AppConfig.KEY_MODE, AppConfig.MODE_REALTIME);
        List<String> preferred = AppConfig.selectedSeats(this);
        if (cookie == null || cookie.trim().isEmpty() || roomId == 0) {
            failAndStop("配置不完整", "请重新登录并选择阅览室");
            return;
        }

        TraceintClient client = new TraceintClient(cookie);
        try {
            if (AppConfig.MODE_TOMORROW.equals(mode)) {
                runTomorrow(client, roomId, roomName, preferred);
            } else {
                runRealtime(client, roomId, roomName, preferred);
            }
        } catch (InterruptedException ignored) {
            Thread.currentThread().interrupt();
        } catch (Exception error) {
            if (running) {
                if (TraceintClient.isSessionExpired(error.getMessage())) expireSessionAndStop(error);
                else failAndStop("任务已停止", friendlyError(error));
            }
        }
    }

    private void runRealtime(TraceintClient client, int roomId, String roomName, List<String> preferred)
        throws InterruptedException {
        int round = 0;
        long lastNoSeatLog = 0;
        long backoff = 0;
        Map<String, Long> cooldown = new HashMap<>();
        log("实时捡漏已启动：" + roomName);
        updateState("实时捡漏运行中", roomName + " · 正在监控空位");

        while (running) {
            try {
                round++;
                List<TraceintClient.Seat> seats = client.fetchSeats(roomId);
                List<TraceintClient.Seat> candidates =
                    TraceintClient.orderCandidates(seats, preferred, true);
                long now = System.currentTimeMillis();
                candidates.removeIf(seat -> cooldown.getOrDefault(seat.key, 0L) > now);
                if (candidates.isEmpty()) {
                    if (now - lastNoSeatLog >= 5000) {
                        lastNoSeatLog = now;
                        log("第 " + round + " 轮：暂时没有符合条件的空位");
                    }
                } else {
                    int attempts = Math.min(3, candidates.size());
                    updateState("发现空位", "正在尝试 " + attempts + " 个候选座位");
                    for (int i = 0; running && i < attempts; i++) {
                        TraceintClient.Seat seat = candidates.get(i);
                        try {
                            log("尝试座位 " + seat.name);
                            if (client.reserveSeat(roomId, seat)) {
                                successAndStop("预约成功", roomName + " · " + seat.name);
                                return;
                            }
                        } catch (Exception error) {
                            if (TraceintClient.isSessionExpired(error.getMessage())) {
                                expireSessionAndStop(error);
                                return;
                            }
                            if (TraceintClient.isRiskMessage(error.getMessage())) throw error;
                            log("座位 " + seat.name + " 未预约成功：" + friendlyError(error));
                        }
                        cooldown.put(seat.key, System.currentTimeMillis() + 10_000);
                    }
                }
                backoff = Math.max(0, backoff - 200);
                sleepInterruptibly(3500 + random.nextInt(1200) + backoff);
            } catch (Exception error) {
                if (TraceintClient.isSessionExpired(error.getMessage())) {
                    expireSessionAndStop(error);
                    return;
                }
                if (TraceintClient.isRiskMessage(error.getMessage())) {
                    failAndStop("账号保护已触发", friendlyError(error));
                    return;
                }
                backoff = Math.min(12000, backoff == 0 ? 1500 : Math.round(backoff * 1.6));
                log("轮询失败：" + friendlyError(error) + "，稍后重试");
                updateState("网络重试中", "将在 " + Math.max(1, backoff / 1000) + " 秒后继续");
                sleepInterruptibly(backoff);
            }
        }
    }

    private void runTomorrow(TraceintClient client, int roomId, String roomName, List<String> preferred)
        throws Exception {
        List<TraceintClient.Seat> roomSeats = client.fetchSeats(roomId);
        roomSeats.removeIf(seat -> seat.type != 1 || seat.key.trim().isEmpty() || seat.name.trim().isEmpty());
        if (roomSeats.isEmpty()) throw new IllegalStateException("当前阅览室没有可预约座位");

        ZonedDateTime target = nextRunAt(preferences.getString(AppConfig.KEY_TIME, "20:00:00"));
        String targetText = target.format(DateTimeFormatter.ofPattern("MM-dd HH:mm:ss", Locale.CHINA));
        log("明日预约已启动：" + roomName + "，" + targetText + " 开始监控");
        while (running) {
            long remaining = Duration.between(ZonedDateTime.now(SHANGHAI), target).toMillis();
            if (remaining <= 0) break;
            updateState("等待明日预约", roomName + " · " + targetText + " 开始");
            sleepInterruptibly(Math.min(remaining, 60_000));
        }
        if (!running) return;

        updateState("进入预约队列", roomName + " · 正在连接排队通道");
        TraceintClient.QueueResult queue = client.enterTomorrowQueue();
        log("排队通道：" + queue.message);
        if (queue.shouldStop) {
            failAndStop("明日预约被拦截", queue.message);
            return;
        }

        boolean detailedSupported = true;
        Map<String, Long> cooldown = new HashMap<>();
        long lastNoSeatLog = 0;
        updateState("明日预约运行中", roomName + " · 正在监控明日空位");
        while (running) {
            TraceintClient.TomorrowAvailability availability;
            try {
                availability = client.fetchTomorrowAvailability(roomId, detailedSupported);
            } catch (Exception error) {
                String message = friendlyError(error);
                if (detailedSupported && message.matches("(?is).*(unknown field|cannot query field).*seats.*")) {
                    detailedSupported = false;
                    log("明日接口不提供座位明细，已切换兼容模式");
                    continue;
                }
                if (TraceintClient.isSessionExpired(error.getMessage())) {
                    expireSessionAndStop(error);
                    return;
                }
                if (TraceintClient.isRiskMessage(error.getMessage())) {
                    failAndStop("账号保护已触发", friendlyError(error));
                    return;
                }
                log("明日空位读取失败：" + friendlyError(error));
                sleepInterruptibly(8000);
                continue;
            }

            List<TraceintClient.Seat> pool = detailedSupported ? availability.seats : roomSeats;
            List<TraceintClient.Seat> candidates = TraceintClient.orderCandidates(
                pool, preferred, detailedSupported);
            long now = System.currentTimeMillis();
            candidates.removeIf(seat -> cooldown.getOrDefault(seat.key, 0L) > now);
            if (availability.available != null && availability.available == 0) candidates.clear();

            if (candidates.isEmpty()) {
                if (now - lastNoSeatLog >= 5000) {
                    lastNoSeatLog = now;
                    log("明日预约：当前没有符合条件的空位");
                }
            } else {
                int attempts = Math.min(3, candidates.size());
                updateState("发现明日空位", "正在尝试 " + attempts + " 个候选座位");
                for (int i = 0; running && i < attempts; i++) {
                    TraceintClient.Seat seat = candidates.get(i);
                    try {
                        log("尝试明日座位 " + seat.name);
                        if (client.reserveTomorrow(roomId, seat)) {
                            try {
                                boolean verified = client.verifyTomorrow(roomId, seat);
                                String detail = roomName + " · " + seat.name +
                                    (verified ? "" : "（请在官方页面复核）");
                                successAndStop(verified ? "明日预约成功" : "预约已提交", detail);
                            } catch (Exception verificationError) {
                                log("预约已提交，但结果复核失败：" + friendlyError(verificationError));
                                successAndStop("预约已提交", roomName + " · " + seat.name + "（请在官方页面复核）");
                            }
                            return;
                        }
                    } catch (Exception error) {
                        if (TraceintClient.isSessionExpired(error.getMessage())) {
                            expireSessionAndStop(error);
                            return;
                        }
                        if (TraceintClient.isRiskMessage(error.getMessage())) throw error;
                        log("座位 " + seat.name + " 未预约成功：" + friendlyError(error));
                    }
                    cooldown.put(seat.key, System.currentTimeMillis() + 8000);
                }
            }
            sleepInterruptibly(6500 + random.nextInt(3000));
        }
    }

    private ZonedDateTime nextRunAt(String value) {
        LocalTime time;
        try {
            time = LocalTime.parse(value, DateTimeFormatter.ofPattern("HH:mm:ss"));
        } catch (Exception ignored) {
            time = LocalTime.of(20, 0);
        }
        ZonedDateTime now = ZonedDateTime.now(SHANGHAI);
        ZonedDateTime target = ZonedDateTime.of(LocalDateTime.of(LocalDate.now(SHANGHAI), time), SHANGHAI);
        return target.isAfter(now) ? target : target.plusDays(1);
    }

    private void sleepInterruptibly(long milliseconds) throws InterruptedException {
        long end = System.currentTimeMillis() + milliseconds;
        while (running) {
            ensureWakeLock();
            long remaining = end - System.currentTimeMillis();
            if (remaining <= 0) return;
            Thread.sleep(Math.min(remaining, 1000));
        }
    }

    private void updateState(String title, String detail) {
        preferences.edit()
            .putBoolean(AppConfig.KEY_RUNNING, running)
            .putString(AppConfig.KEY_STATUS_TITLE, title)
            .putString(AppConfig.KEY_STATUS_DETAIL, detail)
            .apply();
        if (running) notificationManager.notify(
            MONITOR_NOTIFICATION, monitorNotification(title, detail));
        sendBroadcast(new Intent(ACTION_STATUS).setPackage(getPackageName()));
    }

    private void log(String message) {
        AppConfig.addLog(this, message);
        sendBroadcast(new Intent(ACTION_STATUS).setPackage(getPackageName()));
    }

    private void successAndStop(String title, String detail) {
        log(title + "：" + detail);
        notificationManager.notify(RESULT_NOTIFICATION, resultNotification(title, detail));
        finishTask(title, detail);
    }

    private void failAndStop(String title, String detail) {
        log(title + "：" + detail);
        notificationManager.notify(RESULT_NOTIFICATION, resultNotification(title, detail));
        finishTask(title, detail);
    }

    private void expireSessionAndStop(Exception error) {
        AppConfig.clearCookie(this);
        failAndStop("登录已失效", "请重新微信登录后再启动任务：" + friendlyError(error));
    }

    private void stopTask(String message) {
        if (!running && !preferences.getBoolean(AppConfig.KEY_RUNNING, false)) {
            stopSelf();
            return;
        }
        running = false;
        if (work != null) work.cancel(true);
        AppConfig.addLog(this, message);
        finishTask("任务已停止", message);
    }

    private void finishTask(String title, String detail) {
        running = false;
        preferences.edit()
            .putBoolean(AppConfig.KEY_RUNNING, false)
            .putString(AppConfig.KEY_STATUS_TITLE, title)
            .putString(AppConfig.KEY_STATUS_DETAIL, detail)
            .apply();
        releaseWakeLock();
        sendBroadcast(new Intent(ACTION_STATUS).setPackage(getPackageName()));
        stopForeground(STOP_FOREGROUND_REMOVE);
        stopSelf();
    }

    private void acquireWakeLock() {
        PowerManager manager = (PowerManager) getSystemService(POWER_SERVICE);
        wakeLock = manager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "gotolibrary:reservation");
        wakeLock.setReferenceCounted(false);
        wakeLock.acquire(10 * 60 * 1000L);
    }

    private void ensureWakeLock() {
        if (running && (wakeLock == null || !wakeLock.isHeld())) acquireWakeLock();
    }

    private void releaseWakeLock() {
        if (wakeLock != null && wakeLock.isHeld()) wakeLock.release();
        wakeLock = null;
    }

    private void createNotificationChannels() {
        NotificationChannel monitor = new NotificationChannel(
            MONITOR_CHANNEL, "预约任务状态", NotificationManager.IMPORTANCE_LOW);
        monitor.setDescription("显示正在运行的座位监控任务");
        monitor.setSound(null, null);
        NotificationChannel result = new NotificationChannel(
            RESULT_CHANNEL, "预约结果", NotificationManager.IMPORTANCE_HIGH);
        result.setDescription("通知预约成功或任务异常");
        result.enableVibration(true);
        result.enableLights(true);
        result.setLightColor(Color.rgb(8, 122, 99));
        notificationManager.createNotificationChannel(monitor);
        notificationManager.createNotificationChannel(result);
    }

    private Notification monitorNotification(String title, String detail) {
        return new Notification.Builder(this, MONITOR_CHANNEL)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title)
            .setContentText(detail)
            .setContentIntent(mainPendingIntent())
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .build();
    }

    private Notification resultNotification(String title, String detail) {
        return new Notification.Builder(this, RESULT_CHANNEL)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title)
            .setContentText(detail)
            .setStyle(new Notification.BigTextStyle().bigText(detail))
            .setContentIntent(mainPendingIntent())
            .setAutoCancel(true)
            .setCategory(Notification.CATEGORY_EVENT)
            .build();
    }

    private PendingIntent mainPendingIntent() {
        Intent intent = new Intent(this, MainActivity.class)
            .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        return PendingIntent.getActivity(this, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
    }

    private static String friendlyError(Exception error) {
        String value = error.getMessage();
        if (value == null || value.trim().isEmpty()) value = error.getClass().getSimpleName();
        return value;
    }

    @Override public void onDestroy() {
        running = false;
        releaseWakeLock();
        executor.shutdownNow();
        if (preferences != null && preferences.getBoolean(AppConfig.KEY_RUNNING, false)) {
            preferences.edit()
                .putBoolean(AppConfig.KEY_RUNNING, false)
                .putString(AppConfig.KEY_STATUS_TITLE, "任务已中断")
                .putString(AppConfig.KEY_STATUS_DETAIL, "后台服务已结束，请重新启动任务")
                .apply();
            AppConfig.addLog(this, "后台服务已结束");
            sendBroadcast(new Intent(ACTION_STATUS).setPackage(getPackageName()));
        }
        super.onDestroy();
    }

    @Override public IBinder onBind(Intent intent) {
        return null;
    }
}
