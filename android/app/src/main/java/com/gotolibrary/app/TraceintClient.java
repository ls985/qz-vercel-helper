package com.gotolibrary.app;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import android.util.Log;

import java.io.IOException;
import java.net.URLDecoder;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;

import okhttp3.MediaType;
import okhttp3.OkHttpClient;
import okhttp3.Protocol;
import okhttp3.Request;
import okhttp3.RequestBody;
import okhttp3.Response;
import okhttp3.WebSocket;
import okhttp3.WebSocketListener;

final class TraceintClient {
    private static final String LOG_TAG = "GoToLibraryNet";
    static final String GRAPHQL_URL = "https://wechat.v2.traceint.com/index.php/graphql/";
    static final String LOGIN_URL =
        "https://open.weixin.qq.com/connect/oauth2/authorize?appid=wx2996d437cd442527" +
        "&redirect_uri=https%3A%2F%2Fwechat.v2.traceint.com%2Findex.php%2Fgraphql" +
        "&response_type=code&scope=snsapi_userinfo&state=1#wechat_redirect";

    private static final String DESKTOP_WECHAT_UA =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
        "(KHTML, like Gecko) Chrome/107.0.0.0 Safari/537.36 NetType/WIFI " +
        "MicroMessenger/7.0.20.1781(0x6700143B) WindowsWechat(0x63090719) XWEB/8391 Flue";
    private static final String SESSION_EXCHANGE_UA =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) " +
        "Chrome/107.0.0.0 Safari/537.36 NetType/WIFI MicroMessenger/7.0.20.1781 WindowsWechat XWEB/8391";
    private static final String IPHONE_WECHAT_UA =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Mobile/15E148 MicroMessenger/8.0.49";
    private static final MediaType JSON = MediaType.get("application/json");

    private final OkHttpClient http = new OkHttpClient.Builder()
        .protocols(Collections.singletonList(Protocol.HTTP_1_1))
        .connectTimeout(12, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS)
        .writeTimeout(15, TimeUnit.SECONDS)
        .build();
    private String cookie;
    private int authorizationMode;

    TraceintClient(String cookie) {
        this.cookie = normalizeCookieHeader(cookie);
    }

    static final class Room {
        final int id;
        final String name;
        final int available;
        final boolean open;

        Room(int id, String name, int available, boolean open) {
            this.id = id;
            this.name = name;
            this.available = available;
            this.open = open;
        }

        @Override public String toString() {
            return name + (available > 0 ? "  · 余 " + available : "");
        }
    }

    static final class Seat {
        final String key;
        final String name;
        final int type;
        final Object status;
        final Integer seatStatus;

        Seat(String key, String name, int type, Object status, Integer seatStatus) {
            this.key = key;
            this.name = name;
            this.type = type;
            this.status = status;
            this.seatStatus = seatStatus;
        }
    }

    static final class TomorrowAvailability {
        final boolean ready;
        final Integer available;
        final List<Seat> seats;

        TomorrowAvailability(boolean ready, Integer available, List<Seat> seats) {
            this.ready = ready;
            this.available = available;
            this.seats = seats;
        }
    }

    static final class QueueResult {
        final boolean shouldStop;
        final String message;

        QueueResult(boolean shouldStop, String message) {
            this.shouldStop = shouldStop;
            this.message = message;
        }
    }

    static final class ApiException extends IOException {
        ApiException(String message) {
            super(message);
        }
    }

    List<Room> fetchRooms() throws IOException, JSONException {
        JSONObject result = graphql("list",
            "query list {\n userAuth {\n reserve {\n libs(libType: -1) {\n lib_id\n lib_name\n " +
            "is_open\n lib_rt {\n seats_has\n }\n }\n }\n }\n}",
            new JSONObject(), false);
        JSONArray values = result.getJSONObject("data").getJSONObject("userAuth")
            .getJSONObject("reserve").getJSONArray("libs");
        List<Room> rooms = new ArrayList<>();
        for (int i = 0; i < values.length(); i++) {
            JSONObject room = values.getJSONObject(i);
            rooms.add(new Room(
                room.optInt("lib_id"),
                room.optString("lib_name", "阅览室 " + room.optInt("lib_id")),
                room.optJSONObject("lib_rt") == null ? 0 : room.optJSONObject("lib_rt").optInt("seats_has"),
                room.optBoolean("is_open")
            ));
        }
        return rooms;
    }

    List<Seat> fetchSeats(int roomId) throws IOException, JSONException {
        JSONObject variables = new JSONObject().put("libId", roomId).put("libType", -1);
        JSONObject result = graphql("libLayout",
            "query libLayout($libId: Int, $libType: Int) { userAuth { reserve { " +
            "libs(libType: $libType, libId: $libId) { lib_id lib_name lib_floor is_open " +
            "lib_layout { seats_total seats_booking seats_used seats { key name type status seat_status x y } } } } } }",
            variables, false);
        JSONArray libraries = result.getJSONObject("data").getJSONObject("userAuth")
            .getJSONObject("reserve").getJSONArray("libs");
        JSONObject selected = libraries.length() == 0 ? null : libraries.getJSONObject(0);
        for (int i = 0; i < libraries.length(); i++) {
            if (libraries.getJSONObject(i).optInt("lib_id") == roomId) selected = libraries.getJSONObject(i);
        }
        if (selected == null || selected.optJSONObject("lib_layout") == null) return new ArrayList<>();
        return parseSeats(selected.getJSONObject("lib_layout").optJSONArray("seats"));
    }

    boolean reserveSeat(int roomId, Seat seat) throws IOException, JSONException {
        List<String> fields = Arrays.asList("reserueSeat", "reserveSeat");
        ApiException last = null;
        for (String field : fields) {
            JSONObject variables = new JSONObject()
                .put("libId", roomId).put("seatKey", seat.key)
                .put("captchaCode", "").put("captcha", "");
            String query = "mutation " + field + "($libId: Int!, $seatKey: String!, " +
                "$captchaCode: String, $captcha: String!) { userAuth { reserve { " +
                field + "(libId: $libId, seatKey: $seatKey, captchaCode: $captchaCode, captcha: $captcha) } } }";
            try {
                JSONObject result = graphql(field, query, variables, false);
                Object value = result.getJSONObject("data").getJSONObject("userAuth")
                    .getJSONObject("reserve").opt(field);
                return explicitSuccess(value);
            } catch (ApiException error) {
                last = error;
                if (!error.getMessage().toLowerCase(Locale.ROOT).contains("field")) throw error;
            }
        }
        throw last == null ? new ApiException("预约接口没有返回结果") : last;
    }

    TomorrowAvailability fetchTomorrowAvailability(int roomId, boolean includeSeats)
        throws IOException, JSONException {
        String seatFields = includeSeats ? " seats { key name type status seat_status x y }" : "";
        JSONObject result = graphql("libLayout",
            "query libLayout($libId: Int!) { userAuth { prereserve { libLayout(libId: $libId) " +
            "{ seats_booking seats_total seats_used" + seatFields + " } } } }",
            new JSONObject().put("libId", roomId), true);
        JSONObject layout = result.getJSONObject("data").getJSONObject("userAuth")
            .getJSONObject("prereserve").optJSONObject("libLayout");
        if (layout == null) return new TomorrowAvailability(false, null, new ArrayList<>());
        int available = Math.max(0, layout.optInt("seats_total") - layout.optInt("seats_used") -
            layout.optInt("seats_booking"));
        return new TomorrowAvailability(true, available, parseSeats(layout.optJSONArray("seats")));
    }

    boolean reserveTomorrow(int roomId, Seat seat) throws IOException, JSONException {
        String key = seat.key.endsWith(".") ? seat.key : seat.key + ".";
        JSONObject variables = new JSONObject()
            .put("key", key).put("libid", roomId).put("captchaCode", "").put("captcha", "");
        JSONObject result = graphql("save",
            "mutation save($key: String!, $libid: Int!, $captchaCode: String, $captcha: String) " +
            "{ userAuth { prereserve { save(key: $key, libId: $libid, captcha: $captcha, " +
            "captchaCode: $captchaCode) } } }", variables, true);
        Object value = result.getJSONObject("data").getJSONObject("userAuth")
            .getJSONObject("prereserve").opt("save");
        return explicitSuccess(value);
    }

    boolean verifyTomorrow(int roomId, Seat seat) throws IOException, JSONException {
        JSONObject result = graphql("prereserve",
            "query prereserve { userAuth { prereserve { prereserve { day lib_id seat_key seat_name is_used } } } }",
            new JSONObject(), true);
        JSONObject record = result.getJSONObject("data").getJSONObject("userAuth")
            .getJSONObject("prereserve").optJSONObject("prereserve");
        if (record == null || record.optInt("lib_id") != roomId) return false;
        return trimDot(record.optString("seat_key")).equals(trimDot(seat.key));
    }

    QueueResult enterTomorrowQueue() throws InterruptedException {
        CountDownLatch done = new CountDownLatch(1);
        AtomicBoolean settled = new AtomicBoolean(false);
        AtomicReference<QueueResult> result = new AtomicReference<>(
            new QueueResult(false, "排队通道未明确拦截，继续预约"));
        ScheduledExecutorService sender = Executors.newSingleThreadScheduledExecutor();
        Request request = new Request.Builder()
            .url("wss://wechat.v2.traceint.com/ws?ns=prereserve/queue")
            .header("Cookie", cookie)
            .header("Origin", "https://web.traceint.com")
            .header("User-Agent", DESKTOP_WECHAT_UA)
            .build();
        AtomicReference<WebSocket> socketRef = new AtomicReference<>();
        WebSocket socket = http.newWebSocket(request, new WebSocketListener() {
            private void finish(QueueResult queueResult) {
                if (!settled.compareAndSet(false, true)) return;
                result.set(queueResult);
                done.countDown();
            }

            @Override public void onOpen(WebSocket webSocket, Response response) {
                sender.scheduleWithFixedDelay(
                    () -> webSocket.send("{\"ns\":\"prereserve/queue\",\"msg\":\"\"}"),
                    0, 1, TimeUnit.SECONDS);
            }

            @Override public void onMessage(WebSocket webSocket, String text) {
                String normalized = text.toLowerCase(Locale.ROOT);
                if (containsAny(normalized, "不在", "未开始", "结束", "已闭馆", "登记了", "已登记")) {
                    finish(new QueueResult(true, text));
                } else if (containsAny(normalized, "ok", "排队成功", "您已经预定了座位", "不需要排队")) {
                    finish(new QueueResult(false, text));
                }
            }

            @Override public void onFailure(WebSocket webSocket, Throwable error, Response response) {
                finish(new QueueResult(false, "排队通道连接异常，继续预约"));
            }
        });
        socketRef.set(socket);
        done.await(8, TimeUnit.SECONDS);
        settled.set(true);
        sender.shutdownNow();
        socket.close(1000, "done");
        return result.get();
    }

    static String exchangeCallbackForCookie(String callbackUrl) throws IOException {
        WechatSessionCodec.SessionRequest sessionRequest;
        try {
            sessionRequest = WechatSessionCodec.parse(callbackUrl);
        } catch (IllegalArgumentException error) {
            throw new ApiException(error.getMessage());
        }
        OkHttpClient client = new OkHttpClient.Builder()
            .followRedirects(false).followSslRedirects(false)
            .connectTimeout(10, TimeUnit.SECONDS).readTimeout(10, TimeUnit.SECONDS).build();
        Map<String, String> jar = new LinkedHashMap<>();
        followWithCookies(client, sessionRequest.baseUrl, jar, 0);
        followWithCookies(client, sessionRequest.authUrl, jar, 6);
        Log.d(LOG_TAG, "Session exchange complete; cookies=" + String.join(",", jar.keySet()));
        boolean hasSession = false;
        for (Map.Entry<String, String> entry : jar.entrySet()) {
            if (!entry.getKey().equalsIgnoreCase("SERVERID") && !entry.getValue().trim().isEmpty()) {
                hasSession = true;
                break;
            }
        }
        if (!hasSession) throw new ApiException("微信授权已失效，请重新获取回调链接");
        StringBuilder cookie = new StringBuilder();
        for (Map.Entry<String, String> entry : jar.entrySet()) {
            if (cookie.length() > 0) cookie.append("; ");
            cookie.append(entry.getKey()).append('=').append(entry.getValue());
        }
        return cookie.toString();
    }

    private JSONObject graphql(String operation, String query, JSONObject variables, boolean tomorrow)
        throws IOException, JSONException {
        ApiException last = null;
        for (int mode : new int[]{0, 1, 2, 3}) {
            authorizationMode = mode;
            try {
                return graphqlOnce(operation, query, variables, tomorrow);
            } catch (ApiException error) {
                last = error;
                if (!error.getMessage().contains("Unexpected <EOF>")) throw error;
            }
        }
        throw last == null ? new ApiException("图书馆接口认证失败") : last;
    }

    private JSONObject graphqlOnce(String operation, String query, JSONObject variables, boolean tomorrow)
        throws IOException, JSONException {
        if (cookie.trim().isEmpty()) throw new ApiException("登录已失效，请重新登录");
        int braces = 0;
        for (int i = 0; i < query.length(); i++) {
            char value = query.charAt(i);
            if (value == '{') braces++;
            if (value == '}') braces--;
            if (braces < 0) break;
        }
        if (braces != 0) {
            Log.e(LOG_TAG, "GraphQL " + operation + " has unbalanced braces: " + braces);
            throw new ApiException("应用请求结构异常，请更新应用");
        }
        JSONObject payload = new JSONObject()
            .put("operationName", operation).put("query", query).put("variables", variables);
        String payloadText = payload.toString();
        Log.d(LOG_TAG, "GraphQL " + operation + " requestBytes=" +
            payloadText.getBytes(java.nio.charset.StandardCharsets.UTF_8).length + " query=" + query);
        // 必须用 byte[] 构造请求体：OkHttp 的 String 重载会给 Content-Type 追加
        // "; charset=utf-8"，而上游只对精确的 "application/json" 解析请求体，
        // 收到带 charset 的类型会把 body 当空处理并返回 "Unexpected <EOF>"。
        Request.Builder builder = new Request.Builder()
            .url(GRAPHQL_URL)
            .post(RequestBody.create(
                payloadText.getBytes(java.nio.charset.StandardCharsets.UTF_8), JSON))
            .header("Origin", "https://web.traceint.com")
            .header("Referer", "https://web.traceint.com/")
            .header("User-Agent", tomorrow ? DESKTOP_WECHAT_UA : IPHONE_WECHAT_UA)
            .header("Cookie", cookie)
            .header("Content-Type", "application/json")
            .header("App-Version", "2.2.5")
            .header("app-version", "2.2.5")
            .header("Accept", "application/json, text/plain, */*");
        String authorization = cookieValue(cookie, "Authorization");
        if (!authorization.isEmpty() && authorizationMode > 0) {
            String decoded = decodeCookieValue(authorization);
            String header = authorizationMode == 1 ? authorization : decoded;
            if (authorizationMode == 3 && !decoded.regionMatches(true, 0, "Bearer ", 0, 7)) {
                header = "Bearer " + decoded;
            }
            builder.header("Authorization", header);
        }
        Log.d(LOG_TAG, "GraphQL " + operation + " authorizationMode=" + authorizationMode);
        try (Response response = http.newCall(builder.build()).execute()) {
            String text = response.body() == null ? "" : response.body().string();
            Log.d(LOG_TAG, "GraphQL " + operation + " status=" + response.code() +
                " protocol=" + response.protocol() +
                " contentType=" + response.header("Content-Type", ""));
            if (!text.isEmpty() && (response.code() >= 400 || text.contains("\"errors\""))) {
                Log.d(LOG_TAG, "GraphQL " + operation + " response=" + text);
            }
            if (!response.isSuccessful()) throw new ApiException("图书馆接口 HTTP " + response.code());
            JSONObject json;
            try {
                json = new JSONObject(text);
            } catch (JSONException error) {
                throw new ApiException("图书馆接口返回了非 JSON 数据（HTTP " + response.code() +
                    "）：" + snippet(text, 120));
            }
            JSONArray errors = json.optJSONArray("errors");
            if (errors != null && errors.length() > 0) {
                StringBuilder message = new StringBuilder();
                for (int i = 0; i < errors.length(); i++) {
                    JSONObject item = errors.optJSONObject(i);
                    if (i > 0) message.append("；");
                    message.append(item == null ? errors.optString(i)
                        : item.optString("message", item.optString("msg", item.toString())));
                }
                throw new ApiException(message.toString());
            }
            return json;
        }
    }

    static boolean isRiskMessage(String message) {
        return message != null && message.matches(
            "(?is).*(频繁|过快|封禁|限制|风控|验证码|captcha|access denied|denied|非法|黑名单).*");
    }

    static boolean isSessionExpired(String message) {
        return message != null && message.matches(
            "(?is).*(登录.*(过期|失效|超时)|会话.*(过期|失效)|authorization.*(expired|invalid)|未登录).*");
    }

    static boolean isFree(Seat seat) {
        if (seat.type != 1 || seat.key.trim().isEmpty() || seat.name.trim().isEmpty()) return false;
        if (seat.seatStatus != null) return seat.seatStatus == 1;
        if (seat.status instanceof Boolean) return !((Boolean) seat.status);
        if (seat.status instanceof Number) return ((Number) seat.status).intValue() == 0;
        String value = String.valueOf(seat.status).trim().toLowerCase(Locale.ROOT);
        return Arrays.asList("0", "false", "free", "available", "empty", "空闲", "可选").contains(value);
    }

    static List<Seat> orderCandidates(List<Seat> seats, List<String> preferred, boolean freeOnly) {
        List<Seat> result = new ArrayList<>();
        for (Seat seat : seats) {
            if ((!freeOnly || isFree(seat)) &&
                (preferred.isEmpty() || preferred.contains(seat.name) || preferred.contains(seat.key))) {
                result.add(seat);
            }
        }
        if (preferred.isEmpty()) {
            Collections.shuffle(result);
            return result;
        }
        result.sort(Comparator.comparingInt(seat -> {
            int byName = preferred.indexOf(seat.name);
            int byKey = preferred.indexOf(seat.key);
            int index = byName >= 0 ? byName : byKey;
            return index < 0 ? Integer.MAX_VALUE : index;
        }));
        return result;
    }

    private static List<Seat> parseSeats(JSONArray values) {
        List<Seat> seats = new ArrayList<>();
        if (values == null) return seats;
        for (int i = 0; i < values.length(); i++) {
            JSONObject item = values.optJSONObject(i);
            if (item == null) continue;
            Object rawStatus = item.opt("status");
            Integer seatStatus = item.isNull("seat_status") ? null : item.optInt("seat_status");
            seats.add(new Seat(item.optString("key"), item.optString("name"),
                item.optInt("type"), rawStatus, seatStatus));
        }
        return seats;
    }

    private static boolean explicitSuccess(Object value) {
        if (value instanceof Boolean) return (Boolean) value;
        if (value instanceof JSONObject) {
            JSONObject object = (JSONObject) value;
            return object.optBoolean("success") || object.optBoolean("status") ||
                (object.has("code") && object.optInt("code", -1) == 0);
        }
        String text = String.valueOf(value).trim().toLowerCase(Locale.ROOT);
        if (text.matches(".*(失败|错误|不可|已满|取消|拒绝|不成功|未成功|false|fail|error|denied).*")) return false;
        return text.matches(".*(成功|已预约|已经预约|已预定|已经预定).*") ||
            text.matches("^(ok|true|1)$");
    }

    private static void followWithCookies(OkHttpClient client, String url,
        Map<String, String> jar, int redirectsLeft) throws IOException {
        StringBuilder cookies = new StringBuilder();
        for (Map.Entry<String, String> entry : jar.entrySet()) {
            if (cookies.length() > 0) cookies.append("; ");
            cookies.append(entry.getKey()).append('=').append(entry.getValue());
        }
        Request request = new Request.Builder().url(url).get()
            .header("User-Agent", SESSION_EXCHANGE_UA)
            .header("Accept", "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
            .header("Cookie", cookies.toString())
            .header("Referer", "https://web.traceint.com/web/index.html")
            .build();
        String nextUrl = null;
        try (Response response = client.newCall(request).execute()) {
            WechatSessionCodec.mergeSetCookies(jar, response.headers("Set-Cookie"));
            Log.d(LOG_TAG, "Session GET host=" + response.request().url().host() +
                " path=" + response.request().url().encodedPath() + " status=" + response.code() +
                " cookies=" + String.join(",", jar.keySet()));
            String location = response.header("Location");
            int status = response.code();
            if (redirectsLeft > 0 && location != null &&
                (status == 301 || status == 302 || status == 303 || status == 307 || status == 308)) {
                okhttp3.HttpUrl resolved = response.request().url().resolve(location);
                if (resolved == null ||
                    !(resolved.host().equals("wechat.v2.traceint.com") || resolved.host().equals("web.traceint.com"))) {
                    throw new ApiException("授权跳转到了非图书馆地址");
                }
                nextUrl = resolved.toString();
            }
        }
        if (nextUrl != null) followWithCookies(client, nextUrl, jar, redirectsLeft - 1);
    }

    private static String trimDot(String value) {
        return value != null && value.endsWith(".") ? value.substring(0, value.length() - 1) : String.valueOf(value);
    }

    private static String normalizeCookieHeader(String rawCookie) {
        if (rawCookie == null || rawCookie.trim().isEmpty()) return "";
        Map<String, String> values = new LinkedHashMap<>();
        for (String part : rawCookie.split(";")) {
            String item = part.trim();
            int separator = item.indexOf('=');
            if (separator <= 0) continue;
            String name = item.substring(0, separator).trim();
            String value = item.substring(separator + 1).trim();
            if (name.isEmpty() || value.isEmpty()) continue;
            boolean replaced = false;
            for (Map.Entry<String, String> entry : values.entrySet()) {
                if (entry.getKey().equalsIgnoreCase(name)) {
                    entry.setValue(value);
                    replaced = true;
                    break;
                }
            }
            if (!replaced) values.put(name, value);
        }
        List<String> entries = new ArrayList<>();
        for (Map.Entry<String, String> entry : values.entrySet()) {
            entries.add(entry.getKey() + "=" + entry.getValue());
        }
        return String.join("; ", entries);
    }

    private static String cookieValue(String cookieHeader, String name) {
        for (String part : cookieHeader.split(";")) {
            String item = part.trim();
            int separator = item.indexOf('=');
            if (separator > 0 && item.substring(0, separator).trim().equalsIgnoreCase(name)) {
                return item.substring(separator + 1).trim();
            }
        }
        return "";
    }

    private static String decodeCookieValue(String value) {
        try {
            return URLDecoder.decode(value, java.nio.charset.StandardCharsets.UTF_8.name()).trim();
        } catch (Exception ignored) {
            return value;
        }
    }

    private static boolean containsAny(String value, String... needles) {
        for (String needle : needles) if (value.contains(needle.toLowerCase(Locale.ROOT))) return true;
        return false;
    }

    static String cookieNames(String cookieHeader) {
        List<String> names = new ArrayList<>();
        if (cookieHeader != null) {
            for (String part : cookieHeader.split(";")) {
                String item = part.trim();
                int separator = item.indexOf('=');
                if (separator > 0) names.add(item.substring(0, separator).trim());
            }
        }
        return names.isEmpty() ? "（无）" : String.join("、", names);
    }

    private static String snippet(String text, int limit) {
        if (text == null || text.trim().isEmpty()) return "（空响应）";
        String compact = text.replaceAll("\\s+", " ").trim();
        return compact.length() <= limit ? compact : compact.substring(0, limit) + "…";
    }
}
