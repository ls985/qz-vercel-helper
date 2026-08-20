package com.gotolibrary.app;

import android.content.Context;
import android.content.SharedPreferences;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;

import org.json.JSONArray;

import java.text.SimpleDateFormat;
import java.security.KeyStore;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Date;
import java.util.List;
import java.util.Locale;

import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

final class AppConfig {
    static final String PREFS = "gotolibrary_native";
    static final String KEY_COOKIE = "cookie";
    private static final String KEY_COOKIE_CIPHER = "cookie_cipher";
    private static final String KEY_COOKIE_IV = "cookie_iv";
    private static final String COOKIE_KEY_ALIAS = "gotolibrary_session_key";
    static final String KEY_ROOM_ID = "room_id";
    static final String KEY_ROOM_NAME = "room_name";
    static final String KEY_SEATS = "preferred_seats";
    static final String KEY_MODE = "mode";
    static final String KEY_TIME = "tomorrow_time";
    static final String KEY_RUNNING = "running";
    static final String KEY_STATUS_TITLE = "status_title";
    static final String KEY_STATUS_DETAIL = "status_detail";
    static final String KEY_LOGS = "logs";

    static final String MODE_REALTIME = "realtime";
    static final String MODE_TOMORROW = "tomorrow";

    private AppConfig() {}

    static SharedPreferences prefs(Context context) {
        return context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    static boolean isLoggedIn(Context context) {
        return !getCookie(context).trim().isEmpty();
    }

    static synchronized String getCookie(Context context) {
        SharedPreferences preferences = prefs(context);
        String encrypted = preferences.getString(KEY_COOKIE_CIPHER, "");
        String encodedIv = preferences.getString(KEY_COOKIE_IV, "");
        if (encrypted != null && !encrypted.isEmpty() && encodedIv != null && !encodedIv.isEmpty()) {
            try {
                Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
                cipher.init(Cipher.DECRYPT_MODE, getOrCreateCookieKey(),
                    new GCMParameterSpec(128, Base64.decode(encodedIv, Base64.NO_WRAP)));
                return new String(cipher.doFinal(Base64.decode(encrypted, Base64.NO_WRAP)),
                    java.nio.charset.StandardCharsets.UTF_8);
            } catch (Exception ignored) {
                clearCookie(context);
                return "";
            }
        }
        String legacy = preferences.getString(KEY_COOKIE, "");
        if (legacy != null && !legacy.trim().isEmpty()) {
            return setCookie(context, legacy) ? legacy : "";
        }
        return "";
    }

    static synchronized boolean setCookie(Context context, String cookie) {
        if (cookie == null || cookie.trim().isEmpty()) {
            clearCookie(context);
            return true;
        }
        try {
            Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
            cipher.init(Cipher.ENCRYPT_MODE, getOrCreateCookieKey());
            byte[] encrypted = cipher.doFinal(cookie.getBytes(java.nio.charset.StandardCharsets.UTF_8));
            prefs(context).edit()
                .putString(KEY_COOKIE_CIPHER, Base64.encodeToString(encrypted, Base64.NO_WRAP))
                .putString(KEY_COOKIE_IV, Base64.encodeToString(cipher.getIV(), Base64.NO_WRAP))
                .remove(KEY_COOKIE)
                .apply();
            return true;
        } catch (Exception ignored) {
            clearCookie(context);
            return false;
        }
    }

    static void clearCookie(Context context) {
        prefs(context).edit()
            .remove(KEY_COOKIE)
            .remove(KEY_COOKIE_CIPHER)
            .remove(KEY_COOKIE_IV)
            .apply();
    }

    static List<String> selectedSeats(Context context) {
        String raw = prefs(context).getString(KEY_SEATS, "");
        if (raw == null || raw.trim().isEmpty()) return new ArrayList<>();
        try {
            JSONArray values = new JSONArray(raw);
            List<String> seats = new ArrayList<>();
            for (int i = 0; i < values.length(); i++) {
                String value = values.optString(i).trim();
                if (!value.isEmpty()) seats.add(value);
            }
            return seats;
        } catch (Exception ignored) {
            List<String> seats = new ArrayList<>(Arrays.asList(raw.split("\\|", -1)));
            seats.removeIf(String::isEmpty);
            saveSelectedSeats(context, seats);
            return seats;
        }
    }

    static void saveSelectedSeats(Context context, List<String> seats) {
        JSONArray values = new JSONArray();
        for (String seat : seats) {
            if (seat != null && !seat.trim().isEmpty()) values.put(seat);
        }
        prefs(context).edit().putString(KEY_SEATS, values.toString()).apply();
    }

    static synchronized void addLog(Context context, String message) {
        SharedPreferences preferences = prefs(context);
        JSONArray logs;
        try {
            logs = new JSONArray(preferences.getString(KEY_LOGS, "[]"));
        } catch (Exception ignored) {
            logs = new JSONArray();
        }
        JSONArray next = new JSONArray();
        String time = new SimpleDateFormat("HH:mm:ss", Locale.CHINA).format(new Date());
        next.put(time + "  " + message);
        for (int i = 0; i < logs.length() && i < 39; i++) next.put(logs.optString(i));
        preferences.edit().putString(KEY_LOGS, next.toString()).apply();
    }

    static String logsText(Context context) {
        try {
            JSONArray logs = new JSONArray(prefs(context).getString(KEY_LOGS, "[]"));
            if (logs.length() == 0) return "暂无运行记录";
            StringBuilder text = new StringBuilder();
            for (int i = 0; i < logs.length(); i++) {
                if (i > 0) text.append('\n');
                text.append(logs.optString(i));
            }
            return text.toString();
        } catch (Exception ignored) {
            return "暂无运行记录";
        }
    }

    private static SecretKey getOrCreateCookieKey() throws Exception {
        KeyStore keyStore = KeyStore.getInstance("AndroidKeyStore");
        keyStore.load(null);
        if (!keyStore.containsAlias(COOKIE_KEY_ALIAS)) {
            KeyGenerator generator = KeyGenerator.getInstance(
                KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
            generator.init(new KeyGenParameterSpec.Builder(
                COOKIE_KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build());
            generator.generateKey();
        }
        return ((KeyStore.SecretKeyEntry) keyStore.getEntry(COOKIE_KEY_ALIAS, null)).getSecretKey();
    }
}
