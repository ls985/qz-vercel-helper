package com.gotolibrary.app;

import android.graphics.Canvas;
import android.graphics.ColorFilter;
import android.graphics.LinearGradient;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.PixelFormat;
import android.graphics.RectF;
import android.graphics.Shader;
import android.graphics.drawable.Drawable;

/**
 * Liquid-glass card surface: translucent fill, gradient border that fades from
 * bright (top-left) to faint (bottom-right), and a specular highlight line hugging
 * the top edge. Shaders are rebuilt only when bounds change so animated backdrops
 * can drive repaints without per-frame allocation.
 */
public final class GlassPanelDrawable extends Drawable {
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final Path path = new Path();
    private final RectF rect = new RectF();
    private final int fillColor;
    private final int strokeHigh;
    private final int strokeLow;
    private final float radius;
    private final float strokeWidth;

    private Shader borderShader;
    private Shader specularShader;
    private float specularEnd;

    public GlassPanelDrawable(int fillColor, int strokeHigh, int strokeLow,
        float radiusPx, float strokeWidthPx) {
        this.fillColor = fillColor;
        this.strokeHigh = strokeHigh;
        this.strokeLow = strokeLow;
        this.radius = radiusPx;
        this.strokeWidth = strokeWidthPx;
    }

    @Override protected void onBoundsChange(android.graphics.Rect bounds) {
        if (bounds.isEmpty()) return;
        rect.set(bounds);
        path.reset();
        path.addRoundRect(rect, radius, radius, Path.Direction.CW);
        borderShader = new LinearGradient(
            rect.left, rect.top, rect.right, rect.bottom,
            strokeHigh, strokeLow, Shader.TileMode.CLAMP);
        specularEnd = Math.max(radius * 1.4f, strokeWidth * 10f);
        specularShader = new LinearGradient(
            0, rect.top, 0, rect.top + specularEnd,
            0x99FFFFFF, 0x00000000, Shader.TileMode.CLAMP);
        invalidateSelf();
    }

    @Override public void draw(Canvas canvas) {
        if (rect.isEmpty() || borderShader == null) return;
        paint.setStyle(Paint.Style.FILL);
        paint.setShader(null);
        paint.setColor(fillColor);
        canvas.drawPath(path, paint);

        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeWidth(strokeWidth);
        paint.setShader(borderShader);
        canvas.drawPath(path, paint);

        if (specularShader != null) {
            paint.setShader(specularShader);
            paint.setStrokeWidth(strokeWidth * 1.6f);
            canvas.drawLine(rect.left + radius * .9f, rect.top + strokeWidth,
                rect.right - radius * .9f, rect.top + strokeWidth, paint);
        }
        paint.setShader(null);
        paint.setStyle(Paint.Style.FILL);
    }

    @Override public void setAlpha(int alpha) {
        paint.setAlpha(alpha);
        invalidateSelf();
    }

    @Override public void setColorFilter(ColorFilter colorFilter) {
        paint.setColorFilter(colorFilter);
        invalidateSelf();
    }

    @Override public int getOpacity() {
        return PixelFormat.TRANSLUCENT;
    }
}
