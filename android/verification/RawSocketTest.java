import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLSocket;
import javax.net.ssl.SSLSocketFactory;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetAddress;
import java.nio.charset.StandardCharsets;

public final class RawSocketTest {
    public static void main(String[] args) throws Exception {
        String style = args.length > 0 ? args[0] : "plain";
        String host = "wechat.v2.traceint.com";
        String body =
            "{\"operationName\":\"list\",\"query\":\"query list { userAuth { reserve { libs(libType: -1) " +
            "{ lib_id lib_name is_open lib_rt { seats_has } } } } }\",\"variables\":{}}";
        String hostHeader = "Host: " + host + "\r\n";
        String cookie = "Cookie: SERVERID=dummy; Authorization=dummy\r\n";
        String contentType = "Content-Type: application/json\r\n";
        String connection = "Connection: close\r\n";
        String acceptEncoding = "";
        StringBuilder headers = new StringBuilder();
        switch (style) {
            case "hostend":
                headers.append(cookie)
                    .append("Origin: https://web.traceint.com\r\n")
                    .append("Referer: https://web.traceint.com/\r\n")
                    .append("User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/107.0.0.0 Safari/537.36 NetType/WIFI MicroMessenger/7.0.20.1781 WindowsWechat XWEB/8391\r\n")
                    .append("app-version: 2.2.5\r\n")
                    .append("Accept: */*\r\n")
                    .append(contentType)
                    .append("Content-Length: " + body.getBytes(StandardCharsets.UTF_8).length + "\r\n")
                    .append(hostHeader)
                    .append(connection);
                break;
            case "charset":
                contentType = "Content-Type: application/json; charset=utf-8\r\n";
                // fall through to plain
            case "plain":
                headers.append(hostHeader)
                    .append("Origin: https://web.traceint.com\r\n")
                    .append("Referer: https://web.traceint.com/\r\n")
                    .append("User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/107.0.0.0 Safari/537.36 NetType/WIFI MicroMessenger/7.0.20.1781 WindowsWechat XWEB/8391\r\n")
                    .append(cookie)
                    .append(contentType)
                    .append("app-version: 2.2.5\r\n")
                    .append("Accept: */*\r\n")
                    .append("Content-Length: " + body.getBytes(StandardCharsets.UTF_8).length + "\r\n")
                    .append(connection);
                break;
            case "keepalive":
                connection = "Connection: Keep-Alive\r\n";
                headers.append(hostHeader)
                    .append("Origin: https://web.traceint.com\r\n")
                    .append(cookie)
                    .append(contentType)
                    .append("app-version: 2.2.5\r\n")
                    .append("Accept: */*\r\n")
                    .append("Content-Length: " + body.getBytes(StandardCharsets.UTF_8).length + "\r\n")
                    .append(connection);
                break;
            case "gzip":
                acceptEncoding = "Accept-Encoding: gzip\r\n";
                headers.append(hostHeader)
                    .append("Origin: https://web.traceint.com\r\n")
                    .append(cookie)
                    .append(contentType)
                    .append("app-version: 2.2.5\r\n")
                    .append("Accept: */*\r\n")
                    .append(acceptEncoding)
                    .append("Content-Length: " + body.getBytes(StandardCharsets.UTF_8).length + "\r\n")
                    .append(connection);
                break;
            default: // okhttplike: cookie first, charset CT, late Host, KA, gzip
                headers.append(cookie)
                    .append("Origin: https://web.traceint.com\r\n")
                    .append("Referer: https://web.traceint.com/\r\n")
                    .append("User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/107.0.0.0 Safari/537.36 NetType/WIFI MicroMessenger/7.0.20.1781 WindowsWechat XWEB/8391\r\n")
                    .append("app-version: 2.2.5\r\n")
                    .append("Accept: application/json, text/plain, */*\r\n")
                    .append("Content-Type: application/json; charset=utf-8\r\n")
                    .append("Content-Length: " + body.getBytes(StandardCharsets.UTF_8).length + "\r\n")
                    .append(hostHeader)
                    .append("Connection: Keep-Alive\r\n")
                    .append("Accept-Encoding: gzip\r\n");
                break;
        }
        String head =
            "POST /index.php/graphql/ HTTP/1.1\r\n" + headers + "\r\n";
        SSLSocketFactory factory = SSLContext.getDefault().getSocketFactory();
        SSLSocket socket = (SSLSocket) factory.createSocket(InetAddress.getByName(host), 443);
        socket.startHandshake();
        OutputStream out = socket.getOutputStream();
        ByteArrayOutputStream merged = new ByteArrayOutputStream();
        merged.write(head.getBytes(StandardCharsets.UTF_8));
        merged.write(body.getBytes(StandardCharsets.UTF_8));
        out.write(merged.toByteArray());
        out.flush();
        InputStream in = socket.getInputStream();
        ByteArrayOutputStream response = new ByteArrayOutputStream();
        byte[] buffer = new byte[4096];
        int read;
        while ((read = in.read(buffer)) != -1) response.write(buffer, 0, read);
        socket.close();
        String text = response.toString(StandardCharsets.UTF_8.name());
        int bodyStart = text.indexOf("\r\n\r\n");
        String responseBody = bodyStart >= 0 ? text.substring(bodyStart + 4) : text;
        if (responseBody.startsWith("\u001f\u008b")) {
            java.util.zip.GZIPInputStream gzipIn = new java.util.zip.GZIPInputStream(
                new java.io.ByteArrayInputStream(response.toByteArray(), bodyStart + 4, response.size() - bodyStart - 4));
            ByteArrayOutputStream plain = new ByteArrayOutputStream();
            byte[] gzipBuffer = new byte[4096];
            int gzipRead;
            while ((gzipRead = gzipIn.read(gzipBuffer)) != -1) plain.write(gzipBuffer, 0, gzipRead);
            responseBody = plain.toString(StandardCharsets.UTF_8.name());
        }
        System.out.println("style=" + style + " => " +
            (responseBody.contains("<EOF>") ? "FAIL Unexpected <EOF>" : "OK " + responseBody.substring(0, Math.min(120, responseBody.length()))));
    }
}
