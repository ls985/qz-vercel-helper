package com.gotolibrary.app;

import android.animation.ValueAnimator;
import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.LinearGradient;
import android.graphics.Paint;
import android.graphics.RadialGradient;
import android.graphics.Shader;
import android.util.AttributeSet;
import android.view.View;
import android.view.animation.LinearInterpolator;

/**
 * Liquid-glass backdrop: deep green base with drifting radial light blobs and a
 * static refractive ribbon. Blobs move on slow Lissajous paths so panels floating
 * on translucent glass surfaces feel alive. Animation pauses with window visibility.
 */
public final class GlassBackdropView extends View {
    private static final long CYCLE_MS = 26_000;

    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final float[] blobPhase = {0f, 0.42f, 0.78f};
    private int frameTick;

    private Shader baseShader;
    private Shader ribbonShader;
    private Shader vignetteShader;
    private RadialGradient blobShaders[] = new RadialGradient[3];
    private ValueAnimator drift;

    public GlassBackdropView(Context context) {
        super(context);
        init();
    }

    public GlassBackdropView(Context context, AttributeSet attrs) {
        super(context, attrs);
        init();
    }

    private void init() {
        drift = ValueAnimator.ofFloat(0f, 1f);
        drift.setDuration(CYCLE_MS);
        drift.setRepeatCount(ValueAnimator.INFINITE);
        drift.setInterpolator(new LinearInterpolator());
        drift.addUpdateListener(animation -> {
            // 隔帧重绘（约 30fps），全屏渐变足够顺滑且明显省电
            if ((frameTick++ & 1) != 0) return;
            if (getVisibility() == VISIBLE && isShown()) invalidate();
        });
    }

    @Override protected void onAttachedToWindow() {
        super.onAttachedToWindow();
        drift.start();
    }

    @Override protected void onDetachedFromWindow() {
        drift.cancel();
        super.onDetachedFromWindow();
    }

    @Override protected void onWindowVisibilityChanged(int visibility) {
        super.onWindowVisibilityChanged(visibility);
        if (visibility == VISIBLE) drift.start();
        else drift.cancel();
    }

    @Override protected void onSizeChanged(int width, int height, int oldWidth, int oldHeight) {
        super.onSizeChanged(width, height, oldWidth, oldHeight);
        baseShader = new LinearGradient(0, 0, width * .7f, height,
            new int[]{Color.rgb(7, 29, 20), Color.rgb(16, 66, 42), Color.rgb(5, 18, 12)},
            new float[]{0f, .52f, 1f}, Shader.TileMode.CLAMP);
        ribbonShader = new LinearGradient(0, height * .08f, width, height * .9f,
            new int[]{0x660B2418, 0x4637D68C, 0x5A03140C},
            new float[]{0f, .55f, 1f}, Shader.TileMode.CLAMP);
        vignetteShader = new LinearGradient(0, 0, 0, height,
            new int[]{0x30000000, 0x00000000, 0x73000603},
            new float[]{0f, .4f, 1f}, Shader.TileMode.CLAMP);
        float[] radii = {width * .62f, width * .5f, width * .44f};
        int[][] colors = {
            {0x5E2BD98F, 0x2E1E7C52, 0x00203D2C},
            {0x4212F0C8, 0x2A0C5B48, 0x000C3325},
            {0x3D9FFFE2, 0x243C8F76, 0x00142A20},
        };
        for (int i = 0; i < 3; i++) {
            blobShaders[i] = new RadialGradient(0, 0, radii[i], colors[i],
                new float[]{0f, .55f, 1f}, Shader.TileMode.CLAMP);
        }
    }

    @Override protected void onDraw(Canvas canvas) {
        super.onDraw(canvas);
        int width = getWidth();
        int height = getHeight();
        if (width == 0 || height == 0) return;
        float phase = drift.getAnimatedFraction();

        canvas.drawColor(Color.rgb(4, 15, 10));
        paint.setShader(baseShader);
        canvas.drawRect(0, 0, width, height, paint);

        // 静态折射缎带，保留原有层次感
        paint.setShader(ribbonShader);
        canvas.save();
        canvas.rotate(-14f, width * .5f, height * .5f);
        canvas.drawRoundRect(-width * .2f, height * .3f, width * 1.2f, height * .62f,
            height * .16f, height * .16f, paint);
        canvas.restore();

        // 漂移光斑：画布平移驱动预生成的径向渐变，避免每帧分配
        for (int i = 0; i < 3; i++) {
            paint.setShader(blobShaders[i]);
            float t = (phase + blobPhase[i]) % 1f;
            double angle = t * Math.PI * 2;
            float cx = width * (.22f + .56f * (0.5f + 0.5f * (float) Math.sin(angle * 1.7 + i * 1.9)));
            float cy = height * (.18f + .66f * (0.5f + 0.5f * (float) Math.cos(angle + i * 2.6)));
            canvas.save();
            canvas.translate(cx, cy);
            canvas.drawCircle(0, 0, width * .62f, paint);
            canvas.restore();
        }

        paint.setShader(vignetteShader);
        canvas.drawRect(0, 0, width, height, paint);
        paint.setShader(null);
    }
}
