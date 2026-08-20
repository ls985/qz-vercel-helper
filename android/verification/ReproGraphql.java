import okhttp3.MediaType;
import okhttp3.OkHttpClient;
import okhttp3.Protocol;
import okhttp3.Request;
import okhttp3.RequestBody;
import okhttp3.Response;

import java.util.Arrays;
import java.util.Collections;
import java.util.concurrent.TimeUnit;

public final class ReproGraphql {
    static final String GRAPHQL_URL = "https://wechat.v2.traceint.com/index.php/graphql/";
    static final String IPHONE_WECHAT_UA =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Mobile/15E148 MicroMessenger/8.0.49";
    static final String WIN_WECHAT_UA =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) " +
        "Chrome/107.0.0.0 Safari/537.36 NetType/WIFI MicroMessenger/7.0.20.1781 WindowsWechat XWEB/8391";
    static final String QUERY_NL =
        "query list {\\n userAuth {\\n reserve {\\n libs(libType: -1) {\\n lib_id\\n lib_name\\n " +
        "is_open\\n lib_rt {\\n seats_has\\n }\\n }\\n }\\n }\\n}";
    static final String QUERY_SP =
        "query list { userAuth { reserve { libs(libType: -1) { lib_id lib_name " +
        "is_open lib_rt { seats_has } } } } }";

    public static void main(String[] args) throws Exception {
        String variant = args.length > 0 ? args[0] : "app";
        String urlOverride = args.length > 1 ? args[1] : null;
        String query = variant.equals("sp") ? QUERY_SP : QUERY_NL;
        String payload =
            "{\"operationName\":\"list\",\"query\":\"" + query + "\",\"variables\":{}}";
        OkHttpClient.Builder httpBuilder = new OkHttpClient.Builder()
            .connectTimeout(12, TimeUnit.SECONDS).readTimeout(15, TimeUnit.SECONDS);
        if (variant.equals("h2")) {
            httpBuilder.protocols(Arrays.asList(Protocol.HTTP_2, Protocol.HTTP_1_1));
        } else {
            httpBuilder.protocols(Collections.singletonList(Protocol.HTTP_1_1));
        }
        OkHttpClient http = httpBuilder.build();
        Request.Builder builder = new Request.Builder()
            .url(urlOverride != null ? urlOverride : GRAPHQL_URL)
            .post(variant.equals("bytes")
                ? RequestBody.create(payload.getBytes(java.nio.charset.StandardCharsets.UTF_8),
                    MediaType.get("application/json"))
                : RequestBody.create(payload, MediaType.get("application/json")))
            .header("Cookie", "SERVERID=dummy; Authorization=dummy");
        switch (variant) {
            case "app": // v1.3.5 exact replica
                builder.header("Origin", "https://web.traceint.com")
                    .header("Referer", "https://web.traceint.com/")
                    .header("User-Agent", IPHONE_WECHAT_UA)
                    .header("Content-Type", "application/json")
                    .header("App-Version", "2.2.5")
                    .header("app-version", "2.2.5")
                    .header("Accept", "application/json, text/plain, */*");
                break;
            case "sp": // app headers but spaces instead of \n in query
                builder.header("Origin", "https://web.traceint.com")
                    .header("Referer", "https://web.traceint.com/")
                    .header("User-Agent", IPHONE_WECHAT_UA)
                    .header("Content-Type", "application/json")
                    .header("App-Version", "2.2.5")
                    .header("app-version", "2.2.5")
                    .header("Accept", "application/json, text/plain, */*");
                break;
            case "curlish": // only headers my working curl sent
                builder.header("Origin", "https://web.traceint.com")
                    .header("Referer", "https://web.traceint.com/")
                    .header("User-Agent", WIN_WECHAT_UA)
                    .header("Content-Type", "application/json")
                    .header("app-version", "2.2.5")
                    .header("Accept", "*/*");
                break;
            case "nogzip": // app headers + explicit identity encoding
                builder.header("Origin", "https://web.traceint.com")
                    .header("Referer", "https://web.traceint.com/")
                    .header("User-Agent", IPHONE_WECHAT_UA)
                    .header("Content-Type", "application/json")
                    .header("App-Version", "2.2.5")
                    .header("app-version", "2.2.5")
                    .header("Accept", "application/json, text/plain, */*")
                    .header("Accept-Encoding", "identity");
                break;
            case "minimal":
                builder.header("User-Agent", WIN_WECHAT_UA)
                    .header("Content-Type", "application/json");
                break;
            default:
                builder.header("Origin", "https://web.traceint.com")
                    .header("Referer", "https://web.traceint.com/")
                    .header("User-Agent", IPHONE_WECHAT_UA)
                    .header("Content-Type", "application/json")
                    .header("app-version", "2.2.5");
        }
        try (Response response = http.newCall(builder.build()).execute()) {
            String text = response.body() == null ? "" : response.body().string();
            System.out.println("variant=" + variant + " status=" + response.code() +
                " protocol=" + response.protocol() + " bodyLen=" + payload.length());
            System.out.println(text);
        }
    }
}
