package com.gotolibrary.app;

import java.net.URI;
import java.net.URISyntaxException;
import java.net.URLDecoder;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

final class WechatSessionCodec {
    static final class SessionRequest {
        final String baseUrl;
        final String authUrl;

        SessionRequest(String baseUrl, String authUrl) {
            this.baseUrl = baseUrl;
            this.authUrl = authUrl;
        }
    }

    private WechatSessionCodec() {}

    static SessionRequest parse(String callbackUrl) {
        String cleanUrl = extractLastCallbackUrl(callbackUrl == null ? "" :
            callbackUrl.trim().replace("\\", ""));
        URI callback;
        try {
            callback = new URI(cleanUrl);
        } catch (URISyntaxException error) {
            throw new IllegalArgumentException("请输入有效的微信回调链接");
        }
        String host = callback.getHost();
        if (host == null || callback.getScheme() == null) {
            throw new IllegalArgumentException("请输入有效的微信回调链接");
        }
        host = host.toLowerCase(Locale.ROOT);
        if (!(host.equals("wechat.v2.traceint.com") || host.equals("web.traceint.com"))) {
            throw new IllegalArgumentException("这不是有效的图书馆微信授权回调链接");
        }

        String baseUrl = "https://" + host + "/";
        Map<String, String> query = queryParameters(callback.getRawQuery());
        String code = query.get("code");
        if (code == null || code.trim().isEmpty()) {
            if (!"https".equalsIgnoreCase(callback.getScheme())) {
                throw new IllegalArgumentException("直接授权链接必须使用 HTTPS");
            }
            return new SessionRequest(baseUrl, callback.toASCIIString());
        }
        String state = query.get("state");
        if (state == null || state.trim().isEmpty()) state = "1";
        String target = "https://" + host;
        String authUrl = target + "/index.php/urlNew/auth.html?r=" +
            formEncode(target + "/web/index.html") + "&code=" + formEncode(code) +
            "&state=" + formEncode(state);
        return new SessionRequest(baseUrl, authUrl);
    }

    private static String extractLastCallbackUrl(String value) {
        String lower = value.toLowerCase(Locale.ROOT);
        int http = lower.lastIndexOf("http://");
        int https = lower.lastIndexOf("https://");
        int start = Math.max(http, https);
        if (start < 0) return value;
        String candidate = value.substring(start).trim();
        int end = candidate.length();
        for (int i = 0; i < candidate.length(); i++) {
            char character = candidate.charAt(i);
            if (Character.isWhitespace(character) || character == '"' || character == '\'' ||
                character == '<' || character == '>') {
                end = i;
                break;
            }
        }
        return candidate.substring(0, end);
    }

    static void mergeSetCookies(Map<String, String> jar, List<String> setCookieHeaders) {
        for (String header : setCookieHeaders) {
            String first = header.split(";", 2)[0].trim();
            int equals = first.indexOf('=');
            if (equals <= 0) continue;
            String name = first.substring(0, equals).trim();
            jar.put(name, first.substring(equals + 1).trim());
        }
    }

    private static Map<String, String> queryParameters(String rawQuery) {
        Map<String, String> values = new LinkedHashMap<>();
        if (rawQuery == null || rawQuery.isEmpty()) return values;
        for (String item : rawQuery.split("&")) {
            int equals = item.indexOf('=');
            String name = equals < 0 ? item : item.substring(0, equals);
            String value = equals < 0 ? "" : item.substring(equals + 1);
            values.put(urlDecode(name), urlDecode(value));
        }
        return values;
    }

    private static String urlDecode(String value) {
        try {
            return URLDecoder.decode(value, StandardCharsets.UTF_8.name());
        } catch (Exception error) {
            throw new IllegalArgumentException("微信回调链接编码无效");
        }
    }

    private static String formEncode(String value) {
        try {
            return URLEncoder.encode(value, StandardCharsets.UTF_8.name());
        } catch (Exception error) {
            throw new IllegalArgumentException("微信回调链接编码失败");
        }
    }
}
