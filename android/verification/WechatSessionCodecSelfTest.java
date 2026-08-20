package com.gotolibrary.app;

import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.Map;

public final class WechatSessionCodecSelfTest {
    public static void main(String[] args) {
        buildsAuthUrlFromCodeCallback();
        acceptsDirectAuthorizationUrlWithoutCode();
        acceptsWechatEscapedCallback();
        acceptsHttpCodeCallbackUsedByWebsite();
        extractsLatestCallbackFromPastedHistory();
        rejectsNonTraceintHosts();
        mergesCookiesLikeWebsite();
        System.out.println("WechatSessionCodec self-test passed: 7/7");
    }

    private static void buildsAuthUrlFromCodeCallback() {
        WechatSessionCodec.SessionRequest request = WechatSessionCodec.parse(
            "https://wechat.v2.traceint.com/index.php/graphql?code=CODE_VALUE&state=STATE_VALUE");
        equal("https://wechat.v2.traceint.com/", request.baseUrl);
        equal(
            "https://wechat.v2.traceint.com/index.php/urlNew/auth.html" +
                "?r=https%3A%2F%2Fwechat.v2.traceint.com%2Fweb%2Findex.html" +
                "&code=CODE_VALUE&state=STATE_VALUE",
            request.authUrl);
    }

    private static void acceptsDirectAuthorizationUrlWithoutCode() {
        String direct = "https://wechat.v2.traceint.com/index.php/urlNew/auth.html?ticket=TICKET_VALUE";
        equal(direct, WechatSessionCodec.parse(direct).authUrl);
    }

    private static void acceptsWechatEscapedCallback() {
        WechatSessionCodec.SessionRequest request = WechatSessionCodec.parse(
            "https:\\/\\/web.traceint.com\\/index.php\\/graphql?code=ABC&state=1");
        equal("https://web.traceint.com/", request.baseUrl);
        check(request.authUrl.contains("code=ABC"), "escaped callback code was lost");
    }

    private static void acceptsHttpCodeCallbackUsedByWebsite() {
        WechatSessionCodec.SessionRequest request = WechatSessionCodec.parse(
            "http://wechat.v2.traceint.com/index.php/graphql?code=HTTP_CALLBACK&state=1");
        check(request.authUrl.startsWith("https://wechat.v2.traceint.com/"),
            "HTTP callback was not upgraded to HTTPS authentication");
        check(request.authUrl.contains("code=HTTP_CALLBACK"), "HTTP callback code was lost");
    }

    private static void extractsLatestCallbackFromPastedHistory() {
        WechatSessionCodec.SessionRequest request = WechatSessionCodec.parse(
            "http://wechat.v2.traceint.com/index.php/graphql?code=OLD&state=1" +
            "http://wechat.v2.traceint.com/index.php/graphql?code=LATEST&state=1");
        check(request.authUrl.contains("code=LATEST"), "latest pasted callback was not selected");
        check(!request.authUrl.contains("code=OLD"), "stale pasted callback was selected");
    }

    private static void rejectsNonTraceintHosts() {
        try {
            WechatSessionCodec.parse("https://example.com/?code=ABC");
            throw new AssertionError("non-Traceint host was accepted");
        } catch (IllegalArgumentException expected) {
            check(expected.getMessage().contains("图书馆"), "unexpected rejection message");
        }
    }

    private static void mergesCookiesLikeWebsite() {
        Map<String, String> jar = new LinkedHashMap<>();
        WechatSessionCodec.mergeSetCookies(jar, Arrays.asList(
            "wechatSESS_ID=first; Path=/; HttpOnly", "SERVERID=server-a; Path=/"));
        WechatSessionCodec.mergeSetCookies(jar, Arrays.asList(
            "Authorization=token; Path=/", "SERVERID=server-b; Path=/"));
        equal("first", jar.get("wechatSESS_ID"));
        equal("token", jar.get("Authorization"));
        equal("server-b", jar.get("SERVERID"));
    }

    private static void equal(String expected, String actual) {
        if (!expected.equals(actual)) {
            throw new AssertionError("expected <" + expected + "> but was <" + actual + ">");
        }
    }

    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
}
