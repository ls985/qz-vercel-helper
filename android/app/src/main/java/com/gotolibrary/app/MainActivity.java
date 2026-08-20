package com.gotolibrary.app;

import android.annotation.SuppressLint;
import android.Manifest;
import android.app.Activity;
import android.app.AlertDialog;
import android.app.TimePickerDialog;
import android.content.BroadcastReceiver;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Bundle;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowInsets;
import android.widget.ArrayAdapter;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.RadioButton;
import android.widget.RadioGroup;
import android.widget.ScrollView;
import android.widget.Spinner;
import android.widget.TextView;
import android.widget.Toast;
import android.util.Log;

import java.util.ArrayList;
import java.util.Calendar;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public final class MainActivity extends Activity {
    private static final String LOG_TAG = "GoToLibraryUI";
    private static final int NOTIFICATION_REQUEST = 1002;

    private final ExecutorService executor = Executors.newSingleThreadExecutor();
    private final List<TraceintClient.Room> rooms = new ArrayList<>();
    private List<TraceintClient.Seat> currentSeats = new ArrayList<>();
    private SharedPreferences preferences;
    private Spinner roomSpinner;
    private Button loginButton;
    private Button refreshRoomsButton;
    private Button selectSeatsButton;
    private Button startButton;
    private Button stopButton;
    private Button copyLoginLinkButton;
    private Button clearLoginButton;
    private Button parseLoginButton;
    private EditText authUrlInput;
    private ScrollView mainScroll;
    private View loginPanel;
    private PulseDotView statusDot;
    private TextView loginStatus;
    private TextView seatSummary;
    private TextView taskTitle;
    private TextView taskDetail;
    private TextView logText;
    private RadioGroup modeGroup;
    private RadioButton realtimeMode;
    private RadioButton tomorrowMode;
    private LinearLayout tomorrowTimeRow;
    private EditText tomorrowTime;
    private LinearLayout loginGuts;
    private Button reloginButton;
    private TextView tomorrowHint;
    private Button copyLogsButton;
    private boolean loginExpandedManually;
    private boolean receiverRegistered;

    private final BroadcastReceiver statusReceiver = new BroadcastReceiver() {
        @Override public void onReceive(Context context, Intent intent) {
            renderState();
        }
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        getWindow().setStatusBarColor(getColor(R.color.app_background));
        getWindow().setNavigationBarColor(getColor(R.color.app_background));
        getWindow().getDecorView().setSystemUiVisibility(0);
        setContentView(R.layout.activity_main);
        preferences = AppConfig.prefs(this);
        bindViews();
        configureInsets();
        configureActions();
        applyGlassSurfaces();
        UiFx.attachPressFx(loginButton, refreshRoomsButton, selectSeatsButton,
            startButton, stopButton, copyLoginLinkButton, clearLoginButton, parseLoginButton,
            reloginButton, copyLogsButton);
        UiFx.playEntrance(findViewById(R.id.contentColumn));
        restoreConfig();
        renderState();
        requestNotificationPermission();
        if (AppConfig.isLoggedIn(this)) refreshRooms(false);
    }

    private void bindViews() {
        roomSpinner = findViewById(R.id.roomSpinner);
        loginButton = findViewById(R.id.loginButton);
        refreshRoomsButton = findViewById(R.id.refreshRoomsButton);
        selectSeatsButton = findViewById(R.id.selectSeatsButton);
        startButton = findViewById(R.id.startButton);
        stopButton = findViewById(R.id.stopButton);
        copyLoginLinkButton = findViewById(R.id.copyLoginLinkButton);
        clearLoginButton = findViewById(R.id.clearLoginButton);
        parseLoginButton = findViewById(R.id.parseLoginButton);
        authUrlInput = findViewById(R.id.authUrlInput);
        mainScroll = findViewById(R.id.mainScroll);
        loginPanel = findViewById(R.id.loginPanel);
        statusDot = findViewById(R.id.statusDot);
        loginStatus = findViewById(R.id.loginStatus);
        seatSummary = findViewById(R.id.seatSummary);
        taskTitle = findViewById(R.id.taskTitle);
        taskDetail = findViewById(R.id.taskDetail);
        logText = findViewById(R.id.logText);
        modeGroup = findViewById(R.id.modeGroup);
        realtimeMode = findViewById(R.id.realtimeMode);
        tomorrowMode = findViewById(R.id.tomorrowMode);
        tomorrowTimeRow = findViewById(R.id.tomorrowTimeRow);
        tomorrowTime = findViewById(R.id.tomorrowTime);
        loginGuts = findViewById(R.id.loginGuts);
        reloginButton = findViewById(R.id.reloginButton);
        tomorrowHint = findViewById(R.id.tomorrowHint);
        copyLogsButton = findViewById(R.id.copyLogsButton);
    }

    private void configureInsets() {
        if (Build.VERSION.SDK_INT < 35) return;
        mainScroll.setOnApplyWindowInsetsListener((view, insets) -> {
            android.graphics.Insets bars = insets.getInsets(WindowInsets.Type.systemBars());
            android.graphics.Insets ime = insets.getInsets(WindowInsets.Type.ime());
            view.setPadding(bars.left, bars.top, bars.right,
                Math.max(bars.bottom, ime.bottom));
            return insets;
        });
    }

    private void configureActions() {
        loginButton.setOnClickListener(view -> {
            if (AppConfig.isLoggedIn(this)) showLoginMenu();
            else focusLoginSetup();
        });
        copyLoginLinkButton.setOnClickListener(view -> copyWechatLoginLink());
        parseLoginButton.setOnClickListener(view -> parseWechatCallback());
        clearLoginButton.setOnClickListener(view -> clearLocalSession());
        reloginButton.setOnClickListener(view -> {
            loginExpandedManually = true;
            renderState();
            focusLoginSetup();
        });
        copyLogsButton.setOnClickListener(view -> {
            ClipboardManager clipboard = (ClipboardManager) getSystemService(CLIPBOARD_SERVICE);
            clipboard.setPrimaryClip(ClipData.newPlainText("运行记录", AppConfig.logsText(this)));
            Toast.makeText(this, R.string.copy_logs_done, Toast.LENGTH_SHORT).show();
        });
        refreshRoomsButton.setOnClickListener(view -> refreshRooms(true));
        selectSeatsButton.setOnClickListener(view -> loadSeatsAndShowPicker());
        modeGroup.setOnCheckedChangeListener((group, checkedId) -> {
            boolean tomorrow = checkedId == R.id.tomorrowMode;
            tomorrowTimeRow.setVisibility(tomorrow ? View.VISIBLE : View.GONE);
            tomorrowHint.setVisibility(tomorrow ? View.VISIBLE : View.GONE);
        });
        startButton.setOnClickListener(view -> startTask());
        tomorrowTime.setOnClickListener(view -> showTimePicker());
        stopButton.setOnClickListener(view -> {
            Intent intent = new Intent(this, ReservationService.class);
            intent.setAction(ReservationService.ACTION_STOP);
            startService(intent);
        });
        roomSpinner.setOnItemSelectedListener(new android.widget.AdapterView.OnItemSelectedListener() {
            @Override public void onItemSelected(android.widget.AdapterView<?> parent, View view, int position, long id) {
                if (position < 0 || position >= rooms.size()) return;
                TraceintClient.Room room = rooms.get(position);
                int previous = preferences.getInt(AppConfig.KEY_ROOM_ID, 0);
                SharedPreferences.Editor editor = preferences.edit()
                    .putInt(AppConfig.KEY_ROOM_ID, room.id)
                    .putString(AppConfig.KEY_ROOM_NAME, room.name);
                if (previous != 0 && previous != room.id) {
                    currentSeats = new ArrayList<>();
                    AppConfig.saveSelectedSeats(MainActivity.this, new ArrayList<>());
                }
                editor.apply();
                renderSeatSummary();
            }
            @Override public void onNothingSelected(android.widget.AdapterView<?> parent) {}
        });
    }

    private void restoreConfig() {
        String mode = preferences.getString(AppConfig.KEY_MODE, AppConfig.MODE_REALTIME);
        if (AppConfig.MODE_TOMORROW.equals(mode)) tomorrowMode.setChecked(true);
        else realtimeMode.setChecked(true);
        tomorrowTime.setText(preferences.getString(AppConfig.KEY_TIME, "20:00:00"));
        tomorrowTimeRow.setVisibility(tomorrowMode.isChecked() ? View.VISIBLE : View.GONE);
        tomorrowHint.setVisibility(tomorrowMode.isChecked() ? View.VISIBLE : View.GONE);
        ArrayAdapter<String> placeholder = new ArrayAdapter<>(this,
            R.layout.spinner_item, Collections.singletonList("登录后读取阅览室"));
        placeholder.setDropDownViewResource(R.layout.spinner_dropdown_item);
        roomSpinner.setAdapter(placeholder);
    }

    private void applyGlassSurfaces() {
        float density = getResources().getDisplayMetrics().density;
        float radius = 22f * density;
        float stroke = Math.max(1f, 1.2f * density);
        findViewById(R.id.headerPanel).setBackground(new GlassPanelDrawable(
            0x8C0A1D14, 0x8CFFFFFF, 0x1FFFFFFF, radius, stroke));
        findViewById(R.id.statusPanel).setBackground(new GlassPanelDrawable(
            0x660D2A1E, 0x99D9FFE9, 0x2AFFFFFF, radius, stroke));
        for (int id : new int[]{R.id.loginPanel, R.id.configPanel, R.id.modePanel, R.id.logsPanel}) {
            findViewById(id).setBackground(new GlassPanelDrawable(
                0x59101F17, 0x73FFFFFF, 0x17FFFFFF, radius, stroke));
        }
    }
    private void renderState() {
        boolean loggedIn = AppConfig.isLoggedIn(this);
        boolean running = preferences.getBoolean(AppConfig.KEY_RUNNING, false);
        statusDot.setActive(running);
        statusDot.setTint(getColor(!loggedIn ? R.color.danger
            : running ? R.color.primary : R.color.secondary_text));
        // 登录成功后把登录面板折叠成摘要，把常用配置顶上来；未登录或手动展开时显示完整表单
        boolean showLoginGuts = !loggedIn || loginExpandedManually;
        if (loginGuts.isLaidOut()) {
            android.transition.TransitionManager.beginDelayedTransition((ViewGroup) loginPanel);
        }
        loginGuts.setVisibility(showLoginGuts ? View.VISIBLE : View.GONE);
        reloginButton.setVisibility(showLoginGuts ? View.GONE : View.VISIBLE);
        loginStatus.setText(loggedIn ? "微信登录有效，会话仅保存在本机" : "尚未登录");
        loginStatus.setTextColor(getColor(loggedIn ? R.color.primary : R.color.danger));
        loginButton.setText(loggedIn ? "账号" : "微信登录");
        boolean roomsLoaded = !rooms.isEmpty();
        String fallbackDetail = !loggedIn ? "请先完成图书馆微信登录" :
            roomsLoaded ? "选择阅览室和任务模式后即可启动" : "正在读取可用阅览室";
        if (!running && !loggedIn) {
            taskTitle.setText("需要登录");
            taskDetail.setText(fallbackDetail);
        } else if (!running && !roomsLoaded) {
            taskTitle.setText("正在准备");
            taskDetail.setText(fallbackDetail);
        } else {
            taskTitle.setText(preferences.getString(AppConfig.KEY_STATUS_TITLE,
                running ? "任务运行中" : "准备就绪"));
            taskDetail.setText(preferences.getString(AppConfig.KEY_STATUS_DETAIL, fallbackDetail));
        }
        startButton.setEnabled(!running && loggedIn && roomsLoaded);
        stopButton.setEnabled(running);
        refreshRoomsButton.setEnabled(loggedIn && !running);
        selectSeatsButton.setEnabled(loggedIn && roomsLoaded && !running);
        loginButton.setEnabled(!running);
        copyLoginLinkButton.setEnabled(!running);
        clearLoginButton.setEnabled(!running && loggedIn);
        reloginButton.setEnabled(!running);
        parseLoginButton.setEnabled(!running);
        authUrlInput.setEnabled(!running);
        roomSpinner.setEnabled(roomsLoaded && !running);
        modeGroup.setEnabled(!running);
        realtimeMode.setEnabled(!running);
        tomorrowMode.setEnabled(!running);
        tomorrowTime.setEnabled(!running);
        logText.setText(AppConfig.logsText(this));
        renderSeatSummary();
    }

    private void renderSeatSummary() {
        List<String> selected = AppConfig.selectedSeats(this);
        if (selected.isEmpty()) {
            seatSummary.setText("未限制座位，将选择任意空位");
        } else {
            String shown = String.join("、", selected.subList(0, Math.min(8, selected.size())));
            if (selected.size() > 8) shown += " 等 " + selected.size() + " 个";
            seatSummary.setText(getString(R.string.seat_summary_format, shown));
        }
    }

    private void showLoginMenu() {
        new AlertDialog.Builder(this, R.style.GlassDialog)
            .setTitle("本机登录会话")
            .setItems(new String[]{"重新微信登录", "清除登录"}, (dialog, which) -> {
                if (which == 0) focusLoginSetup();
                else clearLocalSession();
            }).show();
    }

    private void focusLoginSetup() {
        loginExpandedManually = true;
        if (loginGuts.getVisibility() != View.VISIBLE) renderState();
        mainScroll.post(() -> mainScroll.smoothScrollTo(0, loginPanel.getTop()));
        authUrlInput.requestFocus();
    }

    private void copyWechatLoginLink() {
        ClipboardManager clipboard = (ClipboardManager) getSystemService(CLIPBOARD_SERVICE);
        clipboard.setPrimaryClip(ClipData.newPlainText("微信登录链接", TraceintClient.LOGIN_URL));
        AppConfig.addLog(this, "已复制微信登录链接，请在微信内完成登录");
        Toast.makeText(this, "登录链接已复制，请在微信中打开", Toast.LENGTH_LONG).show();
        renderState();
    }

    private void parseWechatCallback() {
        String callback = authUrlInput.getText().toString().trim();
        if (callback.isEmpty()) {
            authUrlInput.setError("请粘贴微信登录后的完整页面地址");
            return;
        }
        parseLoginButton.setEnabled(false);
        parseLoginButton.setText("正在解析登录…");
        executor.execute(() -> {
            try {
                String cookie = TraceintClient.exchangeCallbackForCookie(callback);
                if (!AppConfig.setCookie(this, cookie)) {
                    throw new IllegalStateException("本机加密存储初始化失败");
                }
                List<TraceintClient.Room> fetched;
                try {
                    fetched = new TraceintClient(cookie).fetchRooms();
                } catch (Exception error) {
                    Log.e(LOG_TAG, "Wechat login succeeded but room loading failed", error);
                    runOnUiThread(() -> {
                        authUrlInput.setText("");
                        AppConfig.addLog(this, "微信登录成功（Cookie：" +
                            TraceintClient.cookieNames(cookie) + "），阅览室读取失败：" + error.getMessage());
                        parseLoginButton.setText(R.string.parse_login);
                        renderState();
                        Toast.makeText(this, "登录已保存，请点刷新重试", Toast.LENGTH_LONG).show();
                    });
                    return;
                }
                if (fetched.isEmpty()) throw new IllegalStateException("登录会话没有返回阅览室");
                runOnUiThread(() -> {
                    authUrlInput.setText("");
                    rooms.clear();
                    currentSeats = new ArrayList<>();
                    loginExpandedManually = false;
                    AppConfig.addLog(this, "微信登录成功（Cookie：" +
                        TraceintClient.cookieNames(cookie) + "），已读取 " + fetched.size() + " 个阅览室");
                    parseLoginButton.setText(R.string.parse_login);
                    renderState();
                    applyRooms(fetched, true);
                });
            } catch (Exception error) {
                Log.e(LOG_TAG, "Wechat login validation failed", error);
                runOnUiThread(() -> {
                    parseLoginButton.setEnabled(true);
                    parseLoginButton.setText(R.string.parse_login);
                    String message = "登录验证失败：" + error.getMessage();
                    AppConfig.addLog(this, message);
                    logText.setText(AppConfig.logsText(this));
                    Toast.makeText(this, message, Toast.LENGTH_LONG).show();
                });
            }
        });
    }

    private void clearLocalSession() {
        AppConfig.clearCookie(this);
        loginExpandedManually = false;
        preferences.edit().remove(AppConfig.KEY_ROOM_ID).remove(AppConfig.KEY_ROOM_NAME).apply();
        rooms.clear();
        currentSeats = new ArrayList<>();
        AppConfig.saveSelectedSeats(this, new ArrayList<>());
        authUrlInput.setText("");
        restoreConfig();
        AppConfig.addLog(this, "已清除本机登录会话");
        renderState();
    }

    private void refreshRooms(boolean notify) {
        String cookie = AppConfig.getCookie(this);
        if (cookie == null || cookie.trim().isEmpty()) {
            Toast.makeText(this, "请先微信登录", Toast.LENGTH_SHORT).show();
            return;
        }
        refreshRoomsButton.setEnabled(false);
        refreshRoomsButton.setText("读取中");
        executor.execute(() -> {
            try {
                List<TraceintClient.Room> fetched = new TraceintClient(cookie).fetchRooms();
                if (fetched.isEmpty()) throw new IllegalStateException("账号没有返回阅览室");
                runOnUiThread(() -> applyRooms(fetched, notify));
            } catch (Exception error) {
                runOnUiThread(() -> {
                    if (TraceintClient.isSessionExpired(error.getMessage())) {
                        AppConfig.clearCookie(this);
                        rooms.clear();
                        currentSeats = new ArrayList<>();
                        AppConfig.addLog(this, "登录会话已失效，请重新微信登录");
                        renderState();
                        Toast.makeText(this, "登录已失效，请重新微信登录", Toast.LENGTH_LONG).show();
                        return;
                    }
                    refreshRoomsButton.setEnabled(true);
                    refreshRoomsButton.setText("刷新");
                    Toast.makeText(this, "读取失败：" + error.getMessage(), Toast.LENGTH_LONG).show();
                });
            }
        });
    }

    private void applyRooms(List<TraceintClient.Room> fetched, boolean notify) {
        rooms.clear();
        rooms.addAll(fetched);
        ArrayAdapter<TraceintClient.Room> adapter = new ArrayAdapter<>(
            this, R.layout.spinner_item, rooms);
        adapter.setDropDownViewResource(R.layout.spinner_dropdown_item);
        roomSpinner.setAdapter(adapter);
        int savedId = preferences.getInt(AppConfig.KEY_ROOM_ID, 0);
        int selected = 0;
        for (int i = 0; i < rooms.size(); i++) if (rooms.get(i).id == savedId) selected = i;
        roomSpinner.setSelection(selected);
        refreshRoomsButton.setEnabled(true);
        refreshRoomsButton.setText("刷新");
        renderState();
        if (notify) Toast.makeText(this, "已读取 " + rooms.size() + " 个阅览室", Toast.LENGTH_SHORT).show();
    }

    private void loadSeatsAndShowPicker() {
        int roomId = preferences.getInt(AppConfig.KEY_ROOM_ID, 0);
        String cookie = AppConfig.getCookie(this);
        if (roomId == 0 || cookie == null || cookie.trim().isEmpty()) {
            Toast.makeText(this, "请先登录并选择阅览室", Toast.LENGTH_SHORT).show();
            return;
        }
        selectSeatsButton.setEnabled(false);
        selectSeatsButton.setText("读取座位中");
        executor.execute(() -> {
            try {
                List<TraceintClient.Seat> seats = new TraceintClient(cookie).fetchSeats(roomId);
                seats.removeIf(seat -> seat.type != 1 || seat.name.trim().isEmpty() || seat.key.trim().isEmpty());
                seats.sort(Comparator.comparing(seat -> seat.name, MainActivity::compareSeatNames));
                runOnUiThread(() -> {
                    currentSeats = seats;
                    selectSeatsButton.setEnabled(true);
                    selectSeatsButton.setText("选择优先座位");
                    showSeatPicker();
                });
            } catch (Exception error) {
                runOnUiThread(() -> {
                    selectSeatsButton.setEnabled(true);
                    selectSeatsButton.setText("选择优先座位");
                    Toast.makeText(this, "座位读取失败：" + error.getMessage(), Toast.LENGTH_LONG).show();
                });
            }
        });
    }

    private void showSeatPicker() {
        if (currentSeats.isEmpty()) {
            Toast.makeText(this, "当前阅览室没有可选座位", Toast.LENGTH_SHORT).show();
            return;
        }
        String[] names = currentSeats.stream().map(seat -> seat.name).toArray(String[]::new);
        Set<String> saved = new HashSet<>(AppConfig.selectedSeats(this));
        boolean[] checked = new boolean[names.length];
        for (int i = 0; i < names.length; i++) checked[i] = saved.contains(names[i]);
        new AlertDialog.Builder(this, R.style.GlassDialog)
            .setTitle("选择优先座位")
            .setMultiChoiceItems(names, checked, (dialog, which, isChecked) -> checked[which] = isChecked)
            .setNeutralButton("不限座位", (dialog, which) -> {
                AppConfig.saveSelectedSeats(this, new ArrayList<>());
                renderSeatSummary();
            })
            .setNegativeButton("取消", null)
            .setPositiveButton("保存", (dialog, which) -> {
                List<String> selected = new ArrayList<>();
                for (int i = 0; i < names.length; i++) if (checked[i]) selected.add(names[i]);
                AppConfig.saveSelectedSeats(this, selected);
                renderSeatSummary();
            }).show();
    }

    private void startTask() {
        if (!AppConfig.isLoggedIn(this)) {
            Toast.makeText(this, "请先完成微信链接登录", Toast.LENGTH_SHORT).show();
            focusLoginSetup();
            return;
        }
        int position = roomSpinner.getSelectedItemPosition();
        if (position < 0 || position >= rooms.size()) {
            Toast.makeText(this, "请先读取并选择阅览室", Toast.LENGTH_SHORT).show();
            return;
        }
        String mode = tomorrowMode.isChecked() ? AppConfig.MODE_TOMORROW : AppConfig.MODE_REALTIME;
        String time = tomorrowTime.getText().toString().trim();
        if (AppConfig.MODE_TOMORROW.equals(mode) &&
            !time.matches("([01]\\d|2[0-3]):[0-5]\\d(?::[0-5]\\d)?")) {
            tomorrowTime.setError("请输入 HH:mm 或 HH:mm:ss");
            return;
        }
        if (time.length() == 5) time += ":00";
        TraceintClient.Room room = rooms.get(position);
        preferences.edit()
            .putInt(AppConfig.KEY_ROOM_ID, room.id)
            .putString(AppConfig.KEY_ROOM_NAME, room.name)
            .putString(AppConfig.KEY_MODE, mode)
            .putString(AppConfig.KEY_TIME, time)
            .apply();
        Intent intent = new Intent(this, ReservationService.class);
        intent.setAction(ReservationService.ACTION_START);
        startForegroundService(intent);
    }

    private void showTimePicker() {
        String[] parts = tomorrowTime.getText().toString().trim().split(":");
        Calendar calendar = Calendar.getInstance();
        int hour = clampTimePart(parts.length > 0 ?
            parseTimePart(parts[0], calendar.get(Calendar.HOUR_OF_DAY)) : calendar.get(Calendar.HOUR_OF_DAY), 23);
        int minute = clampTimePart(parts.length > 1 ?
            parseTimePart(parts[1], calendar.get(Calendar.MINUTE)) : calendar.get(Calendar.MINUTE), 59);
        new TimePickerDialog(this, R.style.GlassDialog, (view, selectedHour, selectedMinute) ->
            tomorrowTime.setText(String.format(Locale.CHINA, "%02d:%02d:00", selectedHour, selectedMinute)),
            hour, minute, true).show();
    }

    private static int parseTimePart(String value, int fallback) {
        try {
            return Integer.parseInt(value);
        } catch (NumberFormatException ignored) {
            return fallback;
        }
    }

    private static int clampTimePart(int value, int max) {
        return Math.max(0, Math.min(max, value));
    }

    private void requestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, NOTIFICATION_REQUEST);
        }
    }

    @SuppressLint("UnspecifiedRegisterReceiverFlag")
    @Override protected void onStart() {
        super.onStart();
        if (!receiverRegistered) {
            IntentFilter filter = new IntentFilter(ReservationService.ACTION_STATUS);
            if (Build.VERSION.SDK_INT >= 33) registerReceiver(statusReceiver, filter, Context.RECEIVER_NOT_EXPORTED);
            else registerReceiver(statusReceiver, filter);
            receiverRegistered = true;
        }
        renderState();
    }

    @Override protected void onStop() {
        if (receiverRegistered) {
            unregisterReceiver(statusReceiver);
            receiverRegistered = false;
        }
        super.onStop();
    }

    @Override protected void onDestroy() {
        executor.shutdownNow();
        super.onDestroy();
    }

    private static int compareSeatNames(String left, String right) {
        try {
            int a = Integer.parseInt(left.replaceAll("\\D+", ""));
            int b = Integer.parseInt(right.replaceAll("\\D+", ""));
            int compare = Integer.compare(a, b);
            return compare != 0 ? compare : left.compareTo(right);
        } catch (NumberFormatException ignored) {
            return left.toLowerCase(Locale.CHINA).compareTo(right.toLowerCase(Locale.CHINA));
        }
    }
}
